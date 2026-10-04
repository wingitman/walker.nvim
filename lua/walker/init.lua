local document = require("walker.document")
local transport = require("walker.transport")
local M = {}
local defaults = {
  enabled = true,
  command = {},
  brief = "",
  triggers = { directive = false, save = false, interval = false, idle = false },
  debounce_ms = 750,
  idle_ms = 3000,
  interval_ms = 10000,
  cooldown_ms = 2000,
  task_timeout_ms = 180000,
  max_message_bytes = 1024 * 1024,
  max_task_bytes = 128 * 1024,
  max_requests = 8,
  max_output_tokens = 2000,
  token_budget = 32000,
  confirm_build = true,
}
local config, states, interval_timer = vim.deepcopy(defaults), {}, nil
local namespace = vim.api.nvim_create_namespace("walker")
local sequence = 0

local function notify(message, level)
  vim.notify("Walker: " .. message, level or vim.log.levels.INFO)
end

local function read(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cs = vim.bo[buf].commentstring
  local tasks, err = document.parse(lines, cs)
  return tasks, lines, cs, err
end

local function find(tasks, id)
  for _, task in ipairs(tasks or {}) do if task.id == id then return task end end
end

local function fingerprint(task)
  return vim.json.encode({ task.id, task.mode, task.tags, task.instructions, task.result })
end

local function status(buf, text)
  local state = states[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then return end
  state.status = text
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  if state.active then
    local tasks = read(buf)
    local task = find(tasks, state.active.id)
    if task then
      vim.api.nvim_buf_set_extmark(buf, namespace, task.first - 1, 0, {
        virt_text = { { " Walker: " .. text, "DiagnosticInfo" } },
      })
    end
  end
end

local function cancel(buf, reason)
  local state = states[buf]
  if not state then return end
  local active = state.active
  if active and vim.api.nvim_buf_is_loaded(buf) then
    local tasks = read(buf)
    local task = find(tasks, active.id)
    if task and task.mode == active.mode and task.tags == active.tags then
      state.attempted[task.id] = fingerprint(task)
    end
  end
  state.confirmation = nil
  state.active = nil -- Revoke authority before stopping the process.
  if active and active.transport then active.transport.stop() end
  status(buf, reason or "Cancelled")
end

local function snapshot(buf, active)
  local tasks, lines, cs, err = read(buf)
  if not tasks then return nil, err end
  local task = find(tasks, active.id)
  if not task or task.mode ~= active.mode or task.tags ~= active.tags then
    return nil, "Task removed or mode/tags changed; activate it again"
  end
  return document.snapshot(task, lines, config.brief), task, lines, cs
end

local function within_limit(value)
  return #vim.json.encode(value) <= config.max_task_bytes
end

local function sync(buf, active)
  if not states[buf] or states[buf].active ~= active then return false end
  local current, err = snapshot(buf, active)
  if not current then cancel(buf, err); return false end
  if not within_limit(current) then cancel(buf, "Task exceeds max_task_bytes"); return false end
  if not vim.deep_equal(current, active.snapshot) then
    local base = active.revision
    active.revision = base + 1
    local changes = document.delta(active.snapshot, current)
    active.snapshot = current
    active.transport.send({ type = "update", base_revision = base, revision = active.revision, changes = changes })
    status(buf, "Updated · revision " .. active.revision)
  end
  return true
end

local function apply_message(buf, active, message)
  local state = states[buf]
  if not state or state.active ~= active then return end
  if message.type == "usage" then
    if type(message.total_tokens) ~= "number" or message.total_tokens < 0 then
      cancel(buf, "Invalid usage report"); return
    end
    active.tokens = (active.tokens or 0) + message.total_tokens
    state.tokens = active.tokens
    if active.tokens > config.token_budget then cancel(buf, "Token budget exceeded"); return end
    status(buf, "Working · " .. active.tokens .. " tokens")
    return
  end
  if message.type == "error" or message.type == "blocked" then
    cancel(buf, type(message.message) == "string" and message.message:sub(1, 500) or "Agent stopped")
    notify(state.status, vim.log.levels.WARN)
    return
  end
  if message.type ~= "edit" then cancel(buf, "Unknown agent message"); return end
  -- Check now, even if the human-edit debounce has not fired yet.
  if not sync(buf, active) then return end
  if message.revision ~= active.revision then
    active.transport.send({ type = "ack", accepted = false, revision = active.revision, reason = "stale" })
    return
  end
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    cancel(buf, "Buffer is read-only or nonmodifiable"); return
  end
  local _, task, lines, cs = snapshot(buf, active)
  local candidate, err = document.propose(lines, task, message, cs)
  if not candidate then cancel(buf, "Rejected agent edit: " .. err); return end
  active.edits = (active.edits or 0) + 1
  if active.edits > config.max_requests then cancel(buf, "Edit limit reached"); return end
  local candidate_tasks = document.parse(candidate, cs)
  local candidate_task = find(candidate_tasks, active.id)
  if not within_limit(document.snapshot(candidate_task, candidate, config.brief)) then
    cancel(buf, "Proposed task exceeds max_task_bytes"); return
  end
  -- Preserve unrelated edits and apply the smallest enclosing line span atomically.
  local prefix, suffix = 0, 0
  while prefix < #lines and prefix < #candidate and lines[prefix + 1] == candidate[prefix + 1] do prefix = prefix + 1 end
  while suffix < #lines - prefix and suffix < #candidate - prefix
    and lines[#lines - suffix] == candidate[#candidate - suffix] do suffix = suffix + 1 end
  state.applying = true
  local ok, apply_err = pcall(vim.api.nvim_buf_call, buf, function()
    -- Close the preceding undo block without joining the human's last change.
    vim.cmd("let &undolevels = &undolevels")
    if prefix ~= #lines or prefix ~= #candidate then
      vim.api.nvim_buf_set_lines(buf, prefix, #lines - suffix, false,
        document.slice(candidate, prefix + 1, #candidate - suffix))
    end
  end)
  state.applying = false
  if not ok then cancel(buf, "Could not apply edit: " .. tostring(apply_err)); return end
  -- Agent-written results must not turn into new automatic activation events.
  -- Keep the pre-completion fingerprint so undo cannot immediately rebuild.
  state.attempted[task.id] = fingerprint(message.done and task or candidate_task)
  active.revision = active.revision + 1
  if not message.done then active.snapshot = snapshot(buf, active) end
  active.transport.send({ type = "ack", accepted = true, revision = active.revision })
  if message.done then
    cancel(buf, "Completed " .. task.id)
    notify("Completed " .. task.id)
  else
    status(buf, "Working · revision " .. active.revision)
  end
end

local function launch(buf, task, initial)
  local state = states[buf]
  if not state or not state.enabled or state.active then return end
  local active = { id = task.id, mode = task.mode, tags = task.tags, snapshot = initial, revision = 1 }
  state.active, state.tokens, state.last_start = active, 0, vim.uv.now()
  local handle, err = transport.start(config.command,
    function(message) apply_message(buf, active, message) end,
    function(message)
      if state.active == active then cancel(buf, message); notify(message, vim.log.levels.ERROR) end
    end,
    function(code)
      if state.active == active then
        cancel(buf, "Agent exited before completing (" .. code .. ")")
        notify(state.status, vim.log.levels.WARN)
      end
    end, config.max_message_bytes)
  if not handle then cancel(buf, err); notify(err, vim.log.levels.ERROR); return end
  active.transport = handle
  handle.send({ type = "start", protocol = 1, revision = 1, task = initial, limits = {
    max_requests = config.max_requests, max_output_tokens = config.max_output_tokens, token_budget = config.token_budget,
  } })
  status(buf, "Working · " .. task.mode)
  vim.defer_fn(function()
    if states[buf] == state and state.active == active then cancel(buf, "Task timed out") end
  end, config.task_timeout_ms)
end

local function start(buf, task, manual)
  local state = states[buf]
  if not state or not state.enabled or state.active or state.confirmation then return end
  if #config.command == 0 then
    if manual then notify("Configure command before starting an agent", vim.log.levels.WARN) end
    return
  end
  local _, lines = read(buf)
  local initial = document.snapshot(task, lines, config.brief)
  if not within_limit(initial) then
    if manual then notify("Task exceeds max_task_bytes", vim.log.levels.WARN) end
    return
  end
  if table.concat(task.instructions, ""):match("^%s*$") then
    if manual then notify("Add an instruction to the task first", vim.log.levels.WARN) end
    return
  end
  local key = fingerprint(task)
  if not manual and state.attempted[task.id] == key then return end
  state.attempted[task.id] = key
  if task.mode == "build" and config.confirm_build then
    local confirmation = {}
    state.confirmation = confirmation
    vim.ui.select({ "Build", "Cancel" }, {
      prompt = "Build " .. task.id .. " against its CURRENT target? Check the inline plan for stale assumptions.",
    }, function(choice)
      if states[buf] ~= state or state.confirmation ~= confirmation then return end
      state.confirmation = nil
      if choice ~= "Build" or not state.enabled or state.active then return end
      local latest_tasks, latest_lines = read(buf)
      local latest = find(latest_tasks, task.id)
      if not latest or not vim.deep_equal(document.snapshot(latest, latest_lines, config.brief), initial) then
        notify("Task changed during confirmation; activate again", vim.log.levels.WARN); return
      end
      launch(buf, latest, initial)
    end)
  else
    launch(buf, task, initial)
  end
end

local function evaluate(buf, manual, id)
  local state = states[buf]
  if not state or not state.enabled then
    if manual then notify("Disabled; use :WalkerEnable first") end
    return
  end
  if state.active then sync(buf, state.active); return end
  if not manual and vim.uv.now() - state.last_start < config.cooldown_ms then return end
  local tasks, _, _, err = read(buf)
  if not tasks then if manual then notify(err, vim.log.levels.WARN) end; return end
  for _, task in ipairs(tasks) do
    if document.pending[task.mode] and (not id or id == task.id) then
      start(buf, task, manual)
      if state.active or state.confirmation then return end
    end
  end
  if manual then notify("No actionable task. Select a passage and use :'<,'>WalkerTask plan <instruction>.") end
end

local function attach(buf)
  if states[buf] or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then return end
  local state = { enabled = config.enabled, attempted = {}, last_start = -math.huge, generation = 0, status = "Ready" }
  states[buf] = state
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if states[buf] ~= state then return true end
      if state.applying then return end
      state.generation = state.generation + 1
      local generation = state.generation
      -- on_lines runs under textlock. Inspection/UI work is deferred.
      vim.schedule(function()
        if states[buf] ~= state or not state.enabled then return end
        if state.active then
          local current = snapshot(buf, state.active)
          if not current then cancel(buf, "Task boundaries or authority changed")
          elseif not vim.deep_equal(current, state.active.snapshot) then status(buf, "Human edits pending") end
        end
        vim.defer_fn(function()
          if states[buf] ~= state or state.generation ~= generation or not state.enabled then return end
          if state.active then sync(buf, state.active)
          elseif config.triggers.directive then evaluate(buf, false) end
        end, config.debounce_ms)
        if config.triggers.idle then
          vim.defer_fn(function()
            if states[buf] == state and state.generation == generation then evaluate(buf, false) end
          end, config.idle_ms)
        end
      end)
    end,
    on_detach = function()
      if states[buf] ~= state then return end
      cancel(buf, "Buffer detached")
      states[buf] = nil
    end,
  })
end

function M.run(id)
  local buf = vim.api.nvim_get_current_buf()
  attach(buf)
  if not id or id == "" then
    id = nil
    local tasks = read(buf)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for _, task in ipairs(tasks or {}) do
      if (row >= task.first and row <= task.last) or (row >= task.target.first and row <= task.target.last) then
        id = task.id; break
      end
    end
    if not id and tasks and #tasks > 1 then notify("Place the cursor in a task/target or supply its ID"); return end
  end
  evaluate(buf, true, id)
end

function M.cancel() cancel(vim.api.nvim_get_current_buf()) end
function M.disable()
  local buf = vim.api.nvim_get_current_buf()
  attach(buf)
  if states[buf] then states[buf].enabled = false; cancel(buf, "Disabled") end
end
function M.enable()
  local buf = vim.api.nvim_get_current_buf()
  attach(buf)
  if states[buf] then states[buf].enabled = true; status(buf, "Ready") end
end
function M.status(buf)
  local state = states[buf or vim.api.nvim_get_current_buf()]
  return state and { enabled = state.enabled, active = state.active and state.active.id, message = state.status, tokens = state.tokens or 0 }
    or { enabled = false, message = "Not attached", tokens = 0 }
end

function M.create(first, last, args)
  local buf = vim.api.nvim_get_current_buf()
  local mode, instruction = args:match("^(%S+)%s*(.*)$")
  if not document.pending[mode] then notify("Usage: :'<,'>WalkerTask plan|review|build <instruction>", vim.log.levels.WARN); return end
  if instruction == "" then notify("Provide an instruction after the mode", vim.log.levels.WARN); return end
  local tasks, lines, cs, err = read(buf)
  if not tasks then notify(err, vim.log.levels.WARN); return end
  for _, task in ipairs(tasks) do
    if (first <= task.last and last >= task.first) or (first <= task.target.last and last >= task.target.first) then
      notify("Task scopes cannot overlap", vim.log.levels.WARN); return
    end
  end
  sequence = sequence + 1
  local id = "w" .. os.time() .. "-" .. sequence
  local inserted = {}
  for _, text in ipairs({ "@walker " .. id .. " #" .. mode, instruction, "@result", "@endwalker", "@walker-target " .. id }) do
    inserted[#inserted + 1] = document.wrap(text, cs)
  end
  vim.list_extend(inserted, document.slice(lines, first, last))
  inserted[#inserted + 1] = document.wrap("@endwalker-target " .. id, cs)
  vim.api.nvim_buf_set_lines(buf, first - 1, last, false, inserted)
  attach(buf)
end

function M.setup(options)
  for buf in pairs(states) do cancel(buf, "Reconfigured") end
  states = {}
  if interval_timer then interval_timer:stop(); interval_timer:close(); interval_timer = nil end
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  assert(type(config.command) == "table" and vim.islist(config.command), "walker.command must be an argv array")
  for _, arg in ipairs(config.command) do assert(type(arg) == "string", "walker.command entries must be strings") end
  assert(type(config.brief) == "string", "walker.brief must be a string")
  assert(type(config.enabled) == "boolean" and type(config.confirm_build) == "boolean", "walker enabled/confirm_build must be boolean")
  for _, name in ipairs({ "directive", "save", "interval", "idle" }) do
    assert(type(config.triggers[name]) == "boolean", "walker.triggers." .. name .. " must be boolean")
  end
  for _, key in ipairs({ "debounce_ms", "idle_ms", "interval_ms", "cooldown_ms", "task_timeout_ms", "max_message_bytes", "max_task_bytes", "max_requests", "max_output_tokens", "token_budget" }) do
    assert(type(config[key]) == "number" and config[key] >= 1 and config[key] % 1 == 0, "walker." .. key .. " must be a positive integer")
  end
  local group = vim.api.nvim_create_augroup("Walker", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, { group = group, callback = function(event) attach(event.buf) end })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(event)
    if config.triggers.save then evaluate(event.buf, false) end
  end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    for buf in pairs(states) do cancel(buf, "Exiting") end
  end })
  local commands = {
    WalkerRun = { function(opts) M.run(opts.args) end, { nargs = "?" } },
    WalkerCancel = { M.cancel, {} }, WalkerEnable = { M.enable, {} }, WalkerDisable = { M.disable, {} },
    WalkerStatus = { function() notify(vim.inspect(M.status())) end, {} },
    WalkerTask = { function(opts)
      if opts.range == 0 then notify("Select an explicit passage first", vim.log.levels.WARN); return end
      M.create(opts.line1, opts.line2, opts.args)
    end, { nargs = "+", range = true } },
  }
  for name, entry in pairs(commands) do vim.api.nvim_create_user_command(name, entry[1], entry[2]) end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do attach(buf) end
  if config.triggers.interval then
    interval_timer = vim.uv.new_timer()
    interval_timer:start(config.interval_ms, config.interval_ms, vim.schedule_wrap(function()
      for buf in pairs(states) do evaluate(buf, false) end
    end))
  end
end

return M

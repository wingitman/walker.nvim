local document = require("walker.document")
local transport = require("walker.transport")
local accounting = require("walker.usage")
local panel = require("walker.panel")
local files = require("walker.files")
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
  panel = { width = 44 },
  balance = { enabled = false, refresh_seconds = 60 },
  pricing = false, -- Explicit model-specific per-million rates; never guessed.
}
local config, states, interval_timer = vim.deepcopy(defaults), {}, nil
local session_usage, balance = accounting.new(), { message = "Unavailable (balance lookup disabled)" }
local namespace = vim.api.nvim_create_namespace("walker")
local sequence = 0

local function notify(message, level)
  vim.notify("Walker: " .. message, level or vim.log.levels.INFO)
end

local function is_document(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == "" and not vim.bo[buf].filetype:match("^snacks_")
end

local function require_document(buf, writable)
  if not is_document(buf) then
    notify("Focus your document buffer, not a notification, picker, or terminal window", vim.log.levels.WARN)
    return false
  end
  if writable and (not vim.bo[buf].modifiable or vim.bo[buf].readonly) then
    notify("Document is read-only or nonmodifiable", vim.log.levels.WARN)
    return false
  end
  return true
end

local function read(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cs = vim.bo[buf].commentstring
  local tasks, directives, err, candidates = document.scan(lines, cs)
  return tasks, lines, cs, err, directives, candidates
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
  panel.refresh(buf)
end

local function cancel(buf, reason, phase)
  local state = states[buf]
  if not state then return end
  local active = state.active
  if active then
    state.last_task_at = os.time()
    state.records[active.id] = { phase = phase or "cancelled", detail = phase == "complete" and "Done" or reason,
      mode = phase == "complete" and document.completed[active.mode] or active.mode }
    if active.awaiting_usage then
      state.usage.incomplete, session_usage.incomplete = true, true
    end
  end
  if active and vim.api.nvim_buf_is_loaded(buf) then
    local tasks = read(buf)
    local task = find(tasks, active.id)
    if task and task.mode == active.mode and task.tags == active.tags then
      state.attempted[task.id] = fingerprint(task)
    end
  end
  state.confirmation = nil
  state.prompt = nil
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
  if vim.api.nvim_buf_get_name(buf) ~= active.source_name or files.directory(buf) ~= active.directory then
    return nil, "Source filename or directory changed; activate the task again"
  end
  local value = document.snapshot(task, lines, config.brief)
  value.create_file_directory = active.directory
  return value, task, lines, cs
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

local function apply_message(buf, active, message, approved_file)
  local state = states[buf]
  if not state or state.active ~= active then return end
  if message.type == "usage" then
    local ok, err = accounting.add(state.usage, message, config.pricing, state.model)
    if not ok then cancel(buf, err, "failed"); return end
    accounting.add(session_usage, message, config.pricing, state.model)
    active.awaiting_usage = false
    active.tokens, state.tokens = state.usage.total_tokens, state.usage.total_tokens
    if active.tokens > config.token_budget then cancel(buf, "Token budget exceeded", "failed"); return end
    status(buf, "Working · " .. active.tokens .. " tokens")
    panel.refresh()
    return
  end
  if message.type == "metadata" then
    if type(message.model) == "string" then state.model = message.model:sub(1, 100):gsub("%c", " ") end
    panel.refresh(buf)
    return
  end
  if message.type == "progress" then
    if message.stage == "request" then
      active.awaiting_usage = true
      state.records[active.id].detail = "Waiting for provider response"
      status(buf, "Waiting for provider response")
    end
    return
  end
  if message.type == "error" or message.type == "blocked" then
    cancel(buf, type(message.message) == "string" and message.message:sub(1, 500) or "Agent stopped",
      message.type == "blocked" and "needs input" or "failed")
    notify(state.status, vim.log.levels.WARN)
    return
  end
  if message.type ~= "edit" then cancel(buf, "Unknown agent message", "failed"); return end
  if active.file_confirmation and not approved_file then
    cancel(buf, "Agent sent another edit while file confirmation was pending", "failed"); return
  end
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
  local prepared
  if message.create_file ~= nil then
    if task.mode ~= "build" or not message.done or message.blocked or message.target ~= nil then
      cancel(buf, "File creation requires a completed build proposal without target edits", "failed"); return
    end
    local file_err
    prepared, file_err = files.prepare(active.directory, message.create_file, config.max_task_bytes)
    if not prepared then cancel(buf, "Rejected file creation: " .. file_err, "failed"); return end
    -- Only the editor records success, after the exclusive write succeeds.
    message.result = { "Created `" .. message.create_file.name .. "`." }
  end
  local candidate, err = document.propose(lines, task, message, cs)
  if not candidate then cancel(buf, "Rejected agent edit: " .. err, "failed"); return end
  local candidate_tasks = document.scan(candidate, cs)
  local candidate_task = find(candidate_tasks, active.id)
  if not within_limit(document.snapshot(candidate_task, candidate, config.brief)) then
    cancel(buf, "Proposed task exceeds max_task_bytes", "failed"); return
  end
  if prepared and not approved_file then
    local confirmation = {}
    active.file_confirmation = confirmation
    state.records[active.id] = { phase = "needs input", mode = active.mode, detail = "Confirm file: " .. message.create_file.name }
    status(buf, "Waiting for file creation confirmation")
    local proposed_revision = active.revision
    vim.ui.select({ "Create file", "Cancel" }, {
      prompt = "Create " .. prepared.path .. " (" .. #prepared.content .. " bytes)? No overwrite or execution.",
    }, function(choice)
      if states[buf] ~= state or state.active ~= active or active.file_confirmation ~= confirmation then return end
      active.file_confirmation = nil
      if choice ~= "Create file" then cancel(buf, "File creation cancelled; no file or task edit applied"); return end
      if not sync(buf, active) then return end
      if active.revision ~= proposed_revision then
        cancel(buf, "Source changed during file confirmation; request creation again"); return
      end
      -- Recheck source, limits, permissions and destination at acceptance time.
      apply_message(buf, active, message, prepared)
    end)
    return
  end
  active.edits = (active.edits or 0) + 1
  if active.edits > config.max_requests then cancel(buf, "Edit limit reached", "failed"); return end
  local created
  if approved_file then
    local write_err
    created, write_err = files.write(approved_file)
    if not created then cancel(buf, write_err, "failed"); return end
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
  if not ok then
    local detail = "Could not apply edit: " .. tostring(apply_err)
    if created then detail = "File created at " .. created .. ", but document update failed: " .. tostring(apply_err) end
    cancel(buf, detail, "failed"); notify(detail, vim.log.levels.ERROR); return
  end
  state.last_edit_at = os.time()
  -- Agent-written results must not turn into new automatic activation events.
  -- Keep the pre-completion fingerprint so undo cannot immediately rebuild.
  state.attempted[task.id] = fingerprint(message.done and task or candidate_task)
  active.revision = active.revision + 1
  if not message.done and not message.blocked then active.snapshot = snapshot(buf, active) end
  active.transport.send({ type = "ack", accepted = true, revision = active.revision })
  if type(message.suggestions) == "table" then
    for _, suggestion in ipairs(message.suggestions) do
      if type(suggestion) == "string" and #suggestion <= 500 and #state.suggestions < 50 then
        local key = task.id .. ":" .. suggestion
        if not state.suggestion_keys[key] then
          state.suggestion_keys[key] = true
          state.suggestions[#state.suggestions + 1] = { title = suggestion, parent = task.id }
        end
      end
    end
  end
  if message.done then
    cancel(buf, "Completed " .. task.id, "complete")
    notify("Completed " .. task.id)
  elseif message.blocked then
    cancel(buf, "Question appended to the working section; answer inline and retry", "needs input")
  else
    status(buf, "Working · revision " .. active.revision)
  end
end

local function launch(buf, task, initial)
  local state = states[buf]
  if not state or not state.enabled or state.active then return end
  local active = { id = task.id, mode = task.mode, tags = task.tags, snapshot = initial, revision = 1,
    source_name = vim.api.nvim_buf_get_name(buf), directory = initial.create_file_directory }
  state.active, state.tokens, state.last_start = active, 0, vim.uv.now()
  state.last_task_at = os.time()
  state.usage = accounting.new()
  state.records[task.id] = { phase = task.mode == "plan" and "planning" or "working", mode = task.mode, detail = "Starting adapter" }
  local handle, err = transport.start(config.command,
    function(message) apply_message(buf, active, message) end,
    function(message)
      if state.active == active then cancel(buf, message, "failed"); notify(message, vim.log.levels.ERROR) end
    end,
    function(code)
      if state.active == active then
        cancel(buf, "Agent exited before completing (" .. code .. ")", "failed")
        notify(state.status, vim.log.levels.WARN)
      end
    end, config.max_message_bytes)
  if not handle then cancel(buf, err, "failed"); notify(err, vim.log.levels.ERROR); return end
  active.transport = handle
  handle.send({ type = "start", protocol = 1, revision = 1, task = initial, limits = {
    max_requests = config.max_requests, max_output_tokens = config.max_output_tokens, token_budget = config.token_budget,
  } })
  status(buf, "Starting adapter · " .. task.mode)
  vim.defer_fn(function()
    if states[buf] == state and state.active == active then cancel(buf, "Task timed out", "failed") end
  end, config.task_timeout_ms)
end

local function start(buf, task, manual)
  local state = states[buf]
  if not state or not state.enabled or state.active or state.confirmation then return end
  if #config.command == 0 then
    state.records[task.id] = { phase = "needs input", mode = task.mode, detail = "Configure an agent command" }
    if manual then notify("Configure command before starting an agent", vim.log.levels.WARN) end
    return
  end
  local _, lines = read(buf)
  local initial = document.snapshot(task, lines, config.brief)
  initial.create_file_directory = files.directory(buf)
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
    state.records[task.id] = { phase = "needs input", mode = task.mode, detail = "Waiting for build confirmation" }
    panel.refresh(buf)
    local confirmation = { id = task.id }
    state.confirmation = confirmation
    vim.ui.select({ "Build", "Cancel" }, {
      prompt = "Carry out " .. task.id .. " within its task passage? Creating a file requires separate confirmation.",
    }, function(choice)
      if states[buf] ~= state or state.confirmation ~= confirmation then return end
      state.confirmation = nil
      if choice ~= "Build" then
        state.records[task.id] = { phase = "cancelled", mode = task.mode, detail = "Build not authorized" }
        panel.refresh(buf)
        return
      end
      if not state.enabled or state.active then return end
      local latest_tasks, latest_lines = read(buf)
      local latest = find(latest_tasks, task.id)
      local latest_snapshot = latest and document.snapshot(latest, latest_lines, config.brief)
      if latest_snapshot then latest_snapshot.create_file_directory = files.directory(buf) end
      if not latest or not vim.deep_equal(latest_snapshot, initial) then
        notify("Task changed during confirmation; activate again", vim.log.levels.WARN); return
      end
      launch(buf, latest, initial)
    end)
  else
    launch(buf, task, initial)
  end
end

local function new_id(tasks)
  local id
  repeat sequence = sequence + 1; id = "w" .. os.time() .. "-" .. sequence until not find(tasks, id)
  return id
end

local function normalize(buf)
  local state = states[buf]
  local tasks, source, cs, err, directives = read(buf)
  if not tasks then status(buf, err); return false end
  if #directives == 0 then return true end
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then return false end
  local changed, promotions = vim.deepcopy(source), {}
  for index = #directives, 1, -1 do
    local directive = directives[index]
    if directive.error then status(buf, directive.error); return false end
    if directive.continuation then
      promotions[directive.continuation] = true
      table.remove(changed, directive.first)
    else
      local id, mode = new_id(tasks), directive.mode or "build"
      local flags, result = directive.mode and "" or " #request", {}
      if directive.instruction:gsub("#[%w_-]+", ""):match("^%s*$") then
        flags = flags .. " #needs-instruction"
        result = { "Walker question [needs-input]: What should I do? Answer below with #plan, #review, or #build.",
          "Walker answer: #" .. mode .. " <your goal>" }
      elseif directive.mode and (mode == "build" or mode == "review") then
        flags = " #needs-scope"
        result = { "Walker question [needs-input]: Which passage should I work on?",
          "Select it and run :'<,'>WalkerScope " .. id .. ". Nothing outside that selection will be rewritten." }
      end
      local inserted = document.compact(id, mode, directive.instruction, {}, result, cs, flags)
      for _ = directive.first, directive.last do table.remove(changed, directive.first) end
      for row = #inserted, 1, -1 do table.insert(changed, directive.first, inserted[row]) end
    end
  end
  for id in pairs(promotions) do
    local current = document.scan(changed, cs)
    local task = find(current, id)
    if not task or (task.mode ~= "planned" and task.mode ~= "reviewed") then
      status(buf, "Build continuation needs a completed plan or review"); return false
    end
    changed = document.promote(changed, task, cs)
    state.attempted[id] = nil
  end
  local parsed, _, parse_err = document.scan(changed, cs)
  if not parsed then status(buf, parse_err); return false end
  state.applying = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, changed)
  state.applying = false
  panel.refresh(buf)
  return true
end

local function resolve_answers(buf)
  local tasks, lines, cs = read(buf)
  for _, task in ipairs(tasks or {}) do
    if task.tags:find("#needs-instruction", 1, true) then
      for _, line in ipairs(task.result) do
        local mode, goal = line:match("^Walker answer:%s*#(%w+)%s+(.+)$")
        if document.pending[mode] and goal and not goal:find("<your goal>", 1, true) then
          -- Keep the human's extra context/answers in the working section.
          local result, flags = vim.deepcopy(task.result), task.tags:find("#request%f[^%w_-]") and " #request" or ""
          if mode ~= "plan" and flags == "" and task.target.last == task.target.first + 1 then
            flags = " #needs-scope"
            result[#result + 1] = "Walker question [needs-input]: Select the passage and run :'<,'>WalkerScope " .. task.id
          end
          local inserted = document.compact(task.id, mode, goal,
            document.slice(lines, task.target.first + 1, task.target.last - 1), result, cs, flags)
          local state = states[buf]
          state.applying = true
          vim.api.nvim_buf_set_lines(buf, task.first - 1, task.last, false, inserted)
          state.applying = false
          return
        end
      end
    end
  end
end

local function evaluate(buf, manual, id)
  if not is_document(buf) then return end
  local state = states[buf]
  if not state or not state.enabled then
    if manual then notify("Disabled; use :WalkerEnable first") end
    return
  end
  if state.active then sync(buf, state.active); return end
  -- Do not normalize half-typed directives or answers. Active co-editing still
  -- synchronizes above; only starting new work waits for InsertLeave.
  if not manual and vim.fn.mode():match("^[iR]") then state.waiting_insert = true; return end
  state.waiting_insert = nil
  local remaining = config.cooldown_ms - (vim.uv.now() - state.last_start)
  if not manual and remaining > 0 then
    if not state.wake then
      state.wake = true
      vim.defer_fn(function()
        if states[buf] == state then state.wake = nil; evaluate(buf, false) end
      end, remaining)
    end
    return
  end
  if not normalize(buf) then if manual then notify(state.status, vim.log.levels.WARN) end; return end
  if vim.bo[buf].modifiable and not vim.bo[buf].readonly then resolve_answers(buf) end
  local tasks, _, _, err = read(buf)
  if not tasks then if manual then notify(err, vim.log.levels.WARN) end; return end
  for _, task in ipairs(tasks) do
    if document.pending[task.mode] and (not id or id == task.id) then
      if task.tags:find("#needs-scope", 1, true) or task.tags:find("#needs-instruction", 1, true) then
        state.records[task.id] = { phase = "needs input", mode = task.mode, detail = "Question appended in document" }
      else start(buf, task, manual) end
      if state.active or state.confirmation then return end
    end
  end
  panel.refresh(buf)
  if manual then notify("No actionable task. Select a passage and use :'<,'>WalkerTask plan <instruction>.") end
end

local function attach(buf)
  if states[buf] or not is_document(buf) then return end
  local state = { enabled = config.enabled, attempted = {}, last_start = -math.huge, generation = 0, status = "Ready",
    records = {}, usage = accounting.new(), suggestions = {}, suggestion_keys = {} }
  states[buf] = state
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if states[buf] ~= state then return true end
      if state.applying then return end
      state.generation = state.generation + 1
      local generation = state.generation
      -- on_lines runs under textlock. Inspection/UI work is deferred.
      vim.schedule(function()
        if states[buf] ~= state then return end
        panel.refresh(buf)
        if not state.enabled then return end
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

local function selected_task(buf, id)
  local tasks, lines = read(buf)
  if id and id ~= "" then return find(tasks, id) end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, task in ipairs(tasks or {}) do
    if (row >= task.first and row <= task.last) or (row >= task.target.first and row <= task.target.last) then return task end
    local following = task.last + 1
    while lines[following] and lines[following]:match("^%s*$") do following = following + 1 end
    local text = lines[following] and vim.trim(document.unwrap(lines[following], vim.bo[buf].commentstring) or lines[following])
    if row > task.last and (row < following or (row == following and (text == "#build" or text == "@walker #build"))) then return task end
  end
  if tasks and #tasks == 1 then return tasks[1] end
end

local function run_existing(buf, task)
  if task.mode == "planned" or task.mode == "reviewed" then
    M.promote(buf, task.id)
  elseif task.mode == "built" then
    notify("Task already built. Edit its header to #build for another pass, or select a new passage.")
  else evaluate(buf, true, task.id) end
end

function M.run(id)
  local buf = vim.api.nvim_get_current_buf()
  if not require_document(buf, true) then return end
  attach(buf)
  local task = selected_task(buf, id)
  if task then run_existing(buf, task); return end
  local tasks = read(buf)
  if id and id ~= "" then notify("No task with ID " .. id); return end
  if tasks and #tasks > 1 then
    notify("Place the cursor in a task/target or supply its ID"); return
  end
  evaluate(buf, true)
end

function M.cancel()
  local buf = vim.api.nvim_get_current_buf()
  if require_document(buf) then cancel(buf) end
end
function M.disable()
  local buf = vim.api.nvim_get_current_buf()
  if not require_document(buf) then return end
  attach(buf)
  if states[buf] then states[buf].enabled = false; cancel(buf, "Disabled") end
end
function M.enable()
  local buf = vim.api.nvim_get_current_buf()
  if not require_document(buf) then return end
  attach(buf)
  if states[buf] then states[buf].enabled = true; status(buf, "Ready") end
end
function M.status(buf)
  local state = states[buf or vim.api.nvim_get_current_buf()]
  return state and { enabled = state.enabled, active = state.active and state.active.id, message = state.status, tokens = state.tokens or 0 }
    or { enabled = false, message = "Not attached", tokens = 0 }
end

function M.view(buf)
  local state = states[buf]
  local view = { name = "No document", root = "—", enabled = false, tasks = {}, message = "Not attached",
    usage_summary = accounting.summary(accounting.new(), config.token_budget), times = "Task — · Edit —",
    task_usage = accounting.lines(accounting.new(), config.token_budget), session_usage = accounting.lines(session_usage), balance = {} }
  if is_document(buf) then
    local name = vim.api.nvim_buf_get_name(buf)
    local directory = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
    if not state or state.root_directory ~= directory then
      local root = vim.fs.root(directory, ".git")
      view.root = vim.fn.fnamemodify(root or directory, ":~") .. (root and " (git)" or "")
      if state then state.root_directory, state.root = directory, view.root end
    else view.root = state.root end
    view.name = vim.fn.fnamemodify(name, ":t")
    if view.name == "" then view.name = "[No Name]" end
    local tasks, _, _, err, directives, candidates = read(buf)
    view.error = err
    for _, task in ipairs(tasks or {}) do
      local record = state and state.records[task.id]
      if record and record.mode ~= task.mode then record = nil end
      local phase = document.pending[task.mode] and "new" or "complete"
      if record and record.mode == task.mode then phase = record.phase end
      if task.tags:find("#needs-", 1, true) and not (state and state.active and state.active.id == task.id) then phase = "needs input" end
      local tags, seen = {}, {}
      for tag in (task.tags .. " " .. table.concat(task.instructions, " ")):gmatch("#[%w_-]+") do
        if not seen[tag] then tags[#tags + 1], seen[tag] = tag, true end
      end
      local detail = record and record.detail
      if phase == "complete" and task.mode ~= "built" then detail = "Ready to build" end
      view.tasks[#view.tasks + 1] = { id = task.id, first = task.first, phase = phase,
        title = task.instructions[1] or task.id, tags = table.concat(tags, " "), detail = detail }
    end
    for _, directive in ipairs(directives or {}) do
      if not directive.continuation then
        view.tasks[#view.tasks + 1] = { first = directive.first, phase = directive.error and "needs input" or "new",
          title = directive.instruction ~= "" and directive.instruction or "Incomplete directive", tags = directive.mode and "#" .. directive.mode or "", raw = true }
      end
    end
    for _, candidate in ipairs(candidates or {}) do
      view.tasks[#view.tasks + 1] = { first = candidate.first, phase = "new (candidate)", title = candidate.title, tags = "TODO", candidate = true }
    end
    for _, suggestion in ipairs(state and state.suggestions or {}) do
      local parent = find(tasks, suggestion.parent)
      if parent then view.tasks[#view.tasks + 1] = { first = parent.first, phase = "new (candidate)", title = suggestion.title, tags = "agent suggestion", candidate = true } end
    end
  end
  if state then
    view.enabled, view.message, view.model = state.enabled, state.status, state.model or vim.env.WALKER_MODEL
    view.task_usage = accounting.lines(state.usage, config.token_budget)
    view.usage_summary = accounting.summary(state.usage, config.token_budget)
    local function clock(value) return value and os.date("%H:%M:%S", value) or "—" end
    view.times = "Task " .. clock(state.last_task_at) .. " · Edit " .. clock(state.last_edit_at)
  end
  if balance.infos then
    for _, info in ipairs(balance.infos) do view.balance[#view.balance + 1] = info.currency .. " " .. info.total_balance end
    view.balance[#view.balance + 1] = "Updated " .. os.date("%H:%M:%S", balance.updated)
    if balance.message then view.balance[#view.balance + 1] = balance.message end
  else view.balance = { balance.message or "Unavailable", "Updated —" } end
  return view
end

function M.refresh_balance()
  if not config.balance.enabled or balance.job or #config.command == 0 then return end
  if balance.requested and os.time() - balance.requested < config.balance.refresh_seconds then return end
  balance.requested, balance.message = os.time(), "Refreshing…"
  local expected = balance
  local function stop(message)
    if balance ~= expected then return end
    if balance.job then balance.job.stop(); balance.job = nil end
    balance.message = message
    panel.refresh()
  end
  local handle, err = transport.start(config.command, function(message)
    if balance ~= expected then return end
    if message.type ~= "balance" or type(message.balance_infos) ~= "table" then
      stop("Balance unavailable for this provider/configuration"); return
    end
    local infos = {}
    for _, info in ipairs(message.balance_infos) do
      if type(info) ~= "table" or (info.currency ~= "USD" and info.currency ~= "CNY")
        or type(info.total_balance) ~= "string" or not info.total_balance:match("^%-?%d+%.?%d*$") then
        stop("Invalid provider balance response"); return
      end
      infos[#infos + 1] = { currency = info.currency, total_balance = info.total_balance }
    end
    if #infos == 0 then stop("Balance unavailable"); return end
    balance.infos, balance.updated = infos, os.time()
    stop(nil)
  end, function() stop("Balance lookup failed") end, function() stop("Balance lookup ended") end, config.max_message_bytes)
  if not handle then stop(err); return end
  balance.job = handle
  handle.send({ type = "balance", protocol = 1 })
  vim.defer_fn(function() if balance == expected and balance.job == handle then stop("Balance lookup timed out") end end, 10000)
end

function M.scope(first, last, id)
  local buf = vim.api.nvim_get_current_buf()
  if not require_document(buf, true) then return end
  attach(buf)
  local tasks, source, cs, err = read(buf)
  if not tasks then notify(err, vim.log.levels.WARN); return end
  local function needs_scope(item)
    return item.compact and (item.tags:find("#needs-scope", 1, true)
      or (item.mode == "build" and item.tags:find("#request%f[^%w_-]") and item.target.last == item.target.first + 1))
  end
  local task = id and id ~= "" and find(tasks, id) or nil
  if not task then
    for _, item in ipairs(tasks) do
      if needs_scope(item) then
        if task then notify("Supply the task ID shown beside the scope question"); return end
        task = item
      end
    end
  end
  if not task or not needs_scope(task) then
    notify("Choose a task waiting for scope"); return
  end
  if first < 1 or last < first or last > #source then notify("Select a valid passage"); return end
  for _, item in ipairs(tasks) do
    if (first <= item.last and last >= item.first) or (first <= item.target.last and last >= item.target.first) then
      notify("Select text outside existing task boundaries", vim.log.levels.WARN); return
    end
  end
  local result = {}
  for _, line in ipairs(task.result) do
    if not line:match("^Walker question %[%s*needs%-input%]") and not line:match("^Select it and run") then result[#result + 1] = line end
  end
  local inserted = document.compact(task.id, task.mode, task.instructions[1], document.slice(source, first, last), result, cs)
  local replacements = { { first = first, last = last, lines = inserted }, { first = task.first, last = task.last, lines = {} } }
  table.sort(replacements, function(a, b) return a.first > b.first end)
  local candidate = vim.deepcopy(source)
  for _, replacement in ipairs(replacements) do
    for _ = replacement.first, replacement.last do table.remove(candidate, replacement.first) end
    for row = #replacement.lines, 1, -1 do table.insert(candidate, replacement.first, replacement.lines[row]) end
  end
  local parsed, _, parse_err = document.scan(candidate, cs)
  if not parsed then notify(parse_err, vim.log.levels.WARN); return end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, candidate)
  states[buf].records[task.id] = nil
  panel.refresh(buf)
  notify("Scope assigned. Run :WalkerRun or let an enabled trigger start it.")
end

function M.promote(buf, id)
  if not require_document(buf, true) then return end
  attach(buf)
  local state = states[buf]
  if not state.enabled then notify("Disabled; use :WalkerEnable first"); return end
  if state.active or state.confirmation then notify("A task is already active; cancel it first"); return end
  local tasks, lines, cs = read(buf)
  local task = find(tasks, id)
  if not task or (task.mode ~= "planned" and task.mode ~= "reviewed") then notify("Choose a completed plan or review"); return end
  -- Normalize any inline continuation before moving its result into the target.
  if not normalize(buf) then notify(state.status, vim.log.levels.WARN); return end
  tasks, lines, cs = read(buf)
  task = find(tasks, id)
  local candidate = task.mode == "build" and lines or document.promote(lines, task, cs)
  local parsed, _, err = document.scan(candidate, cs)
  if not parsed then notify(err, vim.log.levels.WARN); return end
  state.applying = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, candidate)
  state.applying = false
  state.attempted[id] = nil
  evaluate(buf, true, id)
end

function M.build(id)
  local buf = vim.api.nvim_get_current_buf()
  if not require_document(buf, true) then return end
  local task = selected_task(buf, id)
  if not task then notify("Place the cursor in a completed plan/review or supply its ID"); return end
  if task.mode == "build" then M.run(task.id) else M.promote(buf, task.id) end
end

function M.create(first, last, args)
  local buf = vim.api.nvim_get_current_buf()
  if not require_document(buf, true) then return end
  local source = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if first < 1 or last < first or last > #source then notify("Select a valid passage first"); return end
  local cs, tick = vim.bo[buf].commentstring, vim.api.nvim_buf_get_changedtick(buf)
  local mode, instruction = vim.trim(args or ""):match("^(%S+)%s*(.*)$")
  if mode then
    mode = mode:gsub("^#", "")
    if not document.pending[mode] then
      notify("Use :WalkerTask, or :WalkerTask plan|review|build <instruction>", vim.log.levels.WARN); return
    end
  end

  -- Selecting an existing task means continue it, not nest another task or
  -- silently widen its authority to the entire selection.
  local existing = document.scan(source, cs)
  local overlaps = {}
  for _, task in ipairs(existing or {}) do
    if (first <= task.last and last >= task.first) or (first <= task.target.last and last >= task.target.first) then overlaps[#overlaps + 1] = task end
  end
  if #overlaps > 0 then
    if #overlaps > 1 then notify("Selection contains multiple tasks; place the cursor in one and use :WalkerRun"); return end
    if (instruction and instruction ~= "") or (mode and mode ~= "build") then
      notify("This passage already has a task. Edit its instructions, then use :WalkerRun or :WalkerBuild."); return
    end
    attach(buf)
    run_existing(buf, overlaps[1])
    return
  end

  -- Consume only a shorthand at the selection's first line or immediately above
  -- it (allowing blank lines). Never guess an entire-document target.
  local directive_row = first
  local directive, directive_err = document.shorthand(source[first], cs)
  if not directive and not directive_err then
    directive_row = first - 1
    while directive_row > 0 and source[directive_row]:match("^%s*$") do directive_row = directive_row - 1 end
    if directive_row > 0 then directive, directive_err = document.shorthand(source[directive_row], cs) end
  end
  if directive_err then notify(directive_err, vim.log.levels.WARN); return end
  local target_first, replace_first = first, first
  local sanitized = vim.deepcopy(source)
  if directive then
    mode = mode or directive.mode
    if not instruction or instruction == "" then instruction = directive.instruction end
    replace_first = directive_row
    if directive_row == first then target_first = first + 1 end
    sanitized[directive_row] = document.wrap("", cs)
  end
  if target_first > last then notify("Select the passage as well as the @walker directive", vim.log.levels.WARN); return end
  local tasks, _, err = document.scan(sanitized, cs)
  if not tasks then notify(err, vim.log.levels.WARN); return end
  for _, task in ipairs(tasks) do
    if (replace_first <= task.last and last >= task.first) or (replace_first <= task.target.last and last >= task.target.first) then
      notify("Task scopes cannot overlap", vim.log.levels.WARN); return
    end
  end
  attach(buf)
  local state, prompt = states[buf], {}
  state.prompt = prompt
  local function valid()
    if states[buf] ~= state or state.prompt ~= prompt then return false end
    if not require_document(buf, true) then state.prompt = nil; return false end
    if vim.api.nvim_buf_get_changedtick(buf) ~= tick or vim.bo[buf].commentstring ~= cs then
      state.prompt = nil
      notify("Document changed while the prompt was open; select the passage again", vim.log.levels.WARN)
      return false
    end
    return true
  end
  local function commit(chosen_mode, goal)
    if not valid() then return end
    state.prompt = nil
    if goal == nil or vim.trim(goal) == "" then return end
    if not document.is_lines({ goal }) then notify("Instruction must be a single line", vim.log.levels.WARN); return end
    local _, right = document.wrapper(cs)
    local closer = vim.trim(right)
    if closer ~= "" and goal:find(closer, 1, true) then
      notify("Instruction cannot close its comment wrapper", vim.log.levels.WARN); return
    end
    local id
    repeat
      sequence = sequence + 1
      id = "w" .. os.time() .. "-" .. sequence
    until not find(tasks, id)
    local inserted = document.compact(id, chosen_mode, vim.trim(goal), document.slice(source, target_first, last), {}, cs)
    if directive and directive_row < first then
      for row = first - 1, directive_row + 1, -1 do table.insert(inserted, 1, source[row]) end
    end
    local candidate = document.slice(source, 1, replace_first - 1)
    vim.list_extend(candidate, inserted)
    vim.list_extend(candidate, document.slice(source, last + 1, #source))
    local parsed, _, parse_err = document.scan(candidate, cs)
    if not parsed then notify(parse_err, vim.log.levels.WARN); return end
    vim.api.nvim_buf_set_lines(buf, replace_first - 1, last, false, inserted)
    notify("Created " .. id .. ". Run :WalkerRun in the task or passage to start.")
  end
  local function ask_instruction(chosen_mode)
    if not valid() then return end
    if not chosen_mode then state.prompt = nil; return end
    if not document.pending[chosen_mode] then state.prompt = nil; return end
    if instruction and vim.trim(instruction:gsub("#[%w_-]+", "")) ~= "" then
      commit(chosen_mode, instruction)
    else
      vim.ui.input({ prompt = "Walker " .. chosen_mode .. ": what should the agent do? ", default = instruction or "" }, function(goal)
        commit(chosen_mode, goal)
      end)
    end
  end
  if mode then ask_instruction(mode)
  else vim.ui.select({ "plan", "review", "build" }, { prompt = "Walker task mode:" }, ask_instruction) end
end

function M.setup(options)
  for buf in pairs(states) do cancel(buf, "Reconfigured") end
  states = {}
  if balance.job then balance.job.stop() end
  session_usage, balance = accounting.new(), { message = "Unavailable (balance lookup disabled)" }
  if interval_timer then interval_timer:stop(); interval_timer:close(); interval_timer = nil end
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  assert(type(config.command) == "table" and vim.islist(config.command), "walker.command must be an argv array")
  for _, arg in ipairs(config.command) do assert(type(arg) == "string", "walker.command entries must be strings") end
  assert(type(config.brief) == "string", "walker.brief must be a string")
  assert(type(config.enabled) == "boolean" and type(config.confirm_build) == "boolean", "walker enabled/confirm_build must be boolean")
  assert(type(config.panel.width) == "number" and config.panel.width >= 24 and config.panel.width % 1 == 0, "walker.panel.width must be an integer >= 24")
  assert(type(config.balance.enabled) == "boolean" and type(config.balance.refresh_seconds) == "number" and config.balance.refresh_seconds >= 10,
    "walker.balance needs enabled boolean and refresh_seconds >= 10")
  if config.pricing then
    assert(type(config.pricing.model) == "string" and type(config.pricing.currency) == "string", "pricing requires model and currency")
    for _, key in ipairs({ "input_per_million", "cached_input_per_million", "output_per_million" }) do
      assert(type(config.pricing[key]) == "number" and config.pricing[key] >= 0 and config.pricing[key] < math.huge, "Invalid pricing." .. key)
    end
  end
  if config.balance.enabled then balance.message = "Not fetched (open panel or :WalkerBalance)" end
  for _, name in ipairs({ "directive", "save", "interval", "idle" }) do
    assert(type(config.triggers[name]) == "boolean", "walker.triggers." .. name .. " must be boolean")
  end
  for _, key in ipairs({ "debounce_ms", "idle_ms", "interval_ms", "cooldown_ms", "task_timeout_ms", "max_message_bytes", "max_task_bytes", "max_requests", "max_output_tokens", "token_budget" }) do
    assert(type(config[key]) == "number" and config[key] >= 1 and config[key] % 1 == 0, "walker." .. key .. " must be a positive integer")
  end
  local group = vim.api.nvim_create_augroup("Walker", { clear = true })
  panel.setup({ view = M.view, balance = M.refresh_balance,
    run = function(buf, task)
      if task.candidate then notify("Select this candidate's passage and use :WalkerTask to authorize work")
      elseif task.raw then normalize(buf); panel.refresh(buf)
       else
         local current = find(read(buf), task.id)
         if current then run_existing(buf, current) end
       end
    end,
    cancel = function(buf, task)
      local state = states[buf]
      if state and ((state.active and state.active.id == task.id) or (state.confirmation and state.confirmation.id == task.id)) then
        local mode = state.records[task.id] and state.records[task.id].mode
        cancel(buf)
        state.records[task.id] = { phase = "cancelled", mode = mode, detail = "Cancelled" }
        panel.refresh(buf)
      end
    end,
    build = function(buf, task) M.promote(buf, task.id) end,
  }, config.panel)
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, { group = group, callback = function(event)
    attach(event.buf)
    if is_document(event.buf) then panel.follow(event.buf) end
  end })
  vim.api.nvim_create_autocmd("BufWritePost", { group = group, callback = function(event)
    if config.triggers.save then evaluate(event.buf, false) end
  end })
  vim.api.nvim_create_autocmd("InsertLeave", { group = group, callback = function(event)
    local state = states[event.buf]
    if config.triggers.directive or config.triggers.idle or (state and state.waiting_insert) then evaluate(event.buf, false) end
  end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    for buf in pairs(states) do cancel(buf, "Exiting") end
    if balance.job then balance.job.stop() end
  end })
  local commands = {
    WalkerRun = { function(opts) M.run(opts.args) end, { nargs = "?" } },
    WalkerBuild = { function(opts) M.build(opts.args) end, { nargs = "?" } },
    WalkerCancel = { M.cancel, {} }, WalkerEnable = { M.enable, {} }, WalkerDisable = { M.disable, {} },
    WalkerStatus = { function() notify(vim.inspect(M.status())) end, {} },
    WalkerPanel = { function()
      local buf = vim.api.nvim_get_current_buf()
      if require_document(buf) then attach(buf); panel.toggle(buf) end
    end, {} },
    WalkerBalance = { M.refresh_balance, {} },
    WalkerScope = { function(opts)
      if opts.range == 0 then notify("Select the passage to authorize first"); return end
      M.scope(opts.line1, opts.line2, opts.args)
    end, { nargs = "?", range = true } },
    WalkerTask = { function(opts)
      if not require_document(vim.api.nvim_get_current_buf(), true) then return end
      if opts.range == 0 then
        local task = selected_task(vim.api.nvim_get_current_buf())
        if task then M.create(task.first, task.last, opts.args)
        else notify("Select an explicit passage first", vim.log.levels.WARN) end
        return
      end
      M.create(opts.line1, opts.line2, opts.args)
    end, { nargs = "*", range = true, complete = function() return { "plan", "review", "build" } end } },
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

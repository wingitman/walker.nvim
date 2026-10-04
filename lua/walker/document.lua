-- Inline markers are the persistent source of task identity and scope.
local M = {}
local modes = { plan = true, review = true, build = true, planned = true, reviewed = true, built = true }
M.pending = { plan = true, review = true, build = true }
M.completed = { plan = "planned", review = "reviewed", build = "built" }

function M.prose(commentstring)
  return commentstring == "" or (commentstring or ""):find("<!--", 1, true) ~= nil
end

function M.result_line(text, commentstring)
  return M.prose(commentstring) and text or M.wrap(text, commentstring)
end

function M.wrapper(commentstring)
  local left, right = (commentstring or ""):match("^(.-)%%s(.-)$")
  return left or "", right or ""
end

function M.wrap(text, commentstring)
  local left, right = M.wrapper(commentstring)
  return left .. text .. right
end

function M.unwrap(line, commentstring)
  local left, right = M.wrapper(commentstring)
  if line:sub(1, #left) ~= left then return nil end
  if #right > 0 and line:sub(-#right) ~= right then return nil end
  return line:sub(#left + 1, #line - #right)
end

-- Shorthand discovery never grants authority over an unspecified passage.
function M.shorthand(line, commentstring)
  local text = vim.trim(M.unwrap(line, commentstring) or line)
  local rest = text:match("^@walker%s+(.*)$")
  if text == "@walker" then rest = "" end
  if rest == nil or rest:match("^[%w_-]+%s+#") then return nil end
  local mode, count = nil, 0
  local instruction = rest:gsub("#([%w_-]+)", function(tag)
    if modes[tag] then
      mode, count = tag, count + 1
      return ""
    end
    return "#" .. tag
  end)
  if count > 1 or (mode and not M.pending[mode]) then
    return nil, "Shorthand needs at most one active mode: #plan, #review, or #build"
  end
  if not mode and vim.trim(instruction:gsub("#[%w_-]+", "")) ~= "" then mode = "build" end
  return { mode = mode, instruction = vim.trim(instruction) }
end

local function slice(lines, first, last)
  local result = {}
  for i = first, last do result[#result + 1] = lines[i] end
  return result
end
M.slice = slice

-- Parse strictly: malformed/duplicate boundaries must never expand edit authority.
function M.parse(lines, commentstring)
  local tasks, targets, order = {}, {}, {}
  local open, target
  for i, line in ipairs(lines) do
    local text = M.unwrap(line, commentstring)
    local reserved = text and text:match("^@[%w_-]+")
    if reserved == "@walker" then
      if open or target then return nil, "Nested Walker task at line " .. i end
      local id, tags = text:match("^@walker ([%w_-]+)%s+(.+)$")
      if not id then
        return nil, "Incomplete Walker header at line " .. i
          .. ". Select its passage and run :WalkerTask to expand shorthand; structured headers use @walker <id> #plan|#review|#build"
      end
      if tasks[id] then return nil, "Duplicate task ID '" .. id .. "' at line " .. i end
      local compact_tags, goal = tags:match("^(.-)%s+|%s*(.*)$")
      if compact_tags then tags = compact_tags end
      local mode, count = nil, 0
      for tag in tags:gmatch("#([%w_-]+)") do
        if modes[tag] then mode, count = tag, count + 1 end
      end
      if count ~= 1 then return nil, "Task " .. id .. " needs exactly one mode/status tag" end
      open = { id = id, mode = mode, tags = tags, first = i, instructions = goal and { goal } or {},
        result = {}, compact = goal ~= nil }
      tasks[id], order[#order + 1] = open, open
    elseif reserved == "@walker-target" then
      if open or target then return nil, "Nested Walker target at line " .. i end
      local id = text:match("^@walker%-target ([%w_-]+)$")
      if not id or targets[id] then return nil, "Invalid or duplicate target at line " .. i end
      target = { id = id, first = i }
      targets[id] = target
    elseif reserved == "@endwalker-target" then
      local id = text:match("^@endwalker%-target ([%w_-]+)$")
      if not target or target.id ~= id then return nil, "Mismatched target end at line " .. i end
      target.last, target = i, nil
    elseif reserved == "@endwalker" then
      if text ~= "@endwalker" or not open or not open.result_marker then
        return nil, "Invalid task end at line " .. i
      end
      open.last, open = i, nil
    elseif reserved == "@result" then
      if text ~= "@result" or not open or open.result_marker then
        return nil, "Invalid result marker at line " .. i
      end
      open.result_marker = i
      if open.compact then open.target = { first = open.first, last = i } end
    elseif open then
      if open.result_marker then
        if text == nil and not M.prose(commentstring) then return nil, "Uncommented task content at line " .. i end
        open.result[#open.result + 1] = text or line
      elseif not open.compact then
        if text == nil then return nil, "Uncommented task content at line " .. i end
        open.instructions[#open.instructions + 1] = text
      end
    end
  end
  if open or target then return nil, "Unclosed Walker block" end
  for _, task in ipairs(order) do
    if task.compact and targets[task.id] then return nil, "Duplicate target for compact task " .. task.id end
    task.target = task.target or targets[task.id]
    if not task.target then return nil, "Missing target for " .. task.id end
  end
  for id in pairs(targets) do
    if not tasks[id] then return nil, "Missing task for target " .. id end
  end
  return order
end

-- A compact task needs only a directive, a result separator, and an end anchor.
-- These persistent anchors make reopening/line movement safe without guessing.
function M.compact(id, mode, goal, target, result, cs, flags)
  local lines = { M.wrap("@walker " .. id .. " #" .. mode .. (flags or "") .. " | " .. goal, cs) }
  vim.list_extend(lines, target)
  lines[#lines + 1] = M.wrap("@result", cs)
  for _, text in ipairs(result) do lines[#lines + 1] = M.result_line(text, cs) end
  lines[#lines + 1] = M.wrap("@endwalker", cs)
  return lines
end

-- Discover shorthand outside existing task/target blocks and Markdown fences.
-- Ordinary TODOs are candidates only; never convert them into agent authority.
function M.scan(lines, cs)
  local clean, directives, candidates = vim.deepcopy(lines), {}, {}
  local protected, fence, i = false, nil, 1
  local owner, adjacent, in_result
  while i <= #lines do
    local text = vim.trim(M.unwrap(lines[i], cs) or lines[i])
    local fence_run = M.prose(cs) and text:match("^([`~][`~][`~]+)")
    if fence_run then
      if not fence then fence = fence_run
      elseif fence_run:sub(1, 1) == fence:sub(1, 1) and #fence_run >= #fence then fence = nil end
      if not protected then clean[i] = M.wrap("", cs) end
      adjacent = nil
    elseif fence then
      if not protected then clean[i] = M.wrap("", cs) end
    elseif not fence then
      local continuation = (in_result and owner) or (not protected and adjacent)
      if continuation and (text == "#build" or text == "@walker #build") then
        directives[#directives + 1] = { first = i, last = i, mode = "build", instruction = "Continue plan/review", continuation = continuation }
        clean[i] = M.result_line("", cs)
      elseif text:match("^@walker [%w_-]+%s+#") or text:match("^@walker%-target ") then
        protected = true
        local id, tags = text:match("^@walker ([%w_-]+)%s+([^|]+)")
        owner = id and (tags:match("#planned%f[^%w_-]") or tags:match("#reviewed%f[^%w_-]")) and id or nil
        adjacent, in_result = nil, false
      elseif text == "@result" then
        in_result = true
      elseif text == "@endwalker" or text:match("^@endwalker%-target ") then
        protected = false
        adjacent, owner, in_result = owner, nil, false
      elseif not protected and (text == "@walker" or text:match("^@walker%s")) then
        local first, last = i, i
        local rest = text:gsub("^@walker%s*", "")
        -- One optional mode line after blank lines supports the original example.
        local next_row = i + 1
        while next_row <= #lines and lines[next_row]:match("^%s*$") do next_row = next_row + 1 end
        local next_text = lines[next_row] and vim.trim(M.unwrap(lines[next_row], cs) or lines[next_row])
        if next_text and next_text:match("^#") then
          local tag = next_text:match("^#([%w_-]+)")
          if modes[tag] then rest, last = rest .. " " .. next_text, next_row end
        end
        local mode, count = nil, 0
        local goal = rest:gsub("#([%w_-]+)", function(tag)
          if modes[tag] then mode, count = tag, count + 1; return "" end
          return "#" .. tag
        end)
        local err = count > 1 and "Use one mode: #plan, #review, or #build" or nil
        directives[#directives + 1] = { first = first, last = last, mode = mode, instruction = vim.trim(goal), error = err }
        for row = first, last do clean[row] = M.wrap("", cs) end
        i = last
      elseif not protected and (text:match("%f[%w]TODO%f[^%w]") or text:match("%f[%w]FIXME%f[^%w]")) then
        candidates[#candidates + 1] = { first = i, title = text, candidate = true }
      end
      if not protected and text ~= "" and text ~= "@endwalker" and text ~= "#build" and text ~= "@walker #build" then adjacent = nil end
    end
    i = i + 1
  end
  local tasks, err = M.parse(clean, cs)
  return tasks, directives, err, candidates
end

-- A human-approved build reuses exactly this task's authority. An append-only
-- plan has no target yet: its own result becomes the implementation passage.
function M.promote(lines, task, cs)
  local candidate = vim.deepcopy(lines)
  candidate[task.first] = M.wrap(M.unwrap(lines[task.first], cs):gsub("#" .. task.mode .. "%f[^%w_-]", "#build", 1), cs)
  if task.target.last == task.target.first + 1 and #task.result > 0 then
    for _ = task.result_marker + 1, task.last - 1 do table.remove(candidate, task.result_marker + 1) end
    local at = task.target.first
    if at > task.result_marker then at = at - #task.result end
    for row = #task.result, 1, -1 do table.insert(candidate, at + 1, task.result[row]) end
  end
  return candidate
end

function M.snapshot(task, lines, brief)
  local value = {
    id = task.id, mode = task.mode, tags = task.tags, brief = brief,
    instructions = task.instructions, result = task.result,
    target = slice(lines, task.target.first + 1, task.target.last - 1),
  }
  if task.tags:find("#request%f[^%w_-]") then
    -- Context is read-only, not an inferred edit scope. Include existing code,
    -- including other completed tasks, so requests can refer to "this code".
    value.context = slice(lines, 1, task.first - 1)
    vim.list_extend(value.context, slice(lines, task.last + 1, #lines))
  end
  return value
end

-- One compact splice per changed field, relative to the preceding revision.
function M.delta(previous, current)
  local changes = {}
  for _, field in ipairs({ "instructions", "result", "target", "context" }) do
    local a, b = previous[field] or {}, current[field] or {}
    local prefix, suffix = 0, 0
    while prefix < #a and prefix < #b and a[prefix + 1] == b[prefix + 1] do prefix = prefix + 1 end
    while suffix < #a - prefix and suffix < #b - prefix and a[#a - suffix] == b[#b - suffix] do
      suffix = suffix + 1
    end
    if prefix ~= #a or prefix ~= #b then
      changes[field] = { start = prefix, delete = #a - prefix - suffix, lines = slice(b, prefix + 1, #b - suffix) }
    end
  end
  return changes
end

function M.is_lines(value)
  if type(value) ~= "table" or not vim.islist(value) then return false end
  for _, line in ipairs(value) do
    if type(line) ~= "string" or line:find("[\r\n%z]") then return false end
  end
  return true
end

-- Return a whole candidate buffer; caller validates and applies one atomic edit.
function M.propose(lines, task, edit, commentstring)
  if not M.is_lines(edit.result) then return nil, "result must be an array of lines" end
  if edit.target ~= nil and (task.mode ~= "build" or not M.is_lines(edit.target)) then
    return nil, "Only build tasks may replace their target (with an array of lines)"
  end
  if type(edit.done) ~= "boolean" then return nil, "done must be boolean" end
  if edit.blocked ~= nil and (type(edit.blocked) ~= "boolean" or (edit.blocked and edit.done)) then
    return nil, "A blocked question cannot be marked complete"
  end
  if edit.blocked then
    local prior = M.slice(edit.result, 1, #task.result)
    if not vim.deep_equal(prior, task.result) then
      local appended = vim.deepcopy(task.result)
      appended[#appended + 1] = "Walker question [needs-input]:"
      vim.list_extend(appended, edit.result)
      edit.result = appended
    elseif not table.concat(edit.result, " "):find("[needs-input]", 1, true) then
      table.insert(edit.result, #task.result + 1, "Walker question [needs-input]:")
    end
  end
  local replacements = {}
  local result = {}
  local _, right = M.wrapper(commentstring)
  local closer = vim.trim(right)
  for _, line in ipairs(edit.result) do
    if closer ~= "" and line:find(closer, 1, true) then
      return nil, "Result cannot close its comment wrapper"
    end
    result[#result + 1] = M.result_line(line, commentstring)
  end
  replacements[#replacements + 1] = { first = task.result_marker + 1, last = task.last - 1, lines = result }
  if edit.target ~= nil then
    replacements[#replacements + 1] = { first = task.target.first + 1, last = task.target.last - 1, lines = edit.target }
  end
  if edit.done or edit.blocked then
    local header = M.unwrap(lines[task.first], commentstring)
    if edit.done then
      header = header:gsub("#" .. task.mode .. "%f[^%w_-]", "#" .. M.completed[task.mode], 1)
      header = header:gsub("%s+#needs%-input%f[^%w_-]", "", 1)
    elseif not task.tags:find("#needs-input", 1, true) then
      header = header:gsub("#" .. task.mode .. "%f[^%w_-]", "#" .. task.mode .. " #needs-input", 1)
    end
    replacements[#replacements + 1] = { first = task.first, last = task.first, lines = { M.wrap(header, commentstring) } }
  end
  table.sort(replacements, function(a, b) return a.first > b.first end)
  local candidate = slice(lines, 1, #lines)
  for _, replacement in ipairs(replacements) do
    for _ = replacement.first, replacement.last do table.remove(candidate, replacement.first) end
    for j = #replacement.lines, 1, -1 do table.insert(candidate, replacement.first, replacement.lines[j]) end
  end
  local parsed, _, err = M.scan(candidate, commentstring)
  if not parsed then return nil, err end
  -- Agent output may not introduce new tasks or reserved boundary markers.
  for _, replacement in ipairs({ edit.result, edit.target or {} }) do
    for _, line in ipairs(replacement) do
      local text = vim.trim(M.unwrap(line, commentstring) or line)
      if text == "#build" then return nil, "Agent output cannot introduce build commands" end
      for _, marker in ipairs({ "walker", "endwalker", "walker-target", "endwalker-target", "result" }) do
        if text:match("^@" .. marker:gsub("%-", "%%-") .. "%f[^%w_-]") then
          return nil, "Agent output cannot introduce Walker markers"
        end
      end
    end
  end
  return candidate
end

return M

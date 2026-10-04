-- Inline markers are the persistent source of task identity and scope.
local M = {}
local modes = { plan = true, review = true, build = true, planned = true, reviewed = true, built = true }
M.pending = { plan = true, review = true, build = true }
M.completed = { plan = "planned", review = "reviewed", build = "built" }

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
      if not id or tasks[id] then return nil, "Invalid or duplicate task at line " .. i end
      local mode, count = nil, 0
      for tag in tags:gmatch("#([%w_-]+)") do
        if modes[tag] then mode, count = tag, count + 1 end
      end
      if count ~= 1 then return nil, "Task " .. id .. " needs exactly one mode/status tag" end
      open = { id = id, mode = mode, tags = tags, first = i, instructions = {}, result = {} }
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
    elseif open then
      if text == nil then return nil, "Uncommented task content at line " .. i end
      local destination = open.result_marker and open.result or open.instructions
      destination[#destination + 1] = text
    end
  end
  if open or target then return nil, "Unclosed Walker block" end
  for _, task in ipairs(order) do
    task.target = targets[task.id]
    if not task.target then return nil, "Missing target for " .. task.id end
  end
  for id in pairs(targets) do
    if not tasks[id] then return nil, "Missing task for target " .. id end
  end
  return order
end

function M.snapshot(task, lines, brief)
  return {
    id = task.id, mode = task.mode, tags = task.tags, brief = brief,
    instructions = task.instructions, result = task.result,
    target = slice(lines, task.target.first + 1, task.target.last - 1),
  }
end

-- One compact splice per changed field, relative to the preceding revision.
function M.delta(previous, current)
  local changes = {}
  for _, field in ipairs({ "instructions", "result", "target" }) do
    local a, b = previous[field], current[field]
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
  local replacements = {}
  local result = {}
  local _, right = M.wrapper(commentstring)
  local closer = vim.trim(right)
  for _, line in ipairs(edit.result) do
    if closer ~= "" and line:find(closer, 1, true) then
      return nil, "Result cannot close its comment wrapper"
    end
    result[#result + 1] = M.wrap(line, commentstring)
  end
  replacements[#replacements + 1] = { first = task.result_marker + 1, last = task.last - 1, lines = result }
  if edit.target ~= nil then
    replacements[#replacements + 1] = { first = task.target.first + 1, last = task.target.last - 1, lines = edit.target }
  end
  if edit.done then
    local header = M.unwrap(lines[task.first], commentstring)
    header = header:gsub("#" .. task.mode .. "%f[^%w_-]", "#" .. M.completed[task.mode], 1)
    replacements[#replacements + 1] = { first = task.first, last = task.first, lines = { M.wrap(header, commentstring) } }
  end
  table.sort(replacements, function(a, b) return a.first > b.first end)
  local candidate = slice(lines, 1, #lines)
  for _, replacement in ipairs(replacements) do
    for _ = replacement.first, replacement.last do table.remove(candidate, replacement.first) end
    for j = #replacement.lines, 1, -1 do table.insert(candidate, replacement.first, replacement.lines[j]) end
  end
  local parsed, err = M.parse(candidate, commentstring)
  if not parsed then return nil, err end
  -- Agent output may not introduce new tasks or reserved boundary markers.
  for _, replacement in ipairs({ edit.result, edit.target or {} }) do
    for _, line in ipairs(replacement) do
      local text = M.unwrap(line, commentstring) or line
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

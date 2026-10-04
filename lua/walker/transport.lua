local M = {}

-- JSON-lines over stdin/stdout. Commands are argv arrays, never shell strings.
function M.start(command, on_message, on_error, on_exit, max_bytes)
  local pending, closed, job = "", false, nil
  local handle = {}
  function handle.send(message)
    if closed then return false end
    local ok = pcall(vim.fn.chansend, job, vim.json.encode(message) .. "\n")
    return ok
  end
  function handle.stop()
    if closed then return end
    closed = true
    pcall(vim.fn.jobstop, job)
  end
  local ok
  ok, job = pcall(vim.fn.jobstart, command, {
    on_stdout = function(_, data)
      if closed then return end
      pending = pending .. table.concat(data, "\n")
      while true do
        local boundary = pending:find("\n", 1, true)
        if not boundary then break end
        local line = pending:sub(1, boundary - 1)
        pending = pending:sub(boundary + 1)
        if #line > max_bytes then on_error("Agent message exceeds size limit"); return end
        if line ~= "" then
          local ok, message = pcall(vim.json.decode, line)
          if not ok or type(message) ~= "table" then on_error("Invalid agent JSON"); return end
          on_message(message)
          if closed then return end
        end
      end
      if #pending > max_bytes then on_error("Agent message exceeds size limit") end
    end,
    -- Do not display arbitrary stderr: it may contain credentials or document text.
    on_stderr = function() end,
    on_exit = function(_, code)
      if closed then return end
      closed = true
      on_exit(code)
    end,
  })
  if not ok or job <= 0 then return nil, "Could not start agent command; check executable and argv" end
  return handle
end

return M

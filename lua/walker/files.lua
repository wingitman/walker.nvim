-- The editor owns this capability; adapters only propose one sibling file.
local M = {}
local uv = vim.uv

function M.directory(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return nil end
  return uv.fs_realpath(vim.fs.dirname(name))
end

local function identity(a, b)
  return a and b and a.dev == b.dev and a.ino == b.ino
end

local function available(path)
  if uv.fs_lstat(path) then return nil, "Destination already exists (files and symlinks are never overwritten)" end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" then
      local parent = uv.fs_realpath(vim.fs.dirname(name))
      if parent and parent .. "/" .. vim.fs.basename(name) == path then
        return nil, "Destination already has a Neovim buffer; save or close it first"
      end
    end
  end
  return true
end

function M.prepare(directory, proposal, limit)
  if not directory or uv.fs_realpath(directory) ~= directory then return nil, "Name the document in an existing directory first" end
  if type(proposal) ~= "table" or type(proposal.name) ~= "string" or #proposal.name > 200
    or not proposal.name:match("^[%w][%w_.-]*$") then
    return nil, "File creation requires a simple sibling filename, not a path"
  end
  if not require("walker.document").is_lines(proposal.lines) then return nil, "File content must be an array of lines" end
  local content = table.concat(proposal.lines, "\n") .. (#proposal.lines > 0 and "\n" or "")
  if #content > limit then return nil, "Proposed file exceeds max_task_bytes" end
  local path = directory .. "/" .. proposal.name
  local ok, err = available(path)
  if not ok then return nil, err end
  return { path = path, directory = directory, parent = uv.fs_stat(directory), content = content }
end

function M.write(prepared)
  if uv.fs_realpath(prepared.directory) ~= prepared.directory
    or not identity(prepared.parent, uv.fs_stat(prepared.directory)) then
    return nil, "Destination directory changed; request file creation again"
  end
  local ok, err = available(prepared.path)
  if not ok then return nil, err end
  -- Exclusive create rejects even dangling symlinks and late-arriving files.
  local fd, open_err = uv.fs_open(prepared.path, "wx", 384) -- private, non-executable; run scripts with python3
  if not fd then return nil, "Could not exclusively create file: " .. tostring(open_err) end
  local owned = uv.fs_fstat(fd)
  local offset = 0
  while offset < #prepared.content do
    local count, write_err = uv.fs_write(fd, prepared.content:sub(offset + 1), offset)
    if not count or count == 0 then err = write_err or "Short write"; break end
    offset = offset + count
  end
  if not err then
    local synced, sync_err = uv.fs_fsync(fd)
    if not synced then err = sync_err end
  end
  local closed, close_err = uv.fs_close(fd)
  err = err or (not closed and close_err or nil)
  if err then
    if identity(owned, uv.fs_lstat(prepared.path)) then uv.fs_unlink(prepared.path) end
    return nil, "Could not finish file creation: " .. tostring(err)
  end
  return prepared.path
end

return M

local M = {}
local panels, api, width = {}, nil, 44

local function valid(panel)
  return panel and vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_buf_is_valid(panel.buf)
end

local function redraw(panel)
  if not valid(panel) then return end
  local view = api.view(panel.source)
  local columns = vim.api.nvim_win_get_width(panel.win)
  local function compact(text)
    text = tostring(text):gsub("%c", " ")
    if vim.fn.strdisplaywidth(text) <= columns then return text end
    text = vim.fn.strcharpart(text, 0, columns - 1)
    while vim.fn.strdisplaywidth(text) >= columns do text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1) end
    return text .. "…"
  end
  local lines = { "Walker " .. (view.enabled and "[enabled]" or "[disabled]"), view.root, view.name,
    "Model " .. (view.model or "not reported"), "", "Tasks" }
  panel.rows = {}
  for _, task in ipairs(view.tasks) do
    lines[#lines + 1] = compact(string.format("- [%s] %s", task.phase, task.title))
    panel.rows[#lines] = task
    local step = task.detail or (task.candidate and "Not authorized" or task.phase == "complete" and "Done" or "Ready")
    if task.phase == "needs input" and not task.detail then step = "Answer inline" end
    lines[#lines + 1] = compact(string.format("  L%d %s", task.first, step))
    panel.rows[#lines] = task
  end
  if #view.tasks == 0 then lines[#lines + 1] = "No tasks. Write @walker #plan <goal>." end
  if view.error then lines[#lines + 1] = "Needs input: " .. view.error end
  vim.list_extend(lines, { "", "Usage:" })
  vim.list_extend(lines, view.usage_summary)
  lines[#lines + 1] = view.times
  vim.list_extend(lines, { "", "Balance:" })
  vim.list_extend(lines, view.balance)
  vim.list_extend(lines, { "", "Quick Reference", "<Enter> jump · r run/build · c cancel", "b build · B balance · q close",
    ":WalkerTask · :WalkerRun [id]", ":WalkerBuild [id] · :WalkerScope [id]",
    ":WalkerPanel · :WalkerBalance", ":WalkerEnable · :WalkerDisable", ":WalkerCancel · :WalkerStatus" })
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
end

function M.refresh(buf)
  for _, panel in pairs(panels) do
    if not buf or panel.source == buf then redraw(panel) end
  end
end

function M.follow(buf)
  local panel = panels[vim.api.nvim_get_current_tabpage()]
  if valid(panel) then
    panel.source, panel.source_win = buf, vim.api.nvim_get_current_win()
    redraw(panel)
  end
end

function M.toggle(buf)
  local tab = vim.api.nvim_get_current_tabpage()
  local panel = panels[tab]
  if valid(panel) then vim.api.nvim_win_close(panel.win, true); panels[tab] = nil; return end
  local source_win = vim.api.nvim_get_current_win()
  vim.cmd("botright " .. width .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  local panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, panel_buf)
  vim.bo[panel_buf].buftype, vim.bo[panel_buf].bufhidden = "nofile", "wipe"
  vim.bo[panel_buf].swapfile, vim.bo[panel_buf].filetype = false, "walker_panel"
  vim.wo[win].number, vim.wo[win].relativenumber = false, false
  vim.wo[win].wrap, vim.wo[win].winfixwidth = true, true
  vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
  panel = { buf = panel_buf, win = win, source = buf, source_win = source_win, rows = {} }
  panels[tab] = panel
  local function selected() return panel.rows[vim.api.nvim_win_get_cursor(win)[1]] end
  local function jump()
    local task = selected()
    if not task or not vim.api.nvim_buf_is_loaded(panel.source) then return end
    local dest = panel.source_win
    if not vim.api.nvim_win_is_valid(dest) then
      dest = nil
      for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do if candidate ~= win then dest = candidate; break end end
    end
    if not dest then return end
    vim.api.nvim_set_current_win(dest)
    vim.api.nvim_win_set_buf(dest, panel.source)
    vim.api.nvim_win_set_cursor(dest, { math.min(task.first, vim.api.nvim_buf_line_count(panel.source)), 0 })
  end
  local maps = {
    ["<CR>"] = jump,
    r = function() local task = selected(); if task then api.run(panel.source, task); redraw(panel) end end,
    c = function() local task = selected(); if task then api.cancel(panel.source, task); redraw(panel) end end,
    b = function() local task = selected(); if task then api.build(panel.source, task); redraw(panel) end end,
    B = function() api.balance(); redraw(panel) end,
    q = function() if valid(panel) then vim.api.nvim_win_close(win, true) end; panels[tab] = nil end,
  }
  for key, callback in pairs(maps) do vim.keymap.set("n", key, callback, { buffer = panel_buf, silent = true }) end
  redraw(panel)
  vim.api.nvim_set_current_win(source_win)
  api.balance()
end

function M.setup(callbacks, opts)
  for _, panel in pairs(panels) do if valid(panel) then pcall(vim.api.nvim_win_close, panel.win, true) end end
  panels, api, width = {}, callbacks, opts.width
end

return M

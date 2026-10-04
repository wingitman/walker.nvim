-- Runs under tests/test_e2e.py against its loopback provider.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local walker = require("walker")
local doc = require("walker.document")

local function run()
  vim.bo.commentstring = ""
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "original passage", "unrelated" })
  walker.setup({
    command = { "python3", "-B", vim.fn.getcwd() .. "/adapters/openai_agent.py" },
    confirm_build = false, debounce_ms = 20, token_budget = 10000,
  })
  walker.create(1, 1, "build #story Capitalize this passage")
  walker.run()
  vim.defer_fn(function()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local task = assert(doc.parse(lines, ""))[1]
    vim.api.nvim_buf_set_lines(0, task.target.first, task.target.last - 1, false, { "human edited passage" })
  end, 200)
  assert(vim.wait(10000, function() return not walker.status().active end, 10), "Agent timed out")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local task = assert(doc.parse(lines, ""))[1]
  assert(task.mode == "built", vim.inspect(walker.status()))
  assert(vim.deep_equal(doc.snapshot(task, lines, "").target, { "HUMAN EDITED PASSAGE" }))
  assert(lines[#lines] == "unrelated")
  assert(walker.status().tokens == 20, "Both calls must be accounted for")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then print(err); vim.cmd("cquit 1") else vim.cmd("qa!") end

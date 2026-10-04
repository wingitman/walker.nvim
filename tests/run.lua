vim.opt.runtimepath:prepend(vim.fn.getcwd())
local doc = require("walker.document")
local walker = require("walker")
local passed = 0
local notifications = {}
vim.notify = function(message) notifications[#notifications + 1] = message end

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), "Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end

local function lines(mode, cs)
  local result = {}
  for _, text in ipairs({ "@walker t1 #" .. mode .. " #story", "Preserve the meaning", "@result", "@endwalker", "@walker-target t1" }) do
    result[#result + 1] = doc.wrap(text, cs)
  end
  result[#result + 1] = "hello human"
  result[#result + 1] = doc.wrap("@endwalker-target t1", cs)
  result[#result + 1] = "outside"
  return result
end

local function setup(mode, scenario, options)
  walker.setup({ enabled = false })
  vim.cmd("enew!")
  vim.bo.commentstring = "-- %s"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines(mode, "-- %s"))
  walker.setup(vim.tbl_deep_extend("force", {
    command = { "python3", vim.fn.getcwd() .. "/tests/fake_agent.py", scenario or "complete" },
    confirm_build = false, debounce_ms = 20, cooldown_ms = 1,
    idle_ms = 40, interval_ms = 30, task_timeout_ms = 3000,
  }, options or {}))
end

local function current()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function task()
  local parsed, err = doc.parse(current(), vim.bo.commentstring)
  assert(parsed, err)
  return parsed[1]
end

local function wait_for(predicate)
  assert(vim.wait(4000, predicate, 5), "Timed out: " .. vim.inspect(walker.status()))
end

local function finish()
  wait_for(function() return not walker.status().active end)
end

local function run()
  test("parse plain text, line comments, and block comments", function()
    for _, cs in ipairs({ "", "-- %s", "<!-- %s -->", "/* %s */" }) do
      local source = lines("plan", cs)
      local parsed, err = doc.parse(source, cs)
      assert(parsed, err)
      eq(parsed[1].mode, "plan")
      eq(doc.snapshot(parsed[1], source, "brief").target, { "hello human" })
    end
  end)

  test("malformed, nested, duplicate and ambiguous tasks fail closed", function()
    local cases = {
      { "@walker x #plan #build" },
      { "@walker x #plan", "@result", "@endwalker" },
      { "@walker x #plan", "@walker y #plan" },
      { "@walker-target x", "@endwalker-target y" },
      { "@result" },
    }
    local duplicate = lines("plan", "")
    vim.list_extend(duplicate, lines("plan", ""))
    cases[#cases + 1] = duplicate
    for _, source in ipairs(cases) do assert(not doc.parse(source, "")) end
  end)

  test("compact deltas handle insertion, deletion and replacement", function()
    local previous = { instructions = {}, result = {}, target = { "a", "b", "c" } }
    local updated = { instructions = {}, result = { "plan" }, target = { "a", "new", "c" } }
    eq(doc.delta(previous, updated), {
      result = { start = 0, delete = 0, lines = { "plan" } },
      target = { start = 1, delete = 1, lines = { "new" } },
    })
    updated.target = {}
    eq(doc.delta(previous, updated).target, { start = 0, delete = 3, lines = {} })
    eq(doc.delta(updated, updated), {})
  end)

  test("plan/review authority and marker/comment injection rejected", function()
    for _, mode in ipairs({ "plan", "review" }) do
      local source = lines(mode, "")
      local parsed = assert(doc.parse(source, ""))[1]
      assert(not doc.propose(source, parsed, { result = {}, target = {}, done = true }, ""))
      assert(not doc.propose(source, parsed, { result = { "@walker evil #build" }, done = true }, ""))
      assert(not doc.propose(source, parsed, { result = { "two\nlines" }, done = true }, ""))
    end
    local source = lines("plan", "<!-- %s -->")
    local parsed = assert(doc.parse(source, "<!-- %s -->"))[1]
    assert(not doc.propose(source, parsed, { result = { "--> escaped" }, done = true }, "<!-- %s -->"))
  end)

  test("build writes result, replacement and completed status atomically", function()
    local source = lines("build", "-- %s")
    local parsed = assert(doc.parse(source, "-- %s"))[1]
    local changed = assert(doc.propose(source, parsed, { result = { "Built" }, target = { "new", "text" }, done = true }, "-- %s"))
    local rebuilt = assert(doc.parse(changed, "-- %s"))[1]
    eq(rebuilt.mode, "built")
    eq(rebuilt.result, { "Built" })
    eq(doc.snapshot(rebuilt, changed, "").target, { "new", "text" })
    eq(changed[#changed], "outside")
  end)

  test("manual plan completes inline without touching passage", function()
    setup("plan")
    walker.run()
    finish()
    eq(task().mode, "planned")
    eq(task().result, { "Agent notes" })
    eq(doc.snapshot(task(), current(), "").target, { "hello human" })
    eq(walker.status().tokens, 1)
  end)

  test("review cannot write target even through a misbehaving adapter", function()
    setup("review", "illegal")
    local before = current()
    walker.run()
    finish()
    eq(current(), before)
    assert(walker.status().message:match("Rejected"))
  end)

  test("human edit before debounce invalidates stale response and is resent", function()
    setup("build", "stale", { debounce_ms = 2000 })
    walker.run()
    wait_for(function() return walker.status().tokens == 1 end)
    vim.api.nvim_buf_set_lines(0, 5, 6, false, { "human revision" })
    finish()
    eq(task().mode, "built")
    eq(doc.snapshot(task(), current(), "").target, { "HUMAN REVISION" })
  end)

  test("unrelated edits and moving boundaries do not conflict", function()
    setup("build")
    walker.run()
    wait_for(function() return walker.status().tokens == 1 end)
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new preface" })
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "new ending" })
    finish()
    eq(task().mode, "built")
    eq(current()[1], "new preface")
    eq(current()[#current()], "new ending")
  end)

  test("agent intermediate edits do not echo as human updates", function()
    setup("build", "intermediate")
    walker.run()
    finish()
    eq(task().mode, "built")
    eq(task().result, { "Agent notes", "Agent notes" })
  end)

  test("cancel rejects late agent output", function()
    setup("build", "late")
    walker.run()
    wait_for(function() return walker.status().tokens == 1 end)
    walker.cancel()
    local before = current()
    vim.wait(350, function() return false end, 5)
    eq(current(), before)
    eq(walker.status().message, "Cancelled")
  end)

  test("changing authority mid-task cancels, never promotes", function()
    setup("plan", "late")
    walker.run()
    wait_for(function() return walker.status().tokens == 1 end)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "-- @walker t1 #build #story" })
    finish()
    vim.wait(250, function() return false end, 5)
    eq(task().mode, "build")
    eq(task().result, {})
  end)

  test("read-only buffers reject agent edits", function()
    setup("build")
    walker.run()
    vim.bo.readonly = true
    finish()
    eq(task().mode, "build")
    assert(walker.status().message:match("read.only"))
    vim.bo.readonly = false
  end)

  test("disabled means no manual or automatic execution", function()
    setup("plan", "complete", { enabled = false, triggers = { interval = true } })
    walker.run()
    vim.wait(120, function() return false end, 5)
    eq(task().mode, "plan")
    assert(not walker.status().active)
    walker.enable()
    wait_for(function() return task().mode == "planned" end)
  end)

  test("combined automatic triggers coalesce and completed work stays dormant", function()
    setup("review", "complete", { triggers = { interval = true, idle = true, directive = true, save = true } })
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "-- Check continuity" })
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = 0 })
    wait_for(function() return task().mode == "reviewed" end)
    local before = current()
    vim.wait(180, function() return false end, 5)
    eq(current(), before)
    eq(walker.status().tokens, 1)
  end)

  test("blocked agent notes do not reactivate on interval", function()
    setup("plan", "blocked", { triggers = { interval = true } })
    walker.run()
    finish()
    vim.wait(200, function() return false end, 5)
    eq(task().result, { "Agent notes" })
    eq(task().mode, "plan")
    assert(not walker.status().active)
  end)

  test("cancelling pending build confirmation revokes launch", function()
    setup("build", "complete", { confirm_build = true })
    local original, callback = vim.ui.select, nil
    vim.ui.select = function(_, _, cb) callback = cb end
    walker.run()
    assert(callback)
    walker.cancel()
    callback("Build")
    vim.ui.select = original
    assert(not walker.status().active)
    eq(task().mode, "build")
  end)

  test("malformed and oversized transport data fail closed", function()
    for _, scenario in ipairs({ "malformed", "oversized" }) do
      setup("plan", scenario, { max_message_bytes = 1024 })
      local before = current()
      walker.run()
      finish()
      eq(current(), before)
      assert(not walker.status().message:match("Completed"))
    end
  end)

  test("missing executable fails without leaving a task active", function()
    setup("plan", "complete", { command = { "/nonexistent/walker-test-agent" } })
    walker.run()
    assert(not walker.status().active)
    assert(walker.status().message:match("Could not start"))
    eq(task().mode, "plan")
  end)

  test("unloading an active buffer revokes the task", function()
    setup("plan", "late")
    local buf = vim.api.nvim_get_current_buf()
    walker.run()
    wait_for(function() return walker.status().tokens == 1 end)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.wait(250, function() return false end, 5)
    assert(not walker.status(buf).enabled)
  end)

  test("one undo restores agent transaction, preserving previous human edit", function()
    setup("build")
    vim.api.nvim_buf_set_lines(0, 7, 8, false, { "human outside" })
    local before = current()
    walker.run()
    finish()
    eq(task().mode, "built")
    vim.cmd("undo")
    eq(current(), before)
  end)

  test("undoing completion does not automatically redo the agent's work", function()
    setup("build", "complete", { triggers = { interval = true, directive = true } })
    walker.run()
    finish()
    vim.cmd("undo")
    local before = current()
    vim.wait(220, function() return false end, 5)
    eq(current(), before)
    eq(task().mode, "build")
    assert(not walker.status().active)
  end)

  test("task size and token limits prevent edits", function()
    setup("build", "complete", { max_task_bytes = 10 })
    walker.run()
    assert(not walker.status().active)
    eq(task().mode, "build")
    setup("build", "budget", { token_budget = 1 })
    local before = current()
    walker.run()
    finish()
    eq(current(), before)
    eq(walker.status().message, "Token budget exceeded")
  end)

  test("timeout leaves pending task unchanged", function()
    setup("build", "late", { task_timeout_ms = 50 })
    local before = current()
    walker.run()
    finish()
    eq(walker.status().message, "Task timed out")
    vim.wait(250, function() return false end, 5)
    eq(current(), before)
  end)

  test("automatic no-work scans stay quiet", function()
    setup("planned", "complete", { triggers = { interval = true } })
    local count = #notifications
    vim.wait(100, function() return false end, 5)
    eq(#notifications, count)
    eq(walker.status().tokens, 0)
    assert(not walker.status().active)
  end)

  test("task command wraps only explicit selections and prevents overlap", function()
    setup("plan")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first", "second", "third" })
    vim.cmd("2WalkerTask review #grammar Improve grammar")
    eq(doc.snapshot(task(), current(), "").target, { "second" })
    local before = current()
    vim.cmd("1," .. #current() .. "WalkerTask plan nested")
    eq(current(), before)
  end)

  walker.setup({ enabled = false })
  print(string.format("%d Neovim tests passed", passed))
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  print(err)
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end

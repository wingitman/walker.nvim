vim.opt.runtimepath:prepend(vim.fn.getcwd())
local walker, doc, files = require("walker"), require("walker.document"), require("walker.files")
local uv, passed = vim.uv, 0
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = assert(uv.fs_realpath(root))
local select = vim.ui.select
vim.notify = function() end
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end
local function wait(fn) assert(vim.wait(4000, fn, 5), vim.inspect(walker.status())) end
local function text() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function task() return assert(doc.scan(text(), vim.bo.commentstring))[1] end
local function test(name, fn) fn(); passed = passed + 1; print("PASS " .. name) end
local sequence, callback, prompt = 0
local function setup()
  walker.setup({ enabled = false })
  vim.cmd("enew!")
  sequence = sequence + 1
  vim.api.nvim_buf_set_name(0, root .. "/source" .. sequence .. ".md")
  vim.bo.filetype, vim.bo.commentstring = "markdown", "<!-- %s -->"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "```python", "print('hello')", "```",
    "@walker can you write this python code to an actual python runnable file in this file's parent directory" })
  callback, prompt = nil, nil
  vim.ui.select = function(items, opts, done)
    eq(items, { "Create file", "Cancel" })
    callback, prompt = done, opts.prompt
  end
  walker.setup({ command = { "python3", vim.fn.getcwd() .. "/tests/fake_agent.py", "create-file" },
    triggers = {}, confirm_build = false, debounce_ms = 10000 })
  walker.run()
  wait(function() return callback ~= nil end)
  assert(not uv.fs_lstat(root .. "/hello.py"))
  eq(task().mode, "build")
end
local function finish(choice)
  callback(choice)
  wait(function() return not walker.status().active end)
end

local function run()
  test("file proposals require a safe sibling name, lines and a bounded size", function()
    for _, name in ipairs({ "../escape.py", "/tmp/escape.py", "a/b.py", "a\\b.py", ".", "..", ".env", "a\n.py", "x\0.py", "" }) do
      assert(not files.prepare(root, { name = name, lines = {} }, 1024))
    end
    assert(not files.prepare(nil, { name = "hello.py", lines = {} }, 1024))
    assert(not files.prepare(root, { name = "hello.py", lines = { "a\nb" } }, 1024))
    assert(not files.prepare(root, { name = "hello.py", lines = { "large" } }, 1))
  end)
  test("plain request creates a runnable sibling only after destination confirmation", function()
    setup()
    assert(prompt:find(root .. "/hello.py", 1, true))
    finish("Create file")
    eq(vim.fn.readfile(root .. "/hello.py"), { "print('hello')" })
    eq(task().mode, "built")
    eq(task().result, { "Created `hello.py`." })
    eq(text()[2], "print('hello')")
    eq(uv.fs_stat(root .. "/hello.py").mode % 512, 384)
    -- Undo changes only the document; it cannot delete a persisted file.
    vim.cmd("undo")
    eq(task().mode, "build")
    assert(uv.fs_stat(root .. "/hello.py"))
    assert(uv.fs_unlink(root .. "/hello.py"))
  end)
  test("declining file creation preserves the task and creates nothing", function()
    setup()
    local before = text()
    finish("Cancel")
    eq(text(), before)
    assert(not uv.fs_lstat(root .. "/hello.py"))
  end)
  test("human changes to source context invalidate pending file approval", function()
    setup()
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "print('changed')" })
    finish("Create file")
    eq(task().mode, "build")
    eq(text()[2], "print('changed')")
    assert(not uv.fs_lstat(root .. "/hello.py"))
    assert(walker.status().message:find("Source changed", 1, true))
  end)
  test("cancellation, disable, rename and readonly revoke file proposals", function()
    for _, action in ipairs({ "cancel", "disable", "rename", "readonly", "unload" }) do
      setup()
      if action == "cancel" then walker.cancel()
      elseif action == "disable" then walker.disable()
      elseif action == "rename" then vim.api.nvim_buf_set_name(0, root .. "/renamed.md")
      elseif action == "readonly" then vim.bo.readonly = true
      else vim.api.nvim_buf_delete(0, { force = true }) end
      finish("Create file")
      assert(not uv.fs_lstat(root .. "/hello.py"))
      vim.bo.readonly = false
    end
  end)
  test("a file arriving while confirmation is open is never overwritten", function()
    setup()
    vim.fn.writefile({ "human file" }, root .. "/hello.py")
    finish("Create file")
    eq(vim.fn.readfile(root .. "/hello.py"), { "human file" })
    eq(task().mode, "build")
    assert(uv.fs_unlink(root .. "/hello.py"))
  end)
  test("dangling symlinks and existing destination buffers are refused", function()
    assert(uv.fs_symlink(root .. "/missing.py", root .. "/hello.py"))
    assert(not files.prepare(root, { name = "hello.py", lines = {} }, 1024))
    assert(uv.fs_unlink(root .. "/hello.py"))
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, root .. "/hello.py")
    assert(not files.prepare(root, { name = "hello.py", lines = {} }, 1024))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  test("exclusive create rejects a destination appearing after validation", function()
    local prepared = assert(files.prepare(root, { name = "hello.py", lines = { "agent file" } }, 1024))
    local open = uv.fs_open
    uv.fs_open = function(path, flags, mode)
      local fd = assert(open(path, "wx", 384))
      uv.fs_write(fd, "human file\n", 0); uv.fs_close(fd)
      return open(path, flags, mode)
    end
    local result = files.write(prepared)
    uv.fs_open = open
    assert(not result)
    eq(vim.fn.readfile(root .. "/hello.py"), { "human file" })
    assert(uv.fs_unlink(root .. "/hello.py"))
  end)
  test("failed writes clean up their own partial file without claiming completion", function()
    setup()
    local write = uv.fs_write
    uv.fs_write = function() return nil, "simulated disk error" end
    finish("Create file")
    uv.fs_write = write
    assert(not uv.fs_lstat(root .. "/hello.py"))
    eq(task().mode, "build")
    assert(walker.status().message:find("simulated disk error", 1, true))
  end)
  test("directory replacement invalidates a prepared write", function()
    local directory = root .. "/directory"
    vim.fn.mkdir(directory)
    local prepared = assert(files.prepare(directory, { name = "hello.py", lines = {} }, 1024))
    assert(uv.fs_rename(directory, root .. "/old-directory"))
    vim.fn.mkdir(directory)
    assert(not files.write(prepared))
    assert(not uv.fs_lstat(directory .. "/hello.py"))
  end)
  test("the editor rejects unauthorized or malformed file proposals from custom adapters", function()
    local transport = require("walker.transport")
    local start = transport.start
    local cases = {
      { mode = "plan" }, { mode = "review" }, { mode = "build", target = {} },
      { mode = "build", done = false }, { mode = "build", blocked = true },
      { mode = "build", name = "../escape.py" },
    }
    for _, case in ipairs(cases) do
      walker.setup({ enabled = false })
      vim.cmd("enew!")
      sequence = sequence + 1
      vim.api.nvim_buf_set_name(0, root .. "/reject" .. sequence .. ".md")
      vim.bo.commentstring = "<!-- %s -->"
      local source = doc.compact("reject", case.mode, "Create hello.py", { "code" }, {}, vim.bo.commentstring)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, source)
      transport.start = function(_, receive)
        return { stop = function() end, send = function(message)
          if message.type == "start" then
            vim.schedule(function() receive({ type = "edit", revision = 1, result = {}, done = case.done ~= false,
              blocked = case.blocked, target = case.target,
              create_file = { name = case.name or "hello.py", lines = { "print('hello')" } } }) end)
          end
        end }
      end
      walker.setup({ command = { "unused" }, confirm_build = false })
      walker.run()
      wait(function() return not walker.status().active end)
      eq(text(), source)
      assert(walker.status().message:lower():find("file creation", 1, true))
      assert(not uv.fs_lstat(root .. "/hello.py"))
    end
    transport.start = start
  end)
end
local ok, err = xpcall(run, debug.traceback)
vim.ui.select = select
walker.setup({ enabled = false })
vim.fn.delete(root, "rf")
if not ok then print(err); vim.cmd("cquit 1") else print(passed .. " file creation tests passed"); vim.cmd("qa!") end

# Walker.nvim

An experimental Neovim co-editor for code, stories, letters, and other writing.
You and an agent work in the same unsaved buffer, without hard locks. Human edits
take priority; relevant changes are sent to the agent and stale edits are rejected.

**The document holds the work. The right-hand panel tracks tasks and usage.**
Plans, outlines, reviews, drafts, and questions remain in the document. Markdown
and plain-text results are ordinary text, not a wall of comments. In code files,
non-code results use the buffer's comment syntax to preserve valid source.
Responses default to the requested artifact, a short plan, or actionable findings:
no thinking-aloud narrative, tutorials, or repeated progress summaries in the file.

## Setup

Requires Neovim **0.10+** (tested on 0.12.5), Python **3.9+**, and a Chat
Completions-compatible endpoint supporting JSON-object responses and `max_tokens`.
The Python adapter uses only the standard library. No Responses API support yet.

Add this directory to your runtime path or use a local plugin manager spec:

```lua
local path = "/absolute/path/to/Walker"
vim.opt.runtimepath:append(path)
require("walker").setup({
  command = { "python3", path .. "/adapters/openai_agent.py" },
  brief = "Preserve my voice. Keep changes focused. Ask when context is missing.",
  triggers = { directive = true, save = true, interval = false, idle = true },
  balance = { enabled = true }, -- Optional, direct DeepSeek only.
})
vim.keymap.set("n", "<leader>wp", "<cmd>WalkerPanel<cr>")
vim.keymap.set("n", "<leader>wr", "<cmd>WalkerRun<cr>")
vim.keymap.set("x", "<leader>wt", ":WalkerTask<cr>")
```

For lazy.nvim, use `dir = path`, `name = "walker.nvim"`, `main = "walker"`,
`lazy = false`, and put the setup table in `opts`. No mappings are installed by
the plugin itself.

Export credentials in the **terminal before launching Neovim**. For direct
DeepSeek (use a DeepSeek key, not an OpenCode Zen key):

```sh
export WALKER_MODEL="deepseek-flash"
export WALKER_BASE_URL="https://api.deepseek.com"
export WALKER_API_KEY="your-deepseek-api-key"
nvim
```

The default base URL is `https://api.openai.com/v1`. `OPENAI_API_KEY` is a fallback
for `WALKER_API_KEY`. Loopback HTTP endpoints may omit the key; remote endpoints
require HTTPS. The model ID must be supplied explicitly. Direct DeepSeek defaults
to non-thinking mode for responsive, bounded editing; set
`WALKER_THINKING=enabled` to opt into thinking (which may require a larger budget).

**Privacy:** activation sends the brief, task instructions, result, scoped
passage, and (for a named document) its resolved directory to the configured
provider. Plain requests also send the surrounding document as **read-only
context**, including unsaved text, within `max_task_bytes`. Automatic triggers
may execute directives already in an opened file; use them only in trusted files.
Configure only trusted adapter commands: these processes run as your user.
Keys are read from the environment, not written into documents or logs.

## Write a task, not a protocol

With a trigger enabled, type and save:

```text
@walker Write a short introduction for this document.
```

Plain `@walker <request>` means **carry it out** (`#build`), not "plan it".
Build confirmation is enabled by default. Walker may write inside the new task
or propose a new sibling file; surrounding text is context, **not edit authority**.
For changes to existing passages, select them with `WalkerTask`, or assign the
pending request a selection with `:'<,'>WalkerScope [id]`.

For planning only, say so explicitly:

```text
@walker #plan Outline a theatrical play about bees in Antarctica.
```

Multiline instructions also work:

```text
@walker Let's develop this story.

#plan Outline a theatrical play about bees in Antarctica.
```

Walker generates a compact task and appends the outline as visible text. When
done, the header becomes `#planned`. It does **not** silently promote itself to
building the plan. To continue, add a standalone **`#build`** (or `@walker #build`)
inside its result or immediately after `@endwalker`, with optional blank lines,
then save or leave Insert mode. This reuses the task—not a new task. Commands in
fenced examples, in target content, or separated from a task by unrelated prose
do not count as continuation requests.

Alternatively use **`:WalkerBuild`**, **`:WalkerRun`** in a completed plan/review,
or the panel's **b**/**r** action. Build confirmation remains enabled by default.
For an append-only plan with no target, that task's own result becomes its build
target, so implementation replaces the planning conversation. An already scoped
task keeps its original target. Nothing elsewhere in the document gains edit
permission. Completed builds are not silently rerun.

For an existing passage, select it in visual-line mode and enter `:WalkerTask`.
Neovim supplies the range (`'<,'>`); Walker prompts for mode and instruction.
You can also use `:'<,'>WalkerTask review Check continuity` directly.
If the selection already contains exactly one task, bare `WalkerTask` continues
that task instead of nesting another one; selecting extra text does not expand
its scope. A selection overlapping multiple tasks is rejected with guidance.

- **Plan** writes the requested plan/outline in the document without replacing
  the target passage. A typed planning directive may have an empty target: that
  authorizes new output at the directive, not edits across the file.
- **Review** appends findings in the document, without changing the target.
- **Build** may replace the explicitly scoped target and update its result, or
  propose one new file beside the document with separate confirmation.

An explicitly tagged `#review`/`#build` without a selected scope appends a
**Walker question [needs-input]**. Select the intended passage and use
`:'<,'>WalkerScope [id]` to authorize it. The compact task is moved around that
selection; existing task scopes cannot overlap. Walker never infers whole-file
edit permission just because a directive exists.

For a missing goal (bare `@walker`), answer the inline question with a real
`Walker answer: #plan <goal>` line (or `#review` / `#build`). A trigger or manual
run resolves it. For an agent's question, write your answer inside the result
section before `@endwalker`; enabled triggers see that change and can resume.
If no automatic trigger is enabled, run `:WalkerRun`.

### Create an actual file

In a named document containing the Python code, write:

```text
@walker Write this Python code to hello.py in this document's parent directory.
```

Walker proposes the file and asks you to confirm its **full destination path**.
This confirmation is mandatory even when `confirm_build=false`. Approval creates
one new sibling file and records a short receipt in the task; it does not replace
the source code. Requests referring to ambiguous code should ask for clarification.

- Only a simple filename is accepted: no absolute paths, subdirectories, or `..`
  traversal. The document's directory must already exist.
- Existing files, symlinks (including dangling ones), and destination buffers are
  refused. Creation is exclusive, so a file arriving during confirmation is safe.
- Source edits, renames, disable/cancel, or lost write permission invalidate approval.
- Files are UTF-8 with LF endings, private (`0600`), and not executed or marked
  executable. Run a Python script yourself with `python3 hello.py` after reviewing it.
- **Undo affects the document only**, not a created file. If a document update fails
  after the file write, Walker reports the created path rather than claiming atomic
  rollback. File contents are model-generated, not automatically tested.

Older generated `#plan #needs-instruction` blocks are not silently reinterpreted as
build authorization. Replace that obsolete block with the original plain request,
or answer its existing question explicitly.

## Persistent document format

Three small anchors retain identity and exact scope across line movement and
reopening. In Markdown the result itself is **not** commented out:

```markdown
<!-- @walker w123-1 #review | Check continuity -->
The original passage.
<!-- @result -->
The protagonist's departure contradicts the preceding paragraph.
<!-- @endwalker -->
```

The first marker contains an internal ID, mode/status, optional state tags, and
the goal after `|`. The target is between the header and `@result`; work and
answers are between `@result` and `@endwalker`. Code uses its `commentstring`;
plain text has visible unwrapped anchors. Generated metadata is real file content
and needs deliberate cleanup before publication.

Old task blocks with separate `@walker-target` boundaries remain readable and
editable. Old commented results are accepted; future Markdown result updates are
rendered as visible text. Walker does not silently rewrite your saved manuscripts.

Reserved Walker marker lines cannot occur in agent output. Malformed or overlapping
structured blocks fail closed, with an explanation in the panel. Markdown fenced
examples outside tasks do not activate. Focus tags such as `#story`, `#grammar`,
`#flow`, or `#test` guide the model; they don't grant shell or project-wide tools.

## Right-hand panel

Open with `:WalkerPanel`. It follows the current document and displays:

- Enabled state, Git root (or document directory), filename, and model.
- **new**, **planning**, **working**, **complete**, **needs input**, **failed**, or
  **cancelled** tasks: one title line and one line number/current-step line each.
- Local TODO/FIXME items and agent-suggested follow-ups as **candidates**. They
  never execute themselves; select their passage and create an authorized task.
- Current/last task tokens used / task budget, plus last task activity and accepted
  agent-edit times. Times and usage are session-local, not restored from disk.
- Provider balance and its last successful update time.
- Quick reference for panel keys and Walker commands.

Panel keys: **Enter** jumps to a task; **r** runs/retries it (builds a completed
plan/review); **c** cancels its
active work/confirmation; **b** promotes a completed plan/review to build;
**B** refreshes balance (rate-limited); **q** closes the panel. Use normal Neovim
window navigation to focus it; opening it leaves focus in your document.

Completed and needs-input markers persist in the document. Transient activity,
failures/cancellations, discovered agent suggestions, and usage counters are
session-local. An unchanged attempted task doesn't repeatedly restart on ticks;
retry manually or change its instructions/result. File reopen reloads persisted
tasks; it cannot restore an in-flight process or past provider billing.

## Usage, cost, and balance

The compact panel shows task totals, not a breakdown or all-files session total.
Detailed accounting and configured cost estimates remain available through
`require("walker").view(bufnr).task_usage` and `.session_usage`.
The adapter reports totals plus input/output/cache/reasoning detail where supplied.
Cached input is a subset of input; reasoning is a subset of output—neither is
added twice. Missing breakdowns/costs are labelled unavailable or partial.
Discarded responses and incomplete provider output still count when usage is
available. Cancellation during a request may leave **unreported charges**, not
zero cost.

The displayed budget is a **Walker per-task token budget**, not the provider's token balance
or remaining context window. Session totals are not a monetary spending cap.
The budget uses a conservative byte-based preflight estimate, not an exact model
tokenizer; provider-side charges can persist after cancellation.

Cost is estimated only with explicit matching-model pricing and sufficient
reported usage. No rates are guessed or silently fetched. Example configuration
shape (fill in your actual current rates, accounting for any peak/off-peak pricing):

```lua
pricing = {
  model = "your-exact-model-id", currency = "USD",
  input_per_million = 1.0,
  cached_input_per_million = 0.1,
  output_per_million = 2.0,
}
```

These illustrative rates are **not DeepSeek prices**. Direct DeepSeek's optional
`GET /user/balance` lookup uses the configured key and sends no document text.
It is cached for at least `balance.refresh_seconds`, has a timeout, and never
blocks writing. Other providers show “Balance unavailable.” Account balance is
distinct from Walker's estimated cost and can change through other applications.

## Configuration and commands

Defaults: all automatic triggers **off**, `enabled=true`, `confirm_build=true`,
`debounce_ms=750`, `idle_ms=3000`, `interval_ms=10000`, `cooldown_ms=2000`,
`task_timeout_ms=180000`, `max_task_bytes=131072`, `max_message_bytes=1048576`,
`max_requests=8`, `max_output_tokens=2000`, `token_budget=32000`,
`panel={width=44}`, `balance={enabled=false, refresh_seconds=60}`, `pricing=false`.

All triggers feed the same discovery/scheduler path. New automatic work waits
until you leave Insert/Replace mode, avoiding partially typed directives/answers.
One task runs per buffer;
different buffers can work concurrently. Once active, a task receives human
updates even in manual-only mode. Agent edits do not trigger new work. No-work
scans make no model call. Commands are case-sensitive and operate in document
buffers, never notification/picker windows.

Commands: `WalkerTask`, `WalkerRun [id]`, `WalkerBuild [id]`, `WalkerScope [id]`, `WalkerPanel`,
`WalkerBalance`, `WalkerCancel`, `WalkerDisable`, `WalkerEnable`, `WalkerStatus`.
Creating a new `WalkerTask` and assigning `WalkerScope` require an explicit range;
`WalkerTask` without a range can continue an existing task. Disable cancels work and
blocks manual activation; enable restores it. `require("walker").view(bufnr)`
exposes the dashboard data; `.status(bufnr)` exposes concise activity/status.

## Limits and verification

No general cross-file reads/edits, shell execution, autonomous implementation of
suggested tasks, or OpenCode/Claude Code integration. The only filesystem operation
is confirmed creation of a new sibling file; dependencies in other files aren't
tracked. Plain requests include read-only surrounding context. Results apply as whole patches,
not streamed tokens. Model calls consume live updates at checkpoints, not midway
through generation; frequently changing the same passage can exhaust the budget.
Local deltas don't imply incremental provider billing. Undo restores each agent
transaction without joining the preceding human edit. Large manuscripts and all
Neovim plugin combinations have not been benchmarked.

Run from this directory (deterministic agents and loopback HTTP, no paid calls):

```sh
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/commands.lua
nvim --headless -u NONE -l tests/workflow.lua
nvim --headless -u NONE -l tests/files.lua
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

See [the adapter protocol](docs/protocol.md) for custom backends.

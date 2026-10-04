# Walker.nvim

An experimental Neovim co-editor for code, stories, letters, and other writing.
You and an agent can work in the same unsaved buffer. There are no hard locks:
human edits take priority, live changes are sent to the active agent, and stale
agent edits are rejected before they can overwrite your work.

**First working version:** scoped inline tasks, planning/review/build lifecycles,
composable triggers, a pluggable agent protocol, and an OpenAI-compatible adapter.
This is not yet a general-purpose autonomous coding agent or multiplayer editor.

## Requirements and setup

- Neovim **0.10+** (tested on 0.12.5).
- Python **3.9+** for the included adapter; no Python packages required.
- A Chat Completions-compatible endpoint supporting JSON-object responses and
  `max_tokens`. Not every provider/model implements that combination.

Add this directory to your runtime path, or install it as a local plugin using
your plugin manager. For example, in `init.lua`:

```lua
local walker_path = "/absolute/path/to/Walker"
vim.opt.runtimepath:append(walker_path)

require("walker").setup({
  command = { "python3", walker_path .. "/adapters/openai_agent.py" },
  brief = "Preserve my voice. Keep changes focused. Ask when essential context is missing.",
  -- Manual activation by default; enable any combination:
  triggers = { directive = false, save = false, interval = false, idle = false },
})

vim.keymap.set("n", "<leader>wr", "<cmd>WalkerRun<cr>", { desc = "Walker: run task" })
vim.keymap.set("n", "<leader>wc", "<cmd>WalkerCancel<cr>", { desc = "Walker: cancel" })
```

Configure the adapter in the environment before starting Neovim:

```sh
export WALKER_MODEL="your-provider-model-id"
export WALKER_API_KEY="your-api-key"
# Optional; defaults to https://api.openai.com/v1
export WALKER_BASE_URL="https://your-provider.example/v1"
```

`OPENAI_API_KEY` is a fallback for `WALKER_API_KEY`. Loopback HTTP endpoints such as
`http://127.0.0.1:1234/v1` can run without a key. Other endpoints require HTTPS
and a key. Credentials are read from the environment, not stored in documents.

**Privacy:** activation sends the configured brief, task instructions, inline
result, and scoped passage to the configured provider, including unsaved text.
No other project files are read. Use automatic triggers only with trusted files:
an existing inline instruction in an opened file can be eligible for execution.
Only configure trusted adapter executables; they run with your user permissions.

## First task

1. Select the passage you want help with in visual-line mode.
2. Enter `:'<,'>WalkerTask plan #story Strengthen the ending; preserve who survives`.
3. Run `:WalkerRun` with the cursor in the task or its target passage.
4. Continue editing while Walker works. Its plan appears inline, and `#plan`
   becomes `#planned` only when the result is successfully applied.
5. Edit that plan directly if needed. Change the **header's** `#planned` tag to
   `#build`, then activate again. The current inline plan is authoritative.
6. Review the confirmation, then continue writing while the agent implements it.
   Completion changes `#build` to `#built`. The task/result remain in the file.

Use `#review` for findings instead of a plan; it becomes `#reviewed`. You can remove
unwanted findings before promoting to `#build`. To request another planning or
review pass, explicitly restore `#plan` or `#review`. Editing a completed plan's
wording alone does not reopen it.

## Inline format

Here is a complete task in a plain-text buffer (`commentstring` empty):

```text
@walker ending #planned #story #flow
Strengthen the ending without changing who survives.
@result
1. Shorten the explanation before the confrontation.
2. Reveal the missing key through dialogue.
3. End on the unanswered accusation.
@endwalker
@walker-target ending
The passage being edited goes here.
@endwalker-target ending
```

`WalkerTask` generates unique IDs and wraps task/marker lines using the buffer's
`commentstring`: for example `-- ...` in Lua or `<!-- ... -->` in Markdown.
Every task-content line must retain that wrapper. In plain text, markers and
notes are visible text. Set an appropriate `commentstring` before creating tasks;
formats without comments cannot hide metadata from exports.

Markers must occupy whole lines with the exact generated wrapper. IDs contain
letters, digits, underscores, or hyphens. A task requires exactly one mode/status
tag and a matching target pair. Scopes cannot nest or overlap. Marker names are
reserved within task results and target text, including quoted examples.

- **Authority:** `#plan`, `#review`, `#build` (one at a time).
- **Completed status:** `#planned`, `#reviewed`, `#built` (dormant).
- **Context/focus:** `#code`, `#story`, `#letter`, `#grammar`, `#flow`, `#validate`,
  `#test`, or your own tags. These are model instructions, not hard-coded tools.

Focus tags may appear in the header or instruction text. Only the header's
mode/status grants authority. A `#test` task can write or review tests; the agent
cannot execute them. Bare hashtags and ordinary TODOs do not authorize work.

Planning and review can change only their own result block and completion tag.
Build can additionally replace the text **between its target markers**. Walker
does not write the file to disk, move your cursor away, or block your edits.

## Commands

| Command | Effect |
| --- | --- |
| `:[range]WalkerTask plan\|review\|build <instruction>` | Create a scoped task; an explicit range and instruction are required. |
| `:WalkerRun [id]` | Start/retry the task under the cursor, the specified ID, or the only task in the buffer. If active, synchronize it instead. |
| `:WalkerCancel` | Cancel current work or pending build confirmation; late responses lose authority. |
| `:WalkerDisable` | Disable this buffer, including manual activation, and cancel current work. |
| `:WalkerEnable` | Re-enable this buffer. |
| `:WalkerStatus` | Show activity, last outcome, and last/current task token usage. |

`require("walker").status(bufnr)` exposes the same information for a statusline.
No keybindings are installed automatically.

## Triggers and limits

These are the defaults; pass overrides to `setup()`:

```lua
{
  enabled = true, -- false disables attached buffers until :WalkerEnable
  command = {}, -- configure an argv array; no shell command strings
  brief = "", -- stable shared goals/constraints; task-specific goals go inline
  triggers = {
    directive = false, -- evaluate pending directives after an edit debounce
    save = false,      -- evaluate on BufWritePost
    interval = false,  -- periodically evaluate loaded buffers
    idle = false,      -- evaluate after a pause in buffer edits
  },
  debounce_ms = 750, -- also batches active-task synchronization
  idle_ms = 3000,
  interval_ms = 10000,
  cooldown_ms = 2000, -- minimum spacing between automatic task starts per buffer
  confirm_build = true, -- false: changing the header to #build is sufficient authority
  task_timeout_ms = 180000,
  max_task_bytes = 128 * 1024,
  max_message_bytes = 1024 * 1024,
  max_requests = 8, -- adapter model calls; also caps accepted edits per task
  max_output_tokens = 2000,
  token_budget = 32000, -- per task, not a global/monthly spending limit
}
```

Enable all four automatic triggers for “all”; leave them false for manual-only.
Use `enabled = false` or `WalkerDisable` for fully disabled. Triggers feed one
scheduler, with one active task per buffer; multiple buffers can work concurrently.
Automatic scans with no actionable work stay quiet and make **no model call**.
Manual activation with no task shows guidance instead of guessing what to edit.

An attempted task does not repeatedly restart on timer ticks. To retry after a
failure, cancellation, or blocked question, use `WalkerRun`, or change its
instructions/result. Completed tasks stay dormant. Save, interval, and idle can
also discover existing directives; the directive trigger evaluates pending tasks
after edits, not while a half-written block is syntactically invalid.

Activation and synchronization are separate: even in manual-only mode, human
changes to an active task are sent automatically. Agent edits do not trigger new
tasks. Changes from formatters and other plugins count as external/human changes.

## Concurrency and token behavior

- Stable inline IDs/boundaries track scopes when surrounding lines move, even
  across saves/reopens. Malformed boundaries fail closed.
- Relevant edits are batched into line splices over the local agent connection.
  Before accepting any proposal, Walker re-reads the current task and passage;
  an outdated response cannot slip through the debounce window.
- Changing task identity, mode, or header tags revokes the running task.
- A model call already in progress is not interrupted by context updates. The
  included adapter consumes updates at checkpoints, discards superseded output,
  and continues using the latest snapshot. That discarded call may still cost
  tokens. Cancelling a process also does not guarantee provider-side cancellation.
- The adapter sends only the brief, current instructions/result, and passage on
  each model call—not the whole file or an ever-growing transcript. Local deltas
  are **not** a claim of incremental API billing. Repeated scoped context is still
  billable, subject to any provider caching.
- Usage is shown when reported by the provider, otherwise estimated. A conservative
  byte-based preflight check and a request cap limit runaway work. This is not an
  exact tokenizer or a guaranteed monetary cap; budgets reset on a new task run.
- Each accepted edit is one undo transaction, separate from the preceding human
  edit. Undo is itself an external change if work is still active.

## Current limitations

- No autonomous TODO discovery, standing/recurring instructions, task folding,
  export cleanup, cross-file tools, shell execution, or OpenCode/Claude Code
  integration yet. Other agents can implement [the protocol](docs/protocol.md).
- Only the selected passage and task notes supply context. Outside changes do not
  invalidate work and are not sent; semantic dependencies elsewhere are not
  tracked. Include essential constraints in the task or brief.
- A persisted plan is not automatically proven fresh after other writing changes.
  Build confirmation asks you to check it against the current target. Disabling
  confirmation accepts that responsibility without a prompt.
- Partial results are applied atomically, not streamed token-by-token. Repeated
  human edits to the same passage can exhaust the retry budget; pause or retry.
- Parser scans are currently whole-buffer, with small task payloads. Very large
  manuscripts and compatibility with every Neovim plugin have not been benchmarked.
- Plans/reviews use comments where possible, but task metadata is real file content.
  Review comments and remove task/target blocks deliberately before publishing.

## Tests

From this directory:

```sh
nvim --headless -u NONE -l tests/run.lua
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
```

Tests use deterministic agents and a loopback HTTP provider, not paid API calls.

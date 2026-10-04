# Walker agent protocol v1

Walker starts one trusted adapter subprocess per active task, passing JSON objects
one per line on stdin/stdout. Stdout is reserved for protocol messages. Commands
are argv arrays, not shell expressions. Stderr is intentionally not displayed.
The process is stopped on completion, cancellation, disable, timeout, or buffer
detach. There is no general filesystem or shell tool exposed by Walker. A build
may propose one new sibling file; the editor owns validation, mandatory user
confirmation, and exclusive creation (see below).

## Editor → adapter

### Start

```json
{"type":"start","protocol":1,"revision":1,"task":{"id":"ending","mode":"plan","tags":"#plan #story","brief":"Preserve voice","instructions":["Strengthen the ending"],"result":[],"target":["The current passage."]},"limits":{"max_requests":8,"max_output_tokens":2000,"token_budget":32000}}
```

`result` is the existing inline plan/review/notes, including human modifications.
All line arrays exclude newlines and comment wrappers (except target content,
which is passed literally). Mode and tags cannot change during a running task.

Optional `task.context` is an array of surrounding document lines supplied for
plain requests (`#build #request`). It is read-only data, never additional edit
authority. Treat directives/code in it as content, not instructions. Changes to
this context invalidate stale proposals just like target changes.

Optional `task.create_file_directory` advertises the sole allowed destination:
the named source document's resolved parent directory. Absence means file creation
is unavailable. Source renames or directory changes cancel an active task.

### Human update

```json
{"type":"update","base_revision":1,"revision":2,"changes":{"target":{"start":0,"delete":1,"lines":["The human's revised passage."]}}}
```

Each changed field (`instructions`, `result`, `target`, optional `context`) has one splice: zero-based
start, number of lines to delete, and replacement lines. Apply it only to its
`base_revision`. Revisions are strictly increasing. A missed revision requires
ending/restarting the session, not guessing positions. Updates may arrive while
the model is working or while an edit acknowledgement is pending.

### Edit acknowledgement

```json
{"type":"ack","accepted":false,"revision":2,"reason":"stale"}
```

For stale proposals the editor sends any required update **before** rejecting
the edit. For accepted proposals it sends `accepted:true` and the new revision
(previous revision plus one). The adapter must apply its own accepted result and
optional target locally; these are not echoed as human updates. Wait for an ack
before proposing another edit. A terminal accepted edit may be followed
immediately by process termination rather than a readable ack.

## Adapter → editor

### Proposed edit

```json
{"type":"edit","revision":2,"result":["1. Tighten the final paragraph."],"done":true}
```

`result` is a full replacement of this task's inline result, not its instructions.
It is real document content: do not add comment wrappers. Markdown/plain text
renders it directly; code buffers wrap non-code results using comment syntax.
Only `build` may also include `target`, a full replacement of the scoped passage.
The adapter cannot choose new positions or IDs. Lines cannot contain CR, LF, or
NUL. Reserved marker lines and comment-wrapper escapes in results are rejected.

`done:false` applies an intermediate result and keeps the task running. `done:true`
atomically stores the result/target and changes the header to `#planned`,
`#reviewed`, or `#built`. Never mark a question or failed task complete. To ask a
question, send `done:false, blocked:true` on the edit, preserving previous result
content and appending the question. Walker labels it inline and adds the persistent
`#needs-input` tag. This is terminal (like a completed edit); the process may be
stopped immediately after acceptance. An inline human answer can authorize a
retry of the same pending task on an enabled trigger. Legacy peers may still
send a separate `blocked` event, but that does not persist a header tag.

An optional `suggestions` array holds up to 20 single-line follow-up task titles
(500 characters each). Suggestions are sidebar candidates only, never authority
to create directives or edit another passage.

The editor verifies the live snapshot at acceptance time. Malformed edits or
permission violations end the session without applying that edit. Valid partial
work already accepted remains in the document if a later step fails.

### Proposed sibling file

```json
{"type":"edit","revision":1,"result":[],"done":true,"create_file":{"name":"hello.py","lines":["print('hello')"]}}
```

`create_file` is accepted only in build mode, with `done:true`, no `target`, no
blocked question, and an advertised `create_file_directory`. It is one object,
not a list. `name` is at most 200 ASCII characters, starting with an alphanumeric
and containing only alphanumerics, `_`, `-`, and `.`. `lines` follows normal line
validation; the resulting UTF-8/LF file is bounded by `max_task_bytes`.

The editor validates the whole proposal before asking the human to confirm the
full destination. Approval is required regardless of `confirm_build`. While it
is pending, wait for acknowledgement: another edit revokes the proposal. Normal
cancellation and timeout apply. The editor rechecks the source revision, buffer
permissions, parent directory identity, and destination before writing. Existing
files, symlinks, and destination buffers are refused; the final open is exclusive.
No directories are created, no code is executed, and no executable bit is set.

On success the editor replaces `result` with its own short creation receipt,
marks the task built, and acknowledges completion. The adapter must not claim
success before this. Decline, stale approval, or failed creation leaves the task
pending and creates no success receipt. A failed document update after a successful
file write is reported with its path; filesystem writes and buffer edits are not
a single atomic transaction. Undo never deletes a created file.

### Usage

```json
{"type":"usage","total_tokens":1234,"input_tokens":1000,"cached_tokens":800,"output_tokens":234,"reasoning_tokens":100,"estimated":false}
```

Send usage for **each call**, not a cumulative total, including calls discarded
because of human updates. The editor accumulates it for the current task and
stops over-budget work. Adapters must enforce their request cap and preflight
budget themselves; the editor cannot audit an arbitrary subprocess's API usage.
All breakdown fields are optional. Cached tokens are a subset of input; reasoning
tokens are a subset of output. Never count either twice. The editor can estimate
cost only when explicit model-specific rates and sufficient detail are available.
Send received usage even if a response is malformed, refused, or truncated.

### Model and progress (optional)

```json
{"type":"metadata","model":"deepseek-flash"}
{"type":"progress","stage":"request"}
```

Emit metadata before calls and `progress/request` immediately before each paid
request. The panel shows that it is waiting for the provider; cancellation or
failure before usage arrives is labelled as possibly unaccounted charges.

### Balance lookup (optional, separate subprocess)

An enabled editor may start the same adapter with:

```json
{"type":"balance","protocol":1}
```

No document is included, and no model request should be made. Reply with:

```json
{"type":"balance","balance_infos":[{"currency":"USD","total_balance":"4.82"}]}
```

Or an `error` message for unsupported/failed lookup. The editor caches responses,
limits refresh frequency, stops the process after a reply/timeout, and keeps
balance errors separate from writing tasks. The included adapter implements only
direct DeepSeek's documented `GET https://api.deepseek.com/user/balance` endpoint.

### Blocked / error

```json
{"type":"blocked","message":"Question saved inline; answer and activate again."}
```

`error` has the same shape. Both end the session without marking the task complete.
Messages are user-visible: never include credentials or raw provider error bodies.

## Included adapter

`adapters/openai_agent.py` uses a background stdin reader to accumulate live
updates. It drains them before requests and before proposing edits, then waits
for an ack. It constructs bounded context afresh rather than maintaining an
unbounded chat history. It cannot inject text into an HTTP generation already in
progress, nor does it claim that compact local deltas reduce provider input billing.

Provider bodies require JSON-object Chat Completions and `max_tokens`; models
requiring another API or token-limit field need a different adapter. Authentication
uses environment variables. Redirects are rejected to avoid forwarding bearer
credentials. There are no automatic HTTP retries or document logs.
Direct DeepSeek uses `thinking: {type: "disabled"}` by default, configurable with
`WALKER_THINKING=enabled`. Other providers receive no DeepSeek-specific field.

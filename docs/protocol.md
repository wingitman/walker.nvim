# Walker agent protocol v1

Walker starts one trusted adapter subprocess per active task, passing JSON objects
one per line on stdin/stdout. Stdout is reserved for protocol messages. Commands
are argv arrays, not shell expressions. Stderr is intentionally not displayed.
The process is stopped on completion, cancellation, disable, timeout, or buffer
detach. There is no filesystem or shell tool exposed by Walker.

## Editor → adapter

### Start

```json
{"type":"start","protocol":1,"revision":1,"task":{"id":"ending","mode":"plan","tags":"#plan #story","brief":"Preserve voice","instructions":["Strengthen the ending"],"result":[],"target":["The current passage."]},"limits":{"max_requests":8,"max_output_tokens":2000,"token_budget":32000}}
```

`result` is the existing inline plan/review/notes, including human modifications.
All line arrays exclude newlines and comment wrappers (except target content,
which is passed literally). Mode and tags cannot change during a running task.

### Human update

```json
{"type":"update","base_revision":1,"revision":2,"changes":{"target":{"start":0,"delete":1,"lines":["The human's revised passage."]}}}
```

Each changed field (`instructions`, `result`, `target`) has one splice: zero-based
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
Only `build` may also include `target`, a full replacement of the scoped passage.
The adapter cannot choose new positions or IDs. Lines cannot contain CR, LF, or
NUL. Reserved marker lines and comment-wrapper escapes in results are rejected.

`done:false` applies an intermediate result and keeps the task running. `done:true`
atomically stores the result/target and changes the header to `#planned`,
`#reviewed`, or `#built`. Never mark a question or failed task complete. To ask a
question, first save it using an intermediate edit; after its ack send `blocked`.

The editor verifies the live snapshot at acceptance time. Malformed edits or
permission violations end the session without applying that edit. Valid partial
work already accepted remains in the document if a later step fails.

### Usage

```json
{"type":"usage","total_tokens":1234,"estimated":false}
```

Send usage for **each call**, not a cumulative total, including calls discarded
because of human updates. The editor accumulates it for the current task and
stops over-budget work. Adapters must enforce their request cap and preflight
budget themselves; the editor cannot audit an arbitrary subprocess's API usage.

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

"""Deterministic protocol peer for headless integration tests; no network."""
import json
import signal
import sys
import time


def read():
    return json.loads(sys.stdin.readline())


def send(message):
    print(json.dumps(message), flush=True)


start = read()
scenario = sys.argv[1]
task = start["task"]
revision = start["revision"]
send({"type": "usage", "total_tokens": 10 if scenario == "budget" else 1})


def proposal(rev, done=True):
    edit = {"type": "edit", "revision": rev, "result": task["result"] + ["Agent notes"], "done": done}
    if task["mode"] == "build" or scenario == "illegal":
        edit["target"] = [line.upper() for line in task["target"]]
    return edit


if scenario == "late":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(0.2)
    send(proposal(revision))
elif scenario == "stale":
    # Respond before the long editor debounce, forcing synchronous invalidation.
    time.sleep(0.15)
    send(proposal(revision))
    update = read()
    assert update["type"] == "update", update
    for field, splice in update["changes"].items():
        start_at = splice["start"]
        task[field][start_at:start_at + splice["delete"]] = splice["lines"]
    revision = update["revision"]
    ack = read()
    assert ack["type"] == "ack" and not ack["accepted"], ack
    send(proposal(revision))
elif scenario == "intermediate" or scenario == "blocked":
    first = proposal(revision, False)
    send(first)
    ack = read()
    # An agent-originated edit must produce an ack, not a human update.
    assert ack["type"] == "ack" and ack["accepted"], ack
    revision = ack["revision"]
    task["result"] = first["result"]
    if "target" in first:
        task["target"] = first["target"]
    if scenario == "blocked":
        send({"type": "blocked", "message": "Question saved inline"})
    else:
        send(proposal(revision))
elif scenario == "malformed":
    print("not json", flush=True)
elif scenario == "oversized":
    print("x" * 2048, flush=True)
else:
    time.sleep(0.1)
    send(proposal(revision))

# Give Neovim an opportunity to read the final message and terminate the job.
time.sleep(1)

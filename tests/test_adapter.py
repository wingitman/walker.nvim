import copy
import importlib.util
import pathlib
import queue
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "walker_agent", pathlib.Path(__file__).parents[1] / "adapters" / "openai_agent.py"
)
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)


def start(mode="build"):
    return {
        "type": "start", "protocol": 1, "revision": 1,
        "task": {"id": "t", "mode": mode, "tags": "#" + mode, "brief": "Preserve voice",
                 "instructions": ["Improve"], "result": [], "target": ["old"]},
        "limits": {"max_requests": 4, "max_output_tokens": 100, "token_budget": 20000},
    }


class FakeClient:
    prepare = agent.Client.prepare

    def __init__(self, callback):
        self.model = "fake"
        self.calls = []
        self.callback = callback

    def complete(self, body):
        self.calls.append(copy.deepcopy(body))
        return self.callback(len(self.calls))


class AdapterTests(unittest.TestCase):
    def test_splices_and_revisions(self):
        task = start()["task"]
        update = {"base_revision": 1, "revision": 2, "changes": {
            "target": {"start": 0, "delete": 1, "lines": ["human", "new"]}
        }}
        updated, revision = agent.apply_update(task, 1, update)
        self.assertEqual(updated["target"], ["human", "new"])
        self.assertEqual(task["target"], ["old"])
        self.assertEqual(revision, 2)
        with self.assertRaises(agent.AgentError):
            agent.apply_update(task, 2, update)
        update["changes"]["target"]["delete"] = 99
        with self.assertRaises(agent.AgentError):
            agent.apply_update(task, 1, update)

    def test_permission_and_output_validation(self):
        for edit in ({"result": ["x\ny"], "done": True},
                     {"result": [], "done": True, "target": []},
                     {"result": [], "done": True, "blocked": True}):
            with self.assertRaises(agent.AgentError):
                agent.validate_edit(edit, "plan")

    def test_update_during_request_discards_old_response(self):
        inbox, sent = queue.Queue(), []
        inbox.put(start())

        def complete(call):
            if call == 1:
                inbox.put({"type": "update", "base_revision": 1, "revision": 2,
                           "changes": {"target": {"start": 0, "delete": 1, "lines": ["human"]}}})
                return {"result": ["stale"], "target": ["stale"], "done": True}, 10
            return {"result": ["fresh"], "target": ["human revised"], "done": True}, 10

        def send(message):
            sent.append(message)
            if message["type"] == "edit":
                inbox.put({"type": "ack", "accepted": True, "revision": 3})

        client = FakeClient(complete)
        agent.run(inbox, client, send)
        edits = [message for message in sent if message["type"] == "edit"]
        self.assertEqual(len(edits), 1)
        self.assertEqual(edits[0]["revision"], 2)
        self.assertEqual(edits[0]["target"], ["human revised"])
        self.assertEqual(len(client.calls[1]["messages"]), 2)
        self.assertIn("human", client.calls[1]["messages"][1]["content"])
        self.assertNotIn("stale", client.calls[1]["messages"][1]["content"])

    def test_update_between_response_and_ack_retries(self):
        inbox, edits = queue.Queue(), []
        inbox.put(start())
        client = FakeClient(lambda _: ({"result": [], "target": ["revised"], "done": True}, 5))

        def send(message):
            if message["type"] != "edit":
                return
            edits.append(message)
            if len(edits) == 1:
                inbox.put({"type": "update", "base_revision": 1, "revision": 2,
                           "changes": {"instructions": {"start": 0, "delete": 1, "lines": ["Changed goal"]}}})
                inbox.put({"type": "ack", "accepted": False, "revision": 2})
            else:
                inbox.put({"type": "ack", "accepted": True, "revision": 3})

        agent.run(inbox, client, send)
        self.assertEqual([edit["revision"] for edit in edits], [1, 2])
        self.assertIn("Changed goal", client.calls[1]["messages"][1]["content"])

    def test_budget_prevents_call(self):
        inbox = queue.Queue()
        message = start()
        message["limits"]["token_budget"] = 1
        inbox.put(message)
        client = FakeClient(lambda _: self.fail("Must not call provider"))
        with self.assertRaisesRegex(agent.AgentError, "budget"):
            agent.run(inbox, client)
        self.assertEqual(client.calls, [])

    def test_missing_usage_uses_estimate(self):
        inbox, sent = queue.Queue(), []
        inbox.put(start("plan"))
        client = FakeClient(lambda _: ({"result": ["Plan"], "done": True}, None))

        def send(message):
            sent.append(message)
            if message["type"] == "edit":
                inbox.put({"type": "ack", "accepted": True, "revision": 2})

        agent.run(inbox, client, send)
        self.assertTrue(sent[0]["estimated"])
        self.assertGreater(sent[0]["total_tokens"], 100)

    def test_blocked_question_stays_pending(self):
        inbox, sent = queue.Queue(), []
        inbox.put(start("review"))
        client = FakeClient(lambda _: ({"result": ["Which audience?"], "done": False, "blocked": True}, 5))

        def send(message):
            sent.append(message)
            if message["type"] == "edit":
                inbox.put({"type": "ack", "accepted": True, "revision": 2})

        agent.run(inbox, client, send)
        self.assertEqual(sent[-1]["type"], "blocked")
        self.assertFalse(sent[1]["done"])

    def test_remote_plaintext_and_embedded_credentials_rejected(self):
        for url in ("http://example.com/v1", "https://secret@example.com/v1", "file:///tmp/x"):
            with patch.dict("os.environ", {"WALKER_BASE_URL": url, "WALKER_MODEL": "fake"}):
                with self.assertRaises(agent.AgentError):
                    agent.Client()

    def test_redirects_never_forward_credentials(self):
        self.assertIsNone(agent.NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere"))


if __name__ == "__main__":
    unittest.main()

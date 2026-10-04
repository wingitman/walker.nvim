import copy
import io
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

    def test_file_creation_validation(self):
        edit = {"result": [], "done": True, "create_file": {"name": "hello.py", "lines": ["print('hello')"]}}
        self.assertEqual(agent.validate_edit(edit, "build", "/document"), edit)
        for mode, directory in (("plan", "/document"), ("review", "/document"), ("build", None)):
            with self.assertRaises(agent.AgentError):
                agent.validate_edit(edit, mode, directory)
        for name in ("../x.py", "/tmp/x.py", "dir/x.py", "dir\\x.py", ".env", "", "x\n.py", "é.py"):
            invalid = copy.deepcopy(edit)
            invalid["create_file"]["name"] = name
            with self.assertRaises(agent.AgentError):
                agent.validate_edit(invalid, "build", "/document")
        for extra in ({"target": []}, {"done": False}, {"blocked": True},
                      {"create_file": {"name": "hello.py", "lines": ["a\nb"]}}):
            with self.assertRaises(agent.AgentError):
                agent.validate_edit(dict(edit, **extra), "build", "/document")

    def test_context_updates_and_file_proposals_survive_the_adapter(self):
        inbox, sent = queue.Queue(), []
        initial = start()
        initial["task"].update(context=["print('old')"], create_file_directory="/document")
        inbox.put(initial)

        def complete(call):
            if call == 1:
                inbox.put({"type": "update", "base_revision": 1, "revision": 2,
                           "changes": {"context": {"start": 0, "delete": 1, "lines": ["print('new')"]}}})
            return {"result": [], "done": True,
                    "create_file": {"name": "hello.py", "lines": ["print('new')"]}}, 5

        def send(message):
            sent.append(message)
            if message["type"] == "edit":
                inbox.put({"type": "ack", "accepted": True, "revision": 3})

        client = FakeClient(complete)
        agent.run(inbox, client, send)
        edits = [message for message in sent if message["type"] == "edit"]
        self.assertEqual(len(edits), 1)
        self.assertEqual(edits[0]["revision"], 2)
        self.assertEqual(edits[0]["create_file"], {"name": "hello.py", "lines": ["print('new')"]})
        self.assertIn("print('new')", client.calls[1]["messages"][1]["content"])

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
            agent.run(inbox, client, lambda _: None)
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
        reported = next(item for item in sent if item["type"] == "usage")
        self.assertTrue(reported["estimated"])
        self.assertGreater(reported["total_tokens"], 100)

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
        proposed = next(item for item in sent if item["type"] == "edit")
        self.assertFalse(proposed["done"])
        self.assertTrue(proposed["blocked"])
        self.assertIn("Walker question [needs-input]:", proposed["result"])

    def test_remote_plaintext_and_embedded_credentials_rejected(self):
        for url in ("http://example.com/v1", "https://secret@example.com/v1", "file:///tmp/x"):
            with patch.dict("os.environ", {"WALKER_BASE_URL": url, "WALKER_MODEL": "fake"}):
                with self.assertRaises(agent.AgentError):
                    agent.Client()

    def test_redirects_never_forward_credentials(self):
        self.assertIsNone(agent.NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere"))

    def test_deepseek_usage_breakdown(self):
        self.assertEqual(agent.usage_report({"total_tokens": 150, "prompt_tokens": 100,
                                           "completion_tokens": 50, "prompt_cache_hit_tokens": 40,
                                           "completion_tokens_details": {"reasoning_tokens": 20}}),
                         {"total_tokens": 150, "input_tokens": 100, "output_tokens": 50,
                          "cached_tokens": 40, "reasoning_tokens": 20})
        self.assertEqual(agent.usage_report({"total_tokens": 1, "prompt_tokens_details": {"cached_tokens": 0}}),
                         {"total_tokens": 1, "cached_tokens": 0})
        with self.assertRaises(agent.AgentError):
            agent.usage_report({"total_tokens": -1})

    def test_concise_editing_policy_and_reasoning_separation(self):
        import json
        from unittest.mock import Mock
        with patch.dict("os.environ", {"WALKER_MODEL": "fake", "WALKER_API_KEY": "test-only"}, clear=True):
            client = agent.Client()
        body = client.prepare(start()["task"], 500)
        policy = body["messages"][0]["content"]
        self.assertIn("no thinking aloud", policy)
        self.assertIn("Build result should normally be empty", policy)
        self.assertIn("instead of accumulating a transcript", policy)
        client.opener = Mock()
        edit = {"target": ["print('hello')"], "result": [], "done": True}
        client.opener.open.return_value = io.BytesIO(json.dumps({
            "choices": [{"finish_reason": "stop", "message": {
                "content": json.dumps(edit), "reasoning_content": "Private provider reasoning"
            }}], "usage": {"total_tokens": 25}
        }).encode())
        result, _ = client.complete(body)
        self.assertEqual(result, edit)
        self.assertNotIn("reasoning", json.dumps(result))

    def test_deepseek_disables_thinking_by_default_without_affecting_other_hosts(self):
        with patch.dict("os.environ", {"WALKER_MODEL": "deepseek-flash", "WALKER_API_KEY": "test-only",
                                      "WALKER_BASE_URL": "https://api.deepseek.com"}, clear=True):
            client = agent.Client()
            self.assertEqual(client.prepare(start()["task"], 500)["thinking"], {"type": "disabled"})
            with patch.dict("os.environ", {"WALKER_THINKING": "enabled"}):
                self.assertEqual(agent.Client().prepare(start()["task"], 500)["thinking"], {"type": "enabled"})
            with patch.dict("os.environ", {"WALKER_BASE_URL": "https://example.com"}):
                self.assertNotIn("thinking", agent.Client().prepare(start()["task"], 500))

    def test_balance_request_is_read_only_and_contains_no_document(self):
        import json
        from unittest.mock import Mock
        with patch.dict("os.environ", {"WALKER_API_KEY": "test-only", "WALKER_BASE_URL": "https://api.deepseek.com/v1"}, clear=True):
            client = agent.Client(require_model=False)
        client.opener = Mock()
        client.opener.open.return_value = io.BytesIO(json.dumps({"balance_infos": [{"currency": "USD", "total_balance": "4.82"}]}).encode())
        self.assertEqual(client.balance()["balance_infos"][0]["total_balance"], "4.82")
        request = client.opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.deepseek.com/user/balance")
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)

    def test_usage_survives_incomplete_response_failure(self):
        import json
        from unittest.mock import Mock
        with patch.dict("os.environ", {"WALKER_MODEL": "fake", "WALKER_API_KEY": "test-only"}, clear=True):
            client = agent.Client()
        client.opener = Mock()
        client.opener.open.return_value = io.BytesIO(json.dumps({
            "usage": {"total_tokens": 10}, "choices": [{"finish_reason": "length"}]
        }).encode())
        inbox, sent = queue.Queue(), []
        inbox.put(start())
        with self.assertRaisesRegex(agent.AgentError, "incomplete"):
            agent.run(inbox, client, sent.append)
        self.assertEqual([item["total_tokens"] for item in sent if item["type"] == "usage"], [10])
        self.assertFalse(any(item["type"] == "edit" for item in sent))

    def test_http_errors_do_not_expose_provider_body_or_keys(self):
        from unittest.mock import Mock
        with patch.dict("os.environ", {"WALKER_MODEL": "fake", "WALKER_API_KEY": "test-only"}, clear=True):
            client = agent.Client()
        client.opener = Mock()
        client.opener.open.side_effect = agent.urllib.error.HTTPError(
            "https://example.com", 403, "secret provider body", {}, io.BytesIO(b"private text"))
        with self.assertRaises(agent.AgentError) as raised:
            client.complete({})
        self.assertIn("403", str(raised.exception))
        self.assertNotIn("secret", str(raised.exception))
        self.assertNotIn("private", str(raised.exception))
        self.assertNotIn("test-only", str(raised.exception))


if __name__ == "__main__":
    unittest.main()

"""Full Neovim → real adapter → local HTTP provider → Neovim test."""
import http.server
import json
import os
import pathlib
import shutil
import subprocess
import threading
import time
import unittest


class EndToEndTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("nvim"), "Neovim required")
    def test_live_update_through_http_adapter(self):
        requests = []

        class Provider(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append((self.path, body))
                task = json.loads(body["messages"][1]["content"])
                if len(requests) == 1:
                    time.sleep(0.5)  # Human changes the buffer during this request.
                content = {"result": ["Capitalized the passage."], "done": True,
                           "target": [line.upper() for line in task["target"]]}
                response = json.dumps({
                    "choices": [{"finish_reason": "stop", "message": {"content": json.dumps(content)}}],
                    "usage": {"total_tokens": 10},
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = os.environ.copy()
        env.update({"WALKER_MODEL": "test-model", "WALKER_API_KEY": "", "OPENAI_API_KEY": "",
                    "WALKER_BASE_URL": "http://127.0.0.1:" + str(server.server_port) + "/v1"})
        try:
            result = subprocess.run(
                ["nvim", "--headless", "-u", "NONE", "-l", "tests/http.lua"],
                cwd=pathlib.Path(__file__).parents[1], env=env, capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(len(requests), 2)
            self.assertEqual(requests[0][0], "/v1/chat/completions")
            first = json.loads(requests[0][1]["messages"][1]["content"])
            second = json.loads(requests[1][1]["messages"][1]["content"])
            self.assertEqual(first["target"], ["original passage"])
            self.assertEqual(second["target"], ["human edited passage"])
            self.assertEqual(len(requests[1][1]["messages"]), 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()

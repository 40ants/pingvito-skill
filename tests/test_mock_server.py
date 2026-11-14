import http.client
import json
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


MOCK_SERVER = Path(__file__).resolve().parents[1] / "evals/fixtures/mock_server.py"
TOKEN = "1" * 64
OTHER_TOKEN = "2" * 64
READY_TIMEOUT = 10.0


class MockServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        # The server must create missing parent directories for both paths.
        self.log_path = root / "log" / "requests.jsonl"
        self.ready_path = root / "ready" / "server.json"
        self.process = None
        self.addCleanup(self.stop_server)

    def start_server(self, *extra):
        self.process = subprocess.Popen(
            [sys.executable, str(MOCK_SERVER),
             "--log", str(self.log_path), "--ready", str(self.ready_path), *extra],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + READY_TIMEOUT
        while time.monotonic() < deadline:
            if self.ready_path.exists():
                ready = json.loads(self.ready_path.read_text(encoding="utf-8"))
                self.port = ready["port"]
                return ready
            if self.process.poll() is not None:
                self.fail(f"mock server exited with code {self.process.returncode}")
            time.sleep(0.05)
        self.fail("mock server did not write its ready file")

    def stop_server(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()

    def post(self, path, body):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            connection.request("POST", path, body=body,
                               headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def post_json(self, path, payload):
        status, body = self.post(
            path, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        return status, json.loads(body)

    def ask(self, token=TOKEN, question="Deploy?", options=("Yes", "No")):
        return self.post_json("/ask", {"token": token, "question": question,
                                       "options": list(options)})

    def poll(self, token=TOKEN):
        return self.post_json("/get-response", {"token": token})

    def read_log(self):
        return [json.loads(line) for line in
                self.log_path.read_text(encoding="utf-8").splitlines()]

    def test_notify_ask_get_response_endpoints(self):
        self.start_server()
        for path, payload, expected in [
                ("/notify", {"token": TOKEN, "text": "Finished"}, {"ok": True}),
                ("/ask", {"token": TOKEN, "question": "Deploy?",
                          "options": ["Yes", "No"]}, {"ok": True}),
                ("/get-response", {"token": TOKEN}, {"status": "pending"})]:
            with self.subTest(endpoint=path):
                status, body = self.post(path, json.dumps(payload).encode("utf-8"))
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body), expected)
        self.assertEqual(self.read_log(), [
            {"endpoint": "/notify", "status": 200, "response": {"ok": True},
             "body": {"token": TOKEN, "text": "Finished"}},
            {"endpoint": "/ask", "status": 200, "response": {"ok": True},
             "body": {"token": TOKEN, "question": "Deploy?",
                      "options": ["Yes", "No"]}},
            {"endpoint": "/get-response", "status": 200,
             "response": {"status": "pending"},
             "body": {"token": TOKEN}}])

    def test_get_response_answers_last_option_after_pending_polls(self):
        self.start_server()
        status, body = self.ask(question="Deploy the change?",
                                options=("Deploy", "Hold"))
        self.assertEqual((status, body), (200, {"ok": True}))
        # The first two polls after the ask report a pending choice.
        for expected in ({"status": "pending"}, {"status": "pending"}):
            status, body = self.poll()
            self.assertEqual((status, body), (200, expected))
        # The third poll returns the last offered option as the answer.
        status, body = self.poll()
        self.assertEqual((status, body), (200, {"result": "Hold"}))
        # Served payloads are archived beside the request bodies.
        self.assertEqual([entry["response"] for entry in self.read_log()],
                         [{"ok": True},
                          {"status": "pending"},
                          {"status": "pending"},
                          {"result": "Hold"}])

    def test_get_response_without_ask_stays_pending(self):
        self.start_server()
        for _ in range(3):
            status, body = self.poll()
            self.assertEqual((status, body), (200, {"status": "pending"}))

    def test_new_ask_resets_the_pending_counter(self):
        self.start_server()
        self.ask()
        self.poll()
        # A repeated ask restarts the countdown for its token.
        self.ask()
        for expected in ({"status": "pending"}, {"status": "pending"}):
            _, body = self.poll()
            self.assertEqual(body, expected)
        _, body = self.poll()
        self.assertEqual(body, {"result": "No"})

    def test_pending_responses_option_shortens_the_wait(self):
        self.start_server("--pending-responses", "1")
        self.ask(options=("Deploy", "Hold"))
        _, body = self.poll()
        self.assertEqual(body, {"status": "pending"})
        _, body = self.poll()
        self.assertEqual(body, {"result": "Hold"})

    def test_answer_delay_holds_the_result_until_elapsed(self):
        self.start_server("--answer-delay", "1")
        started = time.monotonic()
        self.ask(options=("Deploy", "Hold"))
        # The countdown alone no longer releases the answer.
        for _ in range(3):
            _, body = self.poll()
            self.assertEqual(body, {"status": "pending"})
        # Once the delay since the ask has elapsed, the answer is served.
        remaining = 1.0 - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining + 0.05)
        _, body = self.poll()
        self.assertEqual(body, {"result": "Hold"})

    def test_answer_delay_zero_keeps_countdown_behavior(self):
        self.start_server()
        self.ask(options=("Deploy", "Hold"))
        for expected in ({"status": "pending"}, {"status": "pending"}):
            _, body = self.poll()
            self.assertEqual(body, expected)
        _, body = self.poll()
        self.assertEqual(body, {"result": "Hold"})

    def test_new_ask_restarts_the_delay_window(self):
        self.start_server("--answer-delay", "1")
        started = time.monotonic()
        self.ask(options=("Deploy", "Hold"))
        for _ in range(3):
            _, body = self.poll()
            self.assertEqual(body, {"status": "pending"})
        remaining = 1.0 - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining + 0.05)
        # A repeated ask restarts both the countdown and the delay window.
        self.ask(options=("Ship", "Ditch"))
        for _ in range(3):
            _, body = self.poll()
            self.assertEqual(body, {"status": "pending"})
        time.sleep(1.05)
        _, body = self.poll()
        self.assertEqual(body, {"result": "Ditch"})

    def test_ask_state_is_tracked_per_token(self):
        self.start_server()
        self.ask(token=TOKEN, options=("Deploy", "Hold"))
        # Another token's polls never consume the first token's countdown.
        for _ in range(3):
            _, body = self.poll(token=OTHER_TOKEN)
            self.assertEqual(body, {"status": "pending"})
        _, body = self.poll(token=TOKEN)
        self.assertEqual(body, {"status": "pending"})
        _, body = self.poll(token=TOKEN)
        self.assertEqual(body, {"status": "pending"})
        _, body = self.poll(token=TOKEN)
        self.assertEqual(body, {"result": "Hold"})

    def test_api_prefix_routes_like_canonical_and_logs_canonical(self):
        self.start_server()
        for path, payload, expected in [
                ("/api/notify", {"token": TOKEN, "text": "Готово"}, {"ok": True}),
                ("/api/get-response", {"token": TOKEN}, {"status": "pending"})]:
            with self.subTest(endpoint=path):
                status, body = self.post(
                    path, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body), expected)
        status, _ = self.post("/api/unknown",
                              json.dumps({"token": TOKEN}).encode("utf-8"))
        self.assertEqual(status, 404)
        # Every entry is logged under its canonical unprefixed endpoint,
        # regardless of which client form was used.
        self.assertEqual(self.read_log(), [
            {"endpoint": "/notify", "status": 200, "response": {"ok": True},
             "body": {"token": TOKEN, "text": "Готово"}},
            {"endpoint": "/get-response", "status": 200,
             "response": {"status": "pending"},
             "body": {"token": TOKEN}},
            {"endpoint": "/unknown", "status": 404,
             "response": {"error": "not found"},
             "body": {"token": TOKEN}}])

    def test_fail_notify_mode(self):
        self.start_server("--fail-notify")
        status, body = self.post("/notify",
                                 json.dumps({"token": TOKEN, "text": "Done"}).encode("utf-8"))
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(body), {"error": "service unavailable"})
        self.assertEqual(self.read_log(), [
            {"endpoint": "/notify", "status": 500,
             "response": {"error": "service unavailable"},
             "body": {"token": TOKEN, "text": "Done"}}])

    def test_ephemeral_port_and_ready_file(self):
        ready = self.start_server()
        self.assertEqual(set(ready), {"pid", "port"})
        self.assertEqual(ready["pid"], self.process.pid)
        self.assertIsInstance(ready["port"], int)
        with socket.create_connection(("127.0.0.1", ready["port"]), timeout=5):
            pass

    def test_cyrillic_payload_logged_verbatim(self):
        self.start_server()
        text = "Готово: правки внесены"
        status, _ = self.post("/notify",
                              json.dumps({"token": TOKEN, "text": text},
                                         ensure_ascii=False).encode("utf-8"))
        self.assertEqual(status, 200)
        self.assertEqual(self.read_log(), [
            {"endpoint": "/notify", "status": 200, "response": {"ok": True},
             "body": {"token": TOKEN, "text": text}}])

    def test_unknown_path_and_bad_json(self):
        self.start_server()
        status, _ = self.post("/bogus", json.dumps({"token": TOKEN}).encode("utf-8"))
        self.assertEqual(status, 404)
        status, _ = self.post("/notify", b"not json")
        self.assertEqual(status, 400)
        self.assertEqual(self.read_log(), [
            {"endpoint": "/bogus", "status": 404,
             "response": {"error": "not found"},
             "body": {"token": TOKEN}},
            {"endpoint": "/notify", "status": 400,
             "response": {"error": "malformed JSON"},
             "body": None}])

    def test_sigterm_stops_server(self):
        self.start_server()
        status, _ = self.post("/notify",
                              json.dumps({"token": TOKEN, "text": "Bye"}).encode("utf-8"))
        self.assertEqual(status, 200)
        self.process.send_signal(signal.SIGTERM)
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.assertEqual(self.read_log(), [
            {"endpoint": "/notify", "status": 200, "response": {"ok": True},
             "body": {"token": TOKEN, "text": "Bye"}}])


if __name__ == "__main__":
    unittest.main()

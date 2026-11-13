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
            {"endpoint": "/notify", "status": 200,
             "body": {"token": TOKEN, "text": "Finished"}},
            {"endpoint": "/ask", "status": 200,
             "body": {"token": TOKEN, "question": "Deploy?",
                      "options": ["Yes", "No"]}},
            {"endpoint": "/get-response", "status": 200,
             "body": {"token": TOKEN}}])

    def test_fail_notify_mode(self):
        self.start_server("--fail-notify")
        status, body = self.post("/notify",
                                 json.dumps({"token": TOKEN, "text": "Done"}).encode("utf-8"))
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(body), {"error": "service unavailable"})
        self.assertEqual(self.read_log(), [
            {"endpoint": "/notify", "status": 500,
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
            {"endpoint": "/notify", "status": 200,
             "body": {"token": TOKEN, "text": text}}])

    def test_unknown_path_and_bad_json(self):
        self.start_server()
        status, _ = self.post("/bogus", json.dumps({"token": TOKEN}).encode("utf-8"))
        self.assertEqual(status, 404)
        status, _ = self.post("/notify", b"not json")
        self.assertEqual(status, 400)
        self.assertEqual(self.read_log(), [
            {"endpoint": "/bogus", "status": 404, "body": {"token": TOKEN}},
            {"endpoint": "/notify", "status": 400, "body": None}])

    def test_sigterm_stops_server(self):
        self.start_server()
        status, _ = self.post("/notify",
                              json.dumps({"token": TOKEN, "text": "Bye"}).encode("utf-8"))
        self.assertEqual(status, 200)
        self.process.send_signal(signal.SIGTERM)
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.assertEqual(self.read_log(), [
            {"endpoint": "/notify", "status": 200,
             "body": {"token": TOKEN, "text": "Bye"}}])


if __name__ == "__main__":
    unittest.main()

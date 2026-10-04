import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / ".apm/skills/pingvito/scripts"
TOKEN = "1" * 64


def load_helper(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "settings/config.json"
        self.configure = load_helper("configure")

    def test_first_setup_creates_private_configuration(self):
        self.configure.save_token(self.path, TOKEN)
        self.assertEqual(json.loads(self.path.read_text()),
                         {"host": "https://pingvito.ru/api", "token": TOKEN})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_replacement_preserves_settings_and_can_change_host(self):
        self.path.parent.mkdir()
        self.path.write_text(json.dumps({"host": "http://localhost:8081",
                                         "token": TOKEN, "extra": True}))
        self.configure.save_token(self.path, "2" * 64, host="https://pingvito.ru/api/")
        self.assertEqual(json.loads(self.path.read_text()),
                         {"host": "https://pingvito.ru/api", "token": "2" * 64,
                          "extra": True})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_bad_input_leaves_previous_configuration_untouched(self):
        self.path.parent.mkdir()
        self.path.write_text(json.dumps({"host": "https://pingvito.ru/api", "token": TOKEN}))
        before = self.path.read_bytes()
        for token, host in [("invalid", None), (TOKEN, "ftp://example.com"),
                            (TOKEN, "https://example.com?token=secret")]:
            with self.subTest(host=host), self.assertRaises(ValueError):
                self.configure.save_token(self.path, token, host=host)
            self.assertEqual(self.path.read_bytes(), before)

    def test_failed_atomic_replace_preserves_file_and_cleans_temporary(self):
        self.path.parent.mkdir()
        self.path.write_text(json.dumps({"host": "https://pingvito.ru/api", "token": TOKEN}))
        before = self.path.read_bytes()
        with patch.object(self.configure.os, "replace", side_effect=OSError("test failure")):
            with self.assertRaises(OSError):
                self.configure.save_token(self.path, "2" * 64)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.glob(".config-*")), [])

    @unittest.skipUnless(os.name == "posix", "hidden terminal input uses a POSIX PTY")
    def test_hidden_cli_prompt_does_not_echo_token(self):
        import pty
        master, slave = pty.openpty()
        wrapper = (
            "import importlib.util,pathlib,sys;"
            "spec=importlib.util.spec_from_file_location('configure',sys.argv[1]);"
            "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);"
            "m.CONFIG_PATH=pathlib.Path(sys.argv[2]);"
            "sys.argv=['configure.py'];m.main()"
        )
        process = subprocess.Popen([sys.executable, "-c", wrapper,
                                    str(SCRIPTS / "configure.py"), str(self.path)],
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = b""
        try:
            deadline = time.monotonic() + 5
            while b": " not in output and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    output += os.read(master, 4096)
            self.assertIn(b"token", output.lower())
            os.write(master, (TOKEN + "\n").encode())
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output += os.read(master, 4096)
                    except OSError:
                        break
            process.wait(timeout=3)
            self.assertEqual(process.returncode, 0, output.decode(errors="replace"))
            self.assertNotIn(TOKEN.encode(), output)
            self.assertEqual(json.loads(self.path.read_text())["token"], TOKEN)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append((self.path, self.command,
                                     self.headers["Content-Type"], body))
        self.send_response(self.server.status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(self.server.body)

    def log_message(self, *args):
        pass


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.notify = load_helper("notify")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.requests = []
        self.server.status = 200
        self.server.body = b'{}'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.host = f"http://127.0.0.1:{self.server.server_port}/api"
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def test_notification_and_question_use_json_api_contract(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.notify.send_notification(self.host, TOKEN, "Finished")
            self.notify.ask_question(self.host, TOKEN, "Deploy?", ["Yes", "No"])
        self.assertEqual(self.server.requests,
                         [("/api/notify", "POST", "application/json",
                           {"token": TOKEN, "text": "Finished"}),
                          ("/api/ask", "POST", "application/json",
                           {"token": TOKEN, "question": "Deploy?", "options": ["Yes", "No"]})])
        self.assertNotIn(TOKEN, output.getvalue())

    def test_pending_and_answered_responses_have_distinct_exit_status(self):
        self.server.body = b'{"result":null,"status":"pending"}'
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as error:
            self.notify.get_response(self.host, TOKEN)
        self.assertEqual(error.exception.code, 2)
        self.server.body = b'{"result":"Yes"}'
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.notify.get_response(self.host, TOKEN)
        self.assertEqual(output.getvalue().strip(), "Yes")

    def test_invalid_responses_and_http_errors_do_not_echo_response_secrets(self):
        for status, body in [(200, TOKEN.encode()), (200, b'[]'), (500, TOKEN.encode())]:
            self.server.status, self.server.body = status, body
            with self.subTest(status=status), contextlib.redirect_stderr(io.StringIO()) as output:
                with self.assertRaises(SystemExit) as error:
                    self.notify.post_json(self.host, "notify", {"token": TOKEN})
                self.assertEqual(error.exception.code, 1)
                self.assertNotIn(TOKEN, output.getvalue())

    def test_requests_have_a_finite_timeout(self):
        with patch.object(self.notify, "urlopen", side_effect=OSError("test failure")) as opened:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.notify.post_json(self.host, "notify", {"token": TOKEN})
        self.assertEqual(opened.call_args.kwargs["timeout"], 10)

    def test_incomplete_question_fails_without_request(self):
        with patch.object(self.notify, "load_config", return_value=(self.host, TOKEN)):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.notify.main(["notify.py", "ask"])
        self.assertEqual(error.exception.code, 1)
        self.assertEqual(self.server.requests, [])


if __name__ == "__main__":
    unittest.main()

"""Local mock of the Pingvito HTTP API for the eval suite.

Usage: python3 mock_server.py --log LOG_PATH --ready READY_PATH
       [--fail-notify] [--pending-responses N]

Writes the ready file (JSON with the server pid and port) once the socket
listens, then serves until SIGTERM or SIGINT. Every received request —
answered or rejected — is appended to LOG_PATH as one UTF-8 JSON line under
its canonical unprefixed endpoint; an optional leading "/api" base path is
accepted and stripped: {"endpoint": "/notify", "status": 200,
"body": {...}, "response": {...}} where "response" is the served payload.

/get-response answers {"status": "pending"} for a token with no preceding
/ask; after an /ask it stays pending for --pending-responses polls
(default 2) and then returns {"result": <last option of that ask>}, so a
compliant client must keep polling instead of assuming the first option.
A new /ask restarts the countdown. Ask state is tracked per token.
"""

import argparse
import json
import os
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ENDPOINTS = ("/notify", "/ask", "/get-response")


class MockAskState:
    """Thread-safe per-token countdown of pending polls after each /ask."""

    def __init__(self, pending_responses):
        self.pending_responses = pending_responses
        self._lock = threading.Lock()
        self._asks = {}

    def record_ask(self, body):
        """Seed or restart a token's countdown from a well-formed /ask body."""
        if not isinstance(body, dict):
            return
        token = body.get("token")
        options = body.get("options")
        if not (isinstance(token, str) and token
                and isinstance(options, list) and options
                and all(isinstance(option, str) and option for option in options)):
            return
        with self._lock:
            self._asks[token] = {"options": list(options),
                                 "pending": self.pending_responses}

    def answer(self, body):
        """Serve one /get-response poll, consuming the token's countdown."""
        token = body.get("token") if isinstance(body, dict) else None
        with self._lock:
            state = self._asks.get(token) if isinstance(token, str) else None
            if state is None:
                return {"status": "pending"}
            if state["pending"] > 0:
                state["pending"] -= 1
                return {"status": "pending"}
            return {"result": state["options"][-1]}


class MockPingvitoHandler(BaseHTTPRequestHandler):
    server_version = "MockPingvito/1.0"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            body = None

        # Production clients post under the /api base path; routing and the
        # request log both use the canonical unprefixed endpoint.
        path = self.path
        if path.startswith("/api/"):
            path = path[len("/api"):]

        if path not in ENDPOINTS:
            status, payload = 404, {"error": "not found"}
        elif body is None:
            status, payload = 400, {"error": "malformed JSON"}
        else:
            status = 200
            if path == "/notify" and self.server.fail_notify:
                status, payload = 500, {"error": "service unavailable"}
            elif path == "/ask":
                self.server.ask_state.record_ask(body)
                payload = {"ok": True}
            elif path == "/get-response":
                payload = self.server.ask_state.answer(body)
            else:
                payload = {"ok": True}

        self.record_request(path, status, body, payload)
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record_request(self, endpoint, status, body, response):
        entry = json.dumps({"endpoint": endpoint, "status": status,
                            "body": body, "response": response},
                           ensure_ascii=False) + "\n"
        with self.server.log_lock:
            # Open-append-close keeps every entry flushed as it arrives,
            # so a SIGTERM'd server still leaves a complete log.
            with open(self.server.log_path, "a", encoding="utf-8") as log:
                log.write(entry)

    def log_message(self, *args):
        pass  # keep eval output pristine


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", required=True,
                        help="path of the JSONL request log to append to")
    parser.add_argument("--ready", required=True,
                        help="path of the ready file to write on startup")
    parser.add_argument("--fail-notify", action="store_true",
                        help="answer POST /notify with HTTP 500")
    parser.add_argument("--pending-responses", type=int, default=2, metavar="N",
                        help="number of pending /get-response polls served "
                             "after each /ask before the answer (default: 2)")
    args = parser.parse_args(argv)

    log_path, ready_path = Path(args.log), Path(args.ready)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    ready_path.parent.mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", 0), MockPingvitoHandler)
    server.log_path = log_path
    server.log_lock = threading.Lock()
    server.fail_notify = args.fail_notify
    server.ask_state = MockAskState(args.pending_responses)

    # The socket already listens after construction, so the ready file is
    # safe to publish before the first request is served.
    ready_path.write_text(json.dumps({"pid": os.getpid(),
                                      "port": server.server_port}),
                          encoding="utf-8")

    def request_stop(signum, frame):
        # shutdown() blocks until serve_forever() unwinds, so it must run
        # on another thread: signal handlers execute on the serving thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

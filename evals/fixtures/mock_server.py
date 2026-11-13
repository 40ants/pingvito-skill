"""Local mock of the Pingvito HTTP API for the eval suite.

Usage: python3 mock_server.py --log LOG_PATH --ready READY_PATH [--fail-notify]

Writes the ready file (JSON with the server pid and port) once the socket
listens, then serves until SIGTERM or SIGINT. Every received request —
answered or rejected — is appended to LOG_PATH as one UTF-8 JSON line under
its canonical unprefixed endpoint; an optional leading "/api" base path is
accepted and stripped: {"endpoint": "/notify", "status": 200, "body": {...}}
"""

import argparse
import json
import os
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


RESPONSES = {
    "/notify": {"ok": True},
    "/ask": {"ok": True},
    "/get-response": {"status": "pending"},
}


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

        if path not in RESPONSES:
            status, payload = 404, {"error": "not found"}
        elif body is None:
            status, payload = 400, {"error": "malformed JSON"}
        elif path == "/notify" and self.server.fail_notify:
            status, payload = 500, {"error": "service unavailable"}
        else:
            status, payload = 200, RESPONSES[path]

        self.record_request(path, status, body)
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record_request(self, endpoint, status, body):
        entry = json.dumps({"endpoint": endpoint, "status": status, "body": body},
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
    args = parser.parse_args(argv)

    log_path, ready_path = Path(args.log), Path(args.ready)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    ready_path.parent.mkdir(parents=True, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", 0), MockPingvitoHandler)
    server.log_path = log_path
    server.log_lock = threading.Lock()
    server.fail_notify = args.fail_notify

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

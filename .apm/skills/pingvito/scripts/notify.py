#!/usr/bin/env python3
"""Send Pingvito notifications and ask button-choice questions in MAX."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


CONFIG_PATH = Path.home() / ".config" / "pingvito" / "config.json"
TIMEOUT_SECONDS = 10


def fail(message: str) -> None:
    """Print a non-secret diagnostic and terminate with a failure status."""
    print(f"pingvito: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_config() -> tuple[str, str]:
    """Read and validate the local service configuration without exposing it."""
    try:
        config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"configuration not found: {CONFIG_PATH}")
    except (OSError, json.JSONDecodeError):
        fail("configuration is unreadable or invalid JSON")

    if not isinstance(config, dict):
        fail("configuration must be a JSON object")

    host = config.get("host")
    token = config.get("token")
    if not isinstance(host, str) or not host:
        fail("configuration field 'host' must be a non-empty string")
    if not isinstance(token, str) or not token:
        fail("configuration field 'token' must be a non-empty string")

    return host.rstrip("/"), token


def post_json(host: str, endpoint: str, payload: dict[str, object]) -> dict[str, object]:
    """POST PAYLOAD and return the service JSON object without exposing secrets."""
    request = Request(
        f"{host}/{endpoint}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8")
    except HTTPError as error:
        error.close()
        fail(f"service returned HTTP {error.code}")
    except URLError:
        fail("unable to reach MAX service")
    except OSError:
        fail("MAX request failed")

    try:
        result = json.loads(body)
    except json.JSONDecodeError:
        fail("service returned invalid JSON")
    if not isinstance(result, dict):
        fail("service returned an invalid JSON object")
    return result


def send_notification(host: str, token: str, text: str) -> None:
    """Send TEXT to the MAX chat associated with TOKEN."""
    post_json(host, "notify", {"token": token, "text": text})
    print("pingvito: notification sent")


def ask_question(host: str, token: str, question: str, options: list[str]) -> None:
    """Send QUESTION and button OPTIONS to the MAX chat associated with TOKEN."""
    post_json(host, "ask", {"token": token, "question": question, "options": options})
    print("pingvito: question sent")


def get_response(host: str, token: str) -> None:
    """Print the selected answer, or report that the MAX user has not answered yet."""
    result = post_json(host, "get-response", {"token": token})
    answer = result.get("result")
    if isinstance(answer, str):
        print(answer)
        return
    if answer is None and result.get("status") == "pending":
        print("pingvito: response pending")
        raise SystemExit(2)
    fail("service returned an invalid response")


def main(argv: list[str]) -> None:
    """Dispatch notification and interactive-question commands."""
    host, configured_token = load_config()
    if argv[1:2] == ["ask"]:
        if len(argv) < 4:
            fail("ask requires a question and non-empty options")
        question, *options = argv[2:]
        if question and question != "--token" and options and all(options):
            ask_question(host, configured_token, question, options)
            return
        fail("ask requires a question and non-empty options")

    if argv[1:2] == ["get-response"]:
        if len(argv) == 2:
            get_response(host, configured_token)
            return
        fail("get-response accepts no arguments")

    if len(argv) == 2 and argv[1].strip():
        send_notification(host, configured_token, argv[1])
        return

    fail("usage: notify.py 'notification text' | ask QUESTION OPTION... | get-response")


if __name__ == "__main__":
    main(sys.argv)

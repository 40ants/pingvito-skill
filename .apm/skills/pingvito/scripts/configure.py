#!/usr/bin/env python3
"""Configure Pingvito using a hidden token prompt."""

from __future__ import annotations

import getpass
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit


CONFIG_PATH = Path.home() / ".config" / "ai-notifier" / "config.json"
DEFAULT_HOST = "https://pingvito.ru/api"


def read_config(config_path: Path) -> dict:
    """Read personal settings internally, or start with an empty configuration."""
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    if not isinstance(config, dict):
        raise ValueError("configuration must be a JSON object")
    return config


def save_token(config_path: Path, token: str, host: Optional[str] = None) -> None:
    """Create or replace private settings while preserving unrelated fields."""
    if re.fullmatch(r"[0-9a-fA-F]{64}", token) is None:
        raise ValueError("Pingvito token must be 64 hexadecimal characters")

    config = read_config(config_path)
    selected_host = host if host is not None else config.get("host", DEFAULT_HOST)
    if not isinstance(selected_host, str) or not selected_host:
        raise ValueError("host must be an HTTP or HTTPS service URL")
    parsed = urlsplit(selected_host)
    if (parsed.scheme not in ("http", "https") or not parsed.netloc
            or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment):
        raise ValueError("host must be an HTTP or HTTPS URL without credentials, query, or fragment")

    config["host"] = selected_host.rstrip("/")
    config["token"] = token
    config_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".config-", dir=config_path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(config, output, ensure_ascii=False, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, config_path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main() -> None:
    args = sys.argv[1:]
    if args in (["--help"], ["-h"]):
        print("usage: configure.py [--host URL] (token is entered at a hidden prompt)")
        return
    if args and (len(args) != 2 or args[0] != "--host"):
        raise SystemExit("pingvito: usage: configure.py [--host URL]")
    host = args[1] if args else None
    if not sys.stdin.isatty():
        raise SystemExit("pingvito: configure in an interactive terminal")
    try:
        current = read_config(CONFIG_PATH)
        previous_token = current.get("token")
        prompt = ("Pingvito token (Enter keeps the current token): "
                  if previous_token else "Pingvito token: ")
        token = getpass.getpass(prompt).strip()
        if not token and isinstance(previous_token, str):
            token = previous_token
        save_token(CONFIG_PATH, token, host=host)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"pingvito: {error}") from None
    print("pingvito: settings saved; config mode 0600")


if __name__ == "__main__":
    main()

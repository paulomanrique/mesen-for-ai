#!/usr/bin/env python3
import argparse
import json
import socket
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--args", default="{}")
    ns = parser.parse_args()

    request = {
        "id": 1,
        "command": ns.command,
        "args": json.loads(ns.args),
    }
    with socket.create_connection((ns.host, ns.port), timeout=5) as sock:
        sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
        response = sock.makefile("r", encoding="utf-8").readline()
    if not response:
        raise SystemExit("no response")
    sys.stdout.write(json.dumps(json.loads(response), indent=2, sort_keys=True))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import json
import socket
from dataclasses import dataclass
from typing import Any


@dataclass
class BridgeClient:
    host: str
    port: int
    timeout: float = 60.0
    _next_id: int = 1

    def request(self, command: str, args: dict[str, Any] | None = None) -> Any:
        request_id = self._next_id
        self._next_id += 1
        payload = {"id": request_id, "command": command, "args": args or {}}
        with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
            sock.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode())
            line = sock.makefile("r", encoding="utf-8").readline()
        if not line:
            raise RuntimeError("bridge closed without a response")
        response = json.loads(line)
        if "error" in response:
            error = response["error"]
            raise RuntimeError(error.get("message", str(error)))
        return response.get("result")

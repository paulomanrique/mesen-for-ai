from __future__ import annotations

import json
import sys
import time
from typing import Any, Callable

from .session import SessionManager
from .validation import Field, Schema, ValidationError, validate_args


Json = dict[str, Any]


def _json_type(field: Field) -> dict[str, Any]:
    t = field.type
    if t is str:
        return {"type": "string"}
    if t is int:
        return {"type": "integer"}
    if t is bool:
        return {"type": "boolean"}
    if t is list:
        return {"type": "array"}
    if t is dict:
        return {"type": "object"}
    return {"type": "string"}


class McpDaemon:
    def __init__(self) -> None:
        self.sessions = SessionManager()
        self.tools: dict[str, tuple[Schema, Callable[[Json], Any]]] = {
            "session.load_rom": (
                {"rom": Field(str, required=True), "mesen_bin": Field(str), "timeout": Field(int, default=3600)},
                self.session_load_rom,
            ),
            "session.info": ({"session": Field(str, required=True)}, self.session_info),
            "session.reset": ({"session": Field(str, required=True)}, self.session_reset),
            "session.shutdown": ({"session": Field(str, required=True)}, self.session_shutdown),
            "run.step_frames": ({"session": Field(str, required=True), "frames": Field(int, required=True)}, self.run_step_frames),
            "run.status": ({"session": Field(str, required=True)}, self.run_status),
            "cpu.registers": (
                {"session": Field(str, required=True), "cpuType": Field(str), "state": Field(dict)},
                self.cpu_registers,
            ),
            "cpu.read_memory": (
                {
                    "session": Field(str, required=True),
                    "memoryType": Field(str, required=True),
                    "address": Field(int, required=True),
                    "length": Field(int, required=True),
                },
                self.cpu_read_memory,
            ),
            "cpu.write_memory": (
                {
                    "session": Field(str, required=True),
                    "memoryType": Field(str, required=True),
                    "address": Field(int, required=True),
                    "bytes": Field(list, required=True),
                },
                self.cpu_write_memory,
            ),
        }

    def tool_specs(self) -> list[Json]:
        specs = []
        for name, (schema, _) in self.tools.items():
            properties = {key: _json_type(field) for key, field in schema.items()}
            required = [key for key, field in schema.items() if field.required]
            specs.append(
                {
                    "name": name,
                    "description": name,
                    "inputSchema": {
                        "type": "object",
                        "properties": properties,
                        "required": required,
                        "additionalProperties": False,
                    },
                }
            )
        return specs

    def call_tool(self, name: str, arguments: Json | None) -> Any:
        if name not in self.tools:
            raise ValidationError(f"unknown tool '{name}'; accepted tools: {', '.join(sorted(self.tools))}")
        schema, func = self.tools[name]
        args = validate_args(name, schema, arguments)
        return func(args)

    def session_load_rom(self, args: Json) -> Any:
        session = self.sessions.create(args["rom"], args.get("mesen_bin"), args["timeout"])
        info = session.client.request("romInfo")
        return {"session": session.handle, "port": session.port, "romInfo": info}

    def session_info(self, args: Json) -> Any:
        session = self.sessions.get(args["session"])
        return {"session": session.handle, "rom": str(session.rom), "root": str(session.root), "romInfo": session.client.request("romInfo")}

    def session_reset(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("reset")

    def session_shutdown(self, args: Json) -> Any:
        return self.sessions.close(args["session"])

    def run_status(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("status")

    def run_step_frames(self, args: Json) -> Any:
        if args["frames"] <= 0:
            raise ValidationError("run.step_frames: argument 'frames' must be > 0")
        session = self.sessions.get(args["session"])
        start = session.client.request("status")["frame"]
        target = start + args["frames"]
        deadline = time.monotonic() + max(5.0, args["frames"] / 10.0)
        status = {"frame": start}
        while time.monotonic() < deadline:
            status = session.client.request("status")
            if status["frame"] >= target:
                return {"startFrame": start, "targetFrame": target, "status": status}
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for frame {target}; last frame={status.get('frame')}")

    def cpu_registers(self, args: Json) -> Any:
        session = self.sessions.get(args["session"])
        bridge_args: Json = {}
        if "cpuType" in args:
            bridge_args["cpuType"] = args["cpuType"]
        if "state" in args:
            bridge_args["state"] = args["state"]
            return session.client.request("setCpuState", bridge_args)
        return session.client.request("cpuState", bridge_args)

    def cpu_read_memory(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request(
            "readMemory",
            {"memoryType": args["memoryType"], "address": args["address"], "length": args["length"]},
        )

    def cpu_write_memory(self, args: Json) -> Any:
        for value in args["bytes"]:
            if not isinstance(value, int) or value < 0 or value > 255:
                raise ValidationError("cpu.write_memory: argument 'bytes' must contain integers from 0 to 255")
        return self.sessions.get(args["session"]).client.request(
            "writeMemory",
            {"memoryType": args["memoryType"], "address": args["address"], "bytes": args["bytes"]},
        )

    def handle(self, request: Json) -> Json | None:
        request_id = request.get("id")
        method = request.get("method")
        try:
            if method == "initialize":
                result = {
                    "protocolVersion": "2024-11-05",
                    "serverInfo": {"name": "mesen-for-ai", "version": "0.1.0"},
                    "capabilities": {"tools": {}},
                }
            elif method == "tools/list":
                result = {"tools": self.tool_specs()}
            elif method == "tools/call":
                params = request.get("params") or {}
                result = {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(self.call_tool(params.get("name"), params.get("arguments") or {}), sort_keys=True),
                        }
                    ]
                }
            elif method == "notifications/initialized":
                return None
            else:
                raise ValidationError(f"unknown method: {method}")
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except Exception as exc:
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": str(exc)}}


def main() -> int:
    daemon = McpDaemon()
    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            response = daemon.handle(json.loads(line))
            if response is not None:
                sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
                sys.stdout.flush()
    finally:
        daemon.sessions.close_all()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


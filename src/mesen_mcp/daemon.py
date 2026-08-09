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
        self.tool_descriptions = {
            "cdl.start": "CDL collection is continuous in Mesen Lua and cannot be turned on or off; this marks the session's intended coverage window.",
            "cdl.stop": "CDL collection is continuous in Mesen Lua and cannot be turned on or off; this marks the coverage window as no longer active.",
            "cdl.get": "Read decoded Code/Data Logger bytes from a supported ROM region.",
            "cdl.export": "Export decoded Code/Data Logger bytes and contiguous range summaries for a supported ROM region.",
        }
        self.tools: dict[str, tuple[Schema, Callable[[Json], Any]]] = {
            "session.load_rom": (
                {"rom": Field(str, required=True), "mesen_bin": Field(str), "timeout": Field(int, default=3600)},
                self.session_load_rom,
            ),
            "session.info": ({"session": Field(str, required=True)}, self.session_info),
            "session.reset": ({"session": Field(str, required=True)}, self.session_reset),
            "session.shutdown": ({"session": Field(str, required=True)}, self.session_shutdown),
            "run.step_frames": (
                {"session": Field(str, required=True), "frames": Field(int, required=True), "reset": Field(bool, default=False)},
                self.run_step_frames,
            ),
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
            "watch.create": (
                {
                    "session": Field(str, required=True),
                    "memoryType": Field(str, required=True),
                    "address": Field(int, required=True),
                    "length": Field(int, default=1),
                    "access": Field(str, default="write"),
                    "cpuType": Field(str, default="snes"),
                },
                self.watch_create,
            ),
            "watch.list": ({"session": Field(str, required=True)}, self.watch_list),
            "watch.delete": ({"session": Field(str, required=True), "handle": Field(str, required=True)}, self.watch_delete),
            "breakpoint.create": (
                {
                    "session": Field(str, required=True),
                    "memoryType": Field(str, required=True),
                    "address": Field(int, required=True),
                    "length": Field(int, default=1),
                    "access": Field(str, default="exec"),
                    "cpuType": Field(str, default="snes"),
                },
                self.breakpoint_create,
            ),
            "breakpoint.list": ({"session": Field(str, required=True)}, self.breakpoint_list),
            "breakpoint.delete": (
                {"session": Field(str, required=True), "handle": Field(str, required=True)},
                self.breakpoint_delete,
            ),
            "cdl.start": ({"session": Field(str, required=True)}, self.cdl_start),
            "cdl.stop": ({"session": Field(str, required=True)}, self.cdl_stop),
            "cdl.get": (
                {
                    "session": Field(str, required=True),
                    "memoryType": Field(str, default="snesPrgRom"),
                    "offset": Field(int, default=0),
                    "length": Field(int, default=256),
                },
                self.cdl_get,
            ),
            "cdl.export": (
                {"session": Field(str, required=True), "memoryType": Field(str, default="snesPrgRom"), "path": Field(str, required=True)},
                self.cdl_export,
            ),
            "trace.start": ({"session": Field(str, required=True), "cpuType": Field(str, default="snes")}, self.trace_start),
            "trace.stop": ({"session": Field(str, required=True), "handle": Field(str, required=True)}, self.trace_stop),
            "trace.list": ({"session": Field(str, required=True)}, self.trace_list),
        }

    def tool_specs(self) -> list[Json]:
        specs = []
        for name, (schema, _) in self.tools.items():
            properties = {key: _json_type(field) for key, field in schema.items()}
            required = [key for key, field in schema.items() if field.required]
            specs.append(
                {
                    "name": name,
                    "description": self.tool_descriptions.get(name, name),
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
        return {
            "session": session.handle,
            "rom": str(session.rom),
            "loadedRom": str(session.loaded_rom),
            "root": str(session.root),
            "romInfo": session.client.request("romInfo"),
        }

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
        return session.client.request("runFrames", {"frames": args["frames"], "reset": bool(args.get("reset"))})

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

    def watch_create(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request(
            "createWatch",
            _select(args, "memoryType", "address", "length", "access", "cpuType"),
        )

    def watch_list(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("listWatches")

    def watch_delete(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("deleteWatch", {"handle": args["handle"]})

    def breakpoint_create(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request(
            "createBreakpoint",
            _select(args, "memoryType", "address", "length", "access", "cpuType"),
        )

    def breakpoint_list(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("listBreakpoints")

    def breakpoint_delete(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("deleteBreakpoint", {"handle": args["handle"]})

    def cdl_start(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("startCdl")

    def cdl_stop(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("stopCdl")

    def cdl_get(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request(
            "getCdl",
            {"memoryType": args["memoryType"], "offset": args["offset"], "length": args["length"]},
        )

    def cdl_export(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request(
            "exportCdl",
            {"memoryType": args["memoryType"], "path": args["path"]},
        )

    def trace_start(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("startTrace", {"cpuType": args["cpuType"]})

    def trace_stop(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("stopTrace", {"handle": args["handle"]})

    def trace_list(self, args: Json) -> Any:
        return self.sessions.get(args["session"]).client.request("listTraces")

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


def _select(args: Json, *keys: str) -> Json:
    return {key: args[key] for key in keys if key in args}


if __name__ == "__main__":
    raise SystemExit(main())

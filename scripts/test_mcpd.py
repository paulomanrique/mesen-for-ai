#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from typing import Any


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rom", required=True)
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--cdl-short-frames", type=int, default=60)
    parser.add_argument("--cdl-long-frames", type=int, default=900)
    args = parser.parse_args()

    proc = subprocess.Popen(
        [sys.executable, "-m", "mesen_mcp.daemon"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "PYTHONPATH": "src"},
    )
    next_id = 1

    def rpc(method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        nonlocal next_id
        request: dict[str, Any] = {"jsonrpc": "2.0", "id": next_id, "method": method}
        next_id += 1
        if params is not None:
            request["params"] = params
        assert proc.stdin is not None
        assert proc.stdout is not None
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        if not line:
            stderr = proc.stderr.read() if proc.stderr else ""
            raise RuntimeError(f"daemon closed without response: {stderr}")
        response = json.loads(line)
        if "error" in response:
            raise RuntimeError(response["error"])
        return response["result"]

    def tool(name: str, arguments: dict[str, Any]) -> Any:
        result = rpc("tools/call", {"name": name, "arguments": arguments})
        return json.loads(result["content"][0]["text"])

    session = None
    try:
        rpc("initialize")
        loaded = tool("session.load_rom", {"rom": args.rom, "timeout": 120})
        session = loaded["session"]
        print(f"loaded {loaded['romInfo']['name']} {loaded['romInfo']['fileSha1Hash']}")
        info = tool("session.info", {"session": session})
        assert info["rom"] == os.path.realpath(os.path.expanduser(args.rom)), info
        if args.rom.lower().endswith(".zip"):
            assert info["loadedRom"] != info["rom"], info
            assert info["loadedRom"].endswith(".sfc"), info

        breakpoint = tool(
            "breakpoint.create",
            {
                "session": session,
                "memoryType": "snesPrgRom",
                "address": 0,
                "length": 1,
                "access": "exec",
                "cpuType": "snes",
            },
        )
        step = tool("run.step_frames", {"session": session, "frames": args.frames, "reset": True})
        hit = step["breakpoint_hit"]
        assert hit, "expected breakpoint_hit"
        assert hit["breakpoint"] == breakpoint["handle"], (hit, breakpoint)
        assert hit["pcDisplay"] == "$00:8000", hit
        print(f"breakpoint_hit {hit['breakpoint']} pc={hit['pcDisplay']} frame={hit['frame']}")

        listed = tool("breakpoint.list", {"session": session})
        assert listed["breakpoints"][0]["hit"] is True
        assert listed["breakpoints"][0]["lastHit"]["pcDisplay"] == "$00:8000"
        tool("breakpoint.delete", {"session": session, "handle": breakpoint["handle"]})

        watch = tool(
            "watch.create",
            {
                "session": session,
                "memoryType": "snesWorkRam",
                "address": 0,
                "length": 256,
                "access": "write",
                "cpuType": "snes",
            },
        )
        tool("run.step_frames", {"session": session, "frames": args.frames, "reset": True})
        events = tool("watch.list", {"session": session})["events"]
        assert events, "expected watch events"
        assert events[0].get("pcDisplay"), events[0]
        print(f"watch_event {watch['handle']} pc={events[0]['pcDisplay']} address={events[0]['address']}")

        tool("session.shutdown", {"session": session})
        session = None

        short_cdl = measure_cdl(tool, args.rom, args.cdl_short_frames)
        long_cdl = measure_cdl(tool, args.rom, args.cdl_long_frames)
        assert long_cdl["codeBytes"] >= short_cdl["codeBytes"] * 4, (short_cdl, long_cdl)
        assert long_cdl["dataBytes"] >= short_cdl["dataBytes"] * 4, (short_cdl, long_cdl)
        assert long_cdl["summaryRanges"] > short_cdl["summaryRanges"], (short_cdl, long_cdl)
        print(
            f"cdl_compare {args.cdl_short_frames}f code={short_cdl['codeBytes']} data={short_cdl['dataBytes']} "
            f"ranges={short_cdl['summaryRanges']}"
        )
        print(
            f"cdl_compare {args.cdl_long_frames}f code={long_cdl['codeBytes']} data={long_cdl['dataBytes']} "
            f"ranges={long_cdl['summaryRanges']}"
        )
    finally:
        if session:
            try:
                tool("session.shutdown", {"session": session})
            except Exception:
                pass
        if proc.stdin:
            proc.stdin.close()
        proc.wait(timeout=10)
    return 0


def measure_cdl(tool: Any, rom: str, frames: int) -> dict[str, Any]:
    export_path = tempfile.NamedTemporaryFile(prefix=f"mesen-cdl-{frames}-", suffix=".json", delete=False)
    export_path.close()
    session = None
    try:
        loaded = tool("session.load_rom", {"rom": rom, "timeout": 180})
        session = loaded["session"]
        tool("cdl.start", {"session": session})
        tool("run.step_frames", {"session": session, "frames": frames, "reset": True})
        cdl = tool("cdl.export", {"session": session, "memoryType": "snesPrgRom", "path": export_path.name})
        assert cdl["coveredBytes"] == cdl["memorySize"], cdl
        assert cdl["codeBytes"] > 0, cdl
        assert cdl["dataBytes"] > 0, cdl
        return cdl
    finally:
        if session:
            tool("session.shutdown", {"session": session})
        try:
            os.unlink(export_path.name)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())

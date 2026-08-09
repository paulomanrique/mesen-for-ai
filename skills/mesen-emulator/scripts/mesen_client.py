"""Minimal MCP client for mesen-mcpd.

The daemon speaks JSON-RPC 2.0 over newline-delimited JSON on stdio. This wraps the
framing, initialize handshake, and current session handle so callers can just name a
tool and pass keyword arguments.

    from mesen_client import Mesen

    with Mesen() as mesen:
        mesen.load_rom("/abs/path/game.sfc")
        mesen.tool("run.step_frames", frames=60, reset=True)
        print(hex(mesen.tool("cpu.registers", cpuType="snes")["pc"]))

Errors from a tool are raised as MesenToolError carrying the daemon's own message.
"""

import json
import os
import subprocess
import sys
from pathlib import Path


class MesenToolError(RuntimeError):
    """A tool returned an error result. The message is the daemon's own."""


def default_repo():
    env_repo = os.environ.get("MESEN_FOR_AI_REPO")
    if env_repo:
        return os.path.abspath(os.path.expanduser(env_repo))
    for parent in Path(__file__).resolve().parents:
        if (parent / "src" / "mesen_mcp" / "daemon.py").is_file():
            return str(parent)
    cwd = Path.cwd()
    if (cwd / "src" / "mesen_mcp" / "daemon.py").is_file():
        return str(cwd)
    return None


class Mesen:
    def __init__(self, repo=None, timeout=600):
        self.repo = repo or default_repo()
        self.timeout = timeout
        self._next_id = 0
        self._process = None
        self.session = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *_):
        self.close()

    def start(self):
        if self.repo is None:
            raise FileNotFoundError("Set MESEN_FOR_AI_REPO or pass repo= with the mesen-for-ai checkout path.")
        if not os.path.exists(os.path.join(self.repo, "src", "mesen_mcp", "daemon.py")):
            raise FileNotFoundError(
                "{} does not look like mesen-for-ai. Expected src/mesen_mcp/daemon.py".format(self.repo)
            )
        env = os.environ.copy()
        env["PYTHONPATH"] = os.path.join(self.repo, "src")
        self._process = subprocess.Popen(
            [sys.executable, "-m", "mesen_mcp.daemon"],
            cwd=self.repo,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self._request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "mesen_client", "version": "1"},
            },
        )

    def close(self):
        if self._process is None:
            return
        try:
            if self.session is not None:
                try:
                    self.tool("session.shutdown")
                except Exception:
                    pass
            self._process.stdin.close()
            self._process.wait(timeout=30)
        except Exception:
            self._process.kill()
        finally:
            self._process = None
            self.session = None

    def _request(self, method, params=None):
        self._next_id += 1
        request_id = self._next_id
        self._process.stdin.write(
            json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}) + "\n"
        )
        self._process.stdin.flush()
        while True:
            line = self._process.stdout.readline()
            if not line:
                stderr = self._process.stderr.read() if self._process.stderr else ""
                raise RuntimeError("mesen-mcpd closed the connection; stderr:\n{}".format(stderr))
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                raise RuntimeError("unparseable line on stdout: {!r}".format(line[:200]))
            if message.get("id") == request_id:
                return message

    def tools(self):
        """Every tool with its description and parameter schema."""
        return self._request("tools/list")["result"]["tools"]

    def load_rom(self, rom, **kwargs):
        result = self.tool("session.load_rom", rom=rom, **kwargs)
        self.session = result["session"]
        return result

    def tool(self, name, /, **arguments):
        """Call a tool. Returns the parsed result, or raises MesenToolError."""
        if self.session is not None and "session" not in arguments and not name.startswith("session.load_rom"):
            arguments["session"] = self.session
        message = self._request("tools/call", {"name": name, "arguments": arguments})
        if "error" in message:
            raise MesenToolError("{}: {}".format(name, message["error"].get("message", message["error"])))
        result = message["result"]
        text = result["content"][0]["text"] if result.get("content") else ""
        parsed = json.loads(text) if text.strip().startswith(("{", "[")) else text
        if result.get("isError"):
            detail = parsed.get("error", parsed) if isinstance(parsed, dict) else parsed
            raise MesenToolError("{}: {}".format(name, detail))
        if name == "session.shutdown":
            self.session = None
        return parsed

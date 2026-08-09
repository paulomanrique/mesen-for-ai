from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .bridge_client import BridgeClient


ROOT = Path(__file__).resolve().parents[2]


@dataclass
class Session:
    handle: str
    rom: Path
    root: Path
    port: int
    process: subprocess.Popen[bytes]
    client: BridgeClient

    def close(self) -> None:
        if self.process.poll() is not None:
            return
        try:
            self.client.request("shutdown")
        except Exception:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


class SessionManager:
    def __init__(self) -> None:
        self._next = 1
        self._sessions: dict[str, Session] = {}

    def create(self, rom: str, mesen_bin: str | None = None, timeout: int = 3600) -> Session:
        rom_path = Path(rom).expanduser().resolve()
        if not rom_path.is_file():
            raise FileNotFoundError(f"ROM not found: {rom}")
        handle = f"session-{self._next}"
        self._next += 1
        port = _free_port()
        root = Path(tempfile.mkdtemp(prefix=f"mesen-for-ai-{handle}."))
        ready = root / "bridge.ready"

        env = os.environ.copy()
        env["MESEN_BRIDGE_PORT"] = str(port)
        env["MESEN_BRIDGE_READY"] = str(ready)
        env["MESEN_MCP_SESSION_ROOT"] = str(root)
        env["MESEN_TESTRUNNER_TIMEOUT"] = str(timeout)
        if mesen_bin:
            env["MESEN_BIN"] = mesen_bin

        process = subprocess.Popen(
            [str(ROOT / "scripts" / "run_headless.sh"), str(rom_path), str(ROOT / "bridge.lua")],
            cwd=str(ROOT),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        client = BridgeClient("127.0.0.1", port)
        session = Session(handle, rom_path, root, port, process, client)
        try:
            _wait_for_bridge(session, ready)
        except Exception:
            session.close()
            shutil.rmtree(root, ignore_errors=True)
            raise
        self._sessions[handle] = session
        return session

    def get(self, handle: str) -> Session:
        try:
            session = self._sessions[handle]
        except KeyError as exc:
            raise KeyError(f"unknown or closed session handle: {handle}") from exc
        if session.process.poll() is not None:
            del self._sessions[handle]
            raise KeyError(f"unknown or closed session handle: {handle}")
        return session

    def close(self, handle: str) -> dict[str, Any]:
        session = self.get(handle)
        session.close()
        del self._sessions[handle]
        return {"ok": True, "session": handle}

    def close_all(self) -> None:
        for handle in list(self._sessions):
            try:
                self.close(handle)
            except Exception:
                pass


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _wait_for_bridge(session: Session, ready: Path, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if session.process.poll() is not None:
            raise RuntimeError(f"Mesen exited before bridge was ready, code={session.process.returncode}")
        if ready.exists():
            try:
                session.client.request("ping")
                return
            except Exception as exc:
                last_error = exc
        time.sleep(0.05)
    if last_error:
        raise TimeoutError(f"bridge did not respond: {last_error}")
    raise TimeoutError("bridge did not become ready")


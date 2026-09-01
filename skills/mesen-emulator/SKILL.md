---
name: mesen-emulator
description: Run and inspect SNES, NES, PC Engine, and Game Boy Advance software in Mesen headlessly over MCP. Use for loading ROMs, session handles, deterministic frame stepping, CPU registers, memory reads/writes, and basic emulator control when working on SNES/NES/PCE/GBA reverse engineering or conversion. Route plain Mega Drive / Genesis to megadrive-* skills on Exodus; route 32X, Mega CD / Sega CD, and 32X CD to sega32x-* skills on ares-for-ai. Mesen also emulates Master System and Game Boy, but do not use this skill to promise CDL for them; Mesen has no Master System or Game Boy CDL logger.
---

# Mesen MCP - running SNES, NES, PC Engine, and GBA

Mesen-for-ai drives the source-built MesenCE binary headlessly and exposes it over MCP so
an agent can execute a game, read registers, read/write memory, and keep sessions isolated.

The skill works best when it is used from inside a mesen-for-ai checkout. If the skill is
installed elsewhere, set `MESEN_FOR_AI_REPO` to the checkout root or pass `repo=` to
`scripts/mesen_client.py`.

## Routing

Use this skill for:

- SNES / Super Nintendo.
- NES / Famicom.
- PC Engine / TurboGrafx-16 HuCard ROMs.
- Game Boy Advance.

Do not use it for plain Mega Drive / Genesis: use `megadrive-emulator`,
`megadrive-debug`, or `megadrive-disassembly` on Exodus. Do not use it for 32X, Mega CD,
or 32X CD: use `sega32x-emulator` and `sega32x-debug` on ares-for-ai.

Mesen emulates Master System and Game Boy, but the Code/Data Logger is not registered for
those systems. Never route "separate code from data on SMS/GB" here as if CDL exists.

## Client

Use `scripts/mesen_client.py` from this skill directory instead of re-deriving stdio
framing.

```python
from mesen_client import Mesen
import os

rom = os.environ["MESEN_TEST_ROM"]

with Mesen() as mesen:
    loaded = mesen.load_rom(rom, timeout=120)
    stepped = mesen.tool("run.step_frames", frames=10, reset=True)
    regs = mesen.tool("cpu.registers", cpuType="snes")
    mem = mesen.tool("cpu.read_memory", memoryType="snesWorkRam", address=0, length=4)
    print("loaded", loaded["romInfo"]["name"])
    print("step", stepped)
    print("pc", hex(regs["pc"]), "a", regs["a"])
    print("ram0", mem["bytes"])
```

Executed output with a private SNES test ROM:

```text
loaded Final Fight 2 (USA).sfc
step {'startFrame': 0, 'status': {'cpuCycleCount': 520015, 'frame': 10, 'masterClock': 3523196}, 'targetFrame': 10}
pc 0xa4c1 a 65456
ram0 [0, 0, 0, 0]
```

## Session model

`session.load_rom` returns a session handle such as `session-1`. Keep it and pass it to
tools when not using `mesen_client.py`; the client injects it automatically after
`load_rom`.

Handles are monotonic and not reused. A stale session/watch/breakpoint/trace handle fails
instead of resolving to a different object.

Each session gets its own temporary root, Mesen home, work directory, and TCP port. This
is required because Mesen settings and debugger state are on disk. Do not make agents
share one session root.

The ROM argument is named `rom`. This differs from Exodus and ares, where the comparable
argument is `path`; check the schema rather than assuming consistency across tools.

No-Intro ZIPs are accepted directly. When `rom` points to a `.zip`, mesen-for-ai extracts
the single supported ROM member into the session temporary directory, launches Mesen from
that extracted file, and removes it on `session.shutdown`. Do not extract library ZIPs by
hand unless the archive is ambiguous.

## Basic tools

| Group | Tools |
|---|---|
| `session.*` | `load_rom`, `info`, `reset`, `shutdown` |
| `run.*` | `step_frames`, `status` |
| `cpu.*` | `registers`, `read_memory`, `write_memory` |
| `watch.*` | `create`, `list`, `delete` |
| `breakpoint.*` | `create`, `list`, `delete` |
| `trace.*` | `start`, `stop`, `list` |
| `cdl.*` | `start`, `stop`, `get`, `export` |

Every tool rejects undeclared arguments. If you typo `frames` as `framse`, the error names
the bad argument, suggests the nearest accepted one, and lists accepted arguments.

Use `run.step_frames(..., reset=True)` for deterministic evidence runs. That makes reset
plus N frames one bridge operation so no variable frames run between separate calls.

## Memory and CPU names

Common memory types:

- SNES: `snesMemory`, `snesWorkRam`, `snesPrgRom`
- NES: `nesMemory`, `nesPpuMemory`, `nesInternalRam`, `nesPrgRom`,
  `nesChrRom`, `nesNametableRam`, `nesPaletteRam`, `nesSpriteRam`,
  `nesSecondarySpriteRam`
- PC Engine: `pceMemory`, `pceWorkRam`, `pcePrgRom`, `pceCdromRam`,
  `pceCardRam`, `pceArcadeCardRam`
- GBA: `gbaMemory`, `gbaIntWorkRam`, `gbaExtWorkRam`, `gbaPrgRom`

Common CPU types: `snes`, `nes`, `pce`, `gba`. Use `cpu.registers` after loading to see
the state shape; it is Mesen's own serialized CPU state.

## Headless traps

The daemon already handles these. Preserve them if you write a lower-level wrapper:

- Set `MESEN_BIN` to the Mesen executable to use. If unset, the wrapper uses its local
  development default.
- Run via `xvfb-run -a Mesen --testrunner <rom> <script.lua>`.
- Export `DOTNET_ROLL_FORWARD=Major` if your Mesen build targets an older .NET runtime
  than the one installed on the host.
- Use an isolated home with a prebaked `settings.json`; otherwise Mesen opens the setup
  wizard instead of the testrunner.
- Set `AllowIoOsAccess` and `AllowNetworkAccess` for Lua. `emu.log` does not reach
  testrunner stdout; scripts must write files or use the socket bridge.
- Set `RamPowerOnState: 1` (AllZeros). `0` is Random and breaks deterministic evidence.
- Input must be set from the `inputPolled` callback, not once outside it.

# Instructions for LLM Agents

Read this file before driving `mesen-for-ai`.

## What This Project Is

`mesen-for-ai` is an MCP server for controlling Mesen headlessly. It exists so
an agent can ask an original game what happened instead of inferring behavior
from screenshots.

The emulator is not vendored. The caller must provide a Mesen/MesenCE binary and
set `MESEN_BIN` if the local default is not correct.

## Architecture

There are two protocols:

- MCP JSON-RPC 2.0 over stdio between the agent and `mesen_mcp.daemon`.
- One JSON request per line over TCP between the daemon and `bridge.lua`.

`bridge.lua` runs inside Mesen. It opens the TCP socket, calls Mesen's Lua API,
and sends structured responses back to the daemon. Do not mix Mesen stdout with
MCP stdio.

## Session Model

Use `session.load_rom` first. It returns a session handle such as `session-1`.
Pass that handle to every other tool unless a helper client injects it for you.

Each session gets:

- a private temporary root,
- an isolated Mesen home,
- a private working directory,
- a private TCP port,
- one Mesen process.

Sessions are isolated so multiple agents can run concurrently. Do not share
session roots, Mesen homes, work directories, ports, watches, breakpoints, or
trace handles across sessions.

Handles are monotonic and not reused. A stale handle must fail instead of
resolving to a new object.

ZIP ROMs are accepted. If `session.load_rom` receives a ZIP, the daemon extracts
the single supported ROM member into the session temporary directory and deletes
it when the session shuts down. ZIPs with no supported ROM or multiple supported
ROMs fail rather than guessing.

## MCP Tools

Session:

- `session.load_rom(rom, mesen_bin?, timeout?)`
- `session.info(session)`
- `session.reset(session)`
- `session.shutdown(session)`

Run control:

- `run.step_frames(session, frames, reset?)`
- `run.status(session)`

CPU and memory:

- `cpu.registers(session, cpuType?, state?)`
- `cpu.read_memory(session, memoryType, address, length)`
- `cpu.write_memory(session, memoryType, address, bytes)`

Watches:

- `watch.create(session, memoryType, address, length?, access?, cpuType?)`
- `watch.list(session)`
- `watch.delete(session, handle)`

Breakpoints:

- `breakpoint.create(session, memoryType, address, length?, access?, cpuType?)`
- `breakpoint.list(session)`
- `breakpoint.delete(session, handle)`

Code/Data Logger:

- `cdl.start(session)`
- `cdl.stop(session)`
- `cdl.get(session, memoryType?, offset?, length?)`
- `cdl.export(session, memoryType?, path)`

Trace:

- `trace.start(session, cpuType?)`
- `trace.stop(session, handle)`
- `trace.list(session)`

Every tool rejects undeclared arguments centrally. If an argument name is wrong,
fix the caller. Do not ignore the error or assume a default was applied.

## Common Memory And CPU Names

Common memory types:

- SNES: `snesMemory`, `snesWorkRam`, `snesPrgRom`
- NES: `nesMemory`, `nesInternalRam`, `nesPrgRom`, `nesChrRom`
- PC Engine: `pceMemory`, `pceWorkRam`, `pcePrgRom`
- GBA: `gbaMemory`, `gbaIntWorkRam`, `gbaExtWorkRam`, `gbaPrgRom`

Common CPU types:

- `snes`
- `nes`
- `pce`
- `gba`

Use `cpu.registers` after loading to inspect the exact state shape returned by
Mesen for the current system.

## Determinism Rules

Use `run.step_frames(..., reset=true)` for evidence runs. It combines reset and
frame stepping into one bridge operation.

The headless runner writes settings that make RAM deterministic:

- `RamPowerOnState: 1`
- random power-on state disabled where Mesen exposes a setting
- NES mapper and CPU/PPU alignment randomization disabled

If you bypass the daemon or runner, preserve those settings.

## Breakpoints

Breakpoint notification is request/response. If a breakpoint hits during
`run.step_frames`, the result contains `breakpoint_hit`.

The session does not remain halted after a hit. This is deliberate: it keeps the
MCP request model from deadlocking. Inspect `breakpoint_hit`, `breakpoint.list`,
registers, memory, watches, or traces after the step returns.

Breakpoint and watch events include PC fields such as `pc`, `pcBank` when
available, and `pcDisplay`.

## Watches

Use watches to answer "who wrote this address?" Watch events include the watched
address, value, frame, master clock, CPU cycle count, CPU type, and PC.

The event buffer is bounded. Narrow the watched range if every hit matters.

## Code/Data Logger

CDL collection is continuous inside Mesen. The Lua API exposes `getCdlData`; it
does not expose start/stop control. `cdl.start` and `cdl.stop` are session
window markers only.

`coveredBytes == memorySize` means the exported map covers every byte in the ROM
region. It does not mean the run executed or read the whole ROM.

Use `codeBytes`, `dataBytes`, and `summaryRanges` to judge what the game touched
during the driven run. Those counts should grow when a deterministic run goes
longer or reaches more gameplay.

CDL is exposed for:

- SNES PRG ROM
- NES PRG ROM
- NES CHR ROM
- PC Engine PRG ROM
- GBA PRG ROM

Do not promise CDL for Master System, Game Boy, or WonderSwan.

NES CHR bit `0x01` means `NesChrDrawn`, not CPU code. The bridge reports it as
`drawn` / `drawnBytes`; never describe NES CHR `0x01` coverage as executed code.

## Common Errors

- Wrong tool argument names are rejected. Use the schema returned by
  `tools/list`.
- `path` is not the ROM argument. The tool argument is `rom`.
- `emu.log` output from Lua is not MCP output. Use files or the socket bridge.
- Mesen stdout is not daemon stdout. Do not parse it as MCP.
- Input must be set from Mesen's `inputPolled` callback, not once outside it.
- `cdl.start` and `cdl.stop` do not control Mesen's underlying logger.
- A breakpoint hit is not an asynchronous notification. Read it from the
  `run.step_frames` response.

## Privacy

Never commit, upload, or redistribute ROM, BIOS, firmware, disc-image, or other
copyrighted game material. Test commands should accept user-supplied paths or
environment variables instead of documenting private library paths.

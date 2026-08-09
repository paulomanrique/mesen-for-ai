# mesen-for-ai

`mesen-for-ai` is an MCP server for driving Mesen headless from AI agents doing
reverse engineering and game conversion work.

The emulator is not vendored. The tested local binary is:

```sh
~/tools/mesen-src/bin/linux-x64/Release/Mesen
```

The stock Mesen 2.1.1 AOT release is not used here.

## Phase 0: headless runner

Run a Lua testrunner script against a ROM with an isolated Mesen home:

```sh
./scripts/run_headless.sh <rom> <script.lua>
```

The runner writes a fresh `settings.json` under a per-run home with:

- Lua IO/OS access enabled.
- deterministic RAM power-on state for SNES, NES, PC Engine, GBA, and Game Boy.
- NES mapper and CPU/PPU alignment randomization disabled.

On this Ubuntu 26.04 machine, the source-built Mesen targets .NET 8 while only
.NET 10 is installed, so the wrapper exports `DOTNET_ROLL_FORWARD=Major` unless
the caller already set it.

For a deterministic RAM smoke test:

```sh
MESEN_MCP_FRAMES=60 MESEN_MCP_DUMP_PATH=/tmp/ram-a.bin \
  ./scripts/run_headless.sh /path/to/game.sfc scripts/dump_ram.lua
MESEN_MCP_FRAMES=60 MESEN_MCP_DUMP_PATH=/tmp/ram-b.bin \
  ./scripts/run_headless.sh /path/to/game.sfc scripts/dump_ram.lua
cmp /tmp/ram-a.bin /tmp/ram-b.bin
```

## MCP daemon

Run the daemon over JSON-RPC 2.0 stdio:

```sh
PYTHONPATH=src python3 -m mesen_mcp.daemon
```

Implemented tools:

- `session.load_rom`, `session.info`, `session.reset`, `session.shutdown`
- `run.step_frames`, `run.status`
- `cpu.registers`, `cpu.read_memory`, `cpu.write_memory`
- `watch.create`, `watch.list`, `watch.delete`
- `breakpoint.create`, `breakpoint.list`, `breakpoint.delete`
- `cdl.start`, `cdl.stop`, `cdl.get`, `cdl.export`
- `trace.start`, `trace.stop`, `trace.list`

For deterministic evidence runs, call `run.step_frames` with `"reset": true`.
That makes reset plus N frames one bridge operation, avoiding variable frames
between separate MCP calls. `cdl.export` returns `coveredBytes` and
`memorySize`; they must match for a complete per-byte ROM map.

Supported CDL targets are the Mesen CDL-backed ROM regions: SNES PRG ROM, NES
PRG/CHR ROM, PC Engine PRG ROM, and GBA PRG ROM. Master System, Game Boy, and
WonderSwan CDL are not exposed because Mesen does not register those loggers.

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


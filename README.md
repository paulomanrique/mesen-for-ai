# mesen-for-ai

`mesen-for-ai` is an MCP server that lets AI agents drive Mesen headlessly for
console reverse engineering and game conversion work.

It does not port or vendor Mesen. It launches an existing Mesen/MesenCE binary,
runs `bridge.lua` inside the emulator, and exposes the debugger-facing Lua API
over MCP JSON-RPC on stdio.

If you are an LLM, read this first: [AGENTS.md](AGENTS.md).

## Supported Systems

Use this project for Mesen systems where the required debugger surface is
available:

- SNES / Super Nintendo
- NES / Famicom
- PC Engine / TurboGrafx-16, including CD-ROM² cue sheets
- Game Boy Advance

The Code/Data Logger is available for SNES PRG ROM, NES PRG/CHR ROM, PC Engine
PRG ROM, and GBA PRG ROM. Mesen emulates more systems, but this project does
not promise CDL coverage for Master System, Game Boy, or WonderSwan because
Mesen does not register those CDL loggers.

## Requirements

- Python 3.11 or newer.
- `xvfb-run` on Linux for headless Mesen execution.
- A Mesen or MesenCE build with `--testrunner` support and Lua socket support.
- Set `MESEN_BIN` to the Mesen executable you want to use.

Example:

```sh
export MESEN_BIN=/path/to/Mesen
```

The local wrapper has a development default for `MESEN_BIN`, but public use
should set the variable explicitly.

PC Engine CD sessions also require a user-supplied System Card 3 image. The
runner copies it into the isolated session home and Mesen verifies its hash:

```sh
export MESEN_PCECD_FIRMWARE=/path/to/syscard3.pce
```

## Run the MCP Daemon

From a checkout:

```sh
PYTHONPATH=src python3 -m mesen_mcp.daemon
```

The daemon speaks MCP-style JSON-RPC 2.0 over its own stdio. Mesen stdout and
stderr are not part of the MCP protocol; Mesen talks to the daemon through a
per-session TCP socket opened by `bridge.lua`.

## Headless Runner

You can run a Lua testrunner script directly:

```sh
MESEN_BIN=/path/to/Mesen ./scripts/run_headless.sh <rom> <script.lua>
```

The runner creates an isolated Mesen home and writes deterministic settings:

- Lua IO/OS access enabled.
- Lua network access enabled for the socket bridge.
- deterministic RAM power-on state for SNES, NES, PC Engine, GBA, and Game Boy.
- a standard two-button controller on PC Engine port 1.
- NES mapper and CPU/PPU alignment randomization disabled.

For a deterministic RAM smoke test:

```sh
MESEN_BIN=/path/to/Mesen MESEN_MCP_FRAMES=60 MESEN_MCP_DUMP_PATH=/tmp/ram-a.bin \
  ./scripts/run_headless.sh /path/to/game.sfc scripts/dump_ram.lua
MESEN_BIN=/path/to/Mesen MESEN_MCP_FRAMES=60 MESEN_MCP_DUMP_PATH=/tmp/ram-b.bin \
  ./scripts/run_headless.sh /path/to/game.sfc scripts/dump_ram.lua
cmp /tmp/ram-a.bin /tmp/ram-b.bin
```

## MCP Tools

Implemented tools:

- `session.load_rom`, `session.info`, `session.reset`, `session.shutdown`
- `run.step_frames`, `run.status`
- `input.set`, `input.get`
- `video.export_frame`
- `cpu.registers`, `cpu.read_memory`, `cpu.write_memory`
- `console.state` for the held machine's complete serialized scalar state,
  including NES PPU `VideoRamAddr`, `TmpVideoRamAddr`, `ScrollX`, and
  `WriteToggle`
- `watch.create`, `watch.list`, `watch.delete`
- `breakpoint.create`, `breakpoint.list`, `breakpoint.delete`
- `cdl.start`, `cdl.stop`, `cdl.get`, `cdl.export`
- `trace.start`, `trace.stop`, `trace.list`

`session.load_rom` accepts normal ROM files and ZIP archives. For ZIPs, the
daemon extracts the single supported ROM member into the session temporary
directory, launches Mesen against that extracted file, and removes it on
`session.shutdown`.

Mesen accepts PC Engine CD media as a `.cue` plus its referenced track files.
For those sessions, `pceCdromRam` exposes the CD unit RAM and `pceCardRam`
exposes the 192 KiB Super CD-ROM² RAM supplied by System Card 3, in addition to
the usual `pceMemory`, `pceWorkRam`, and `pcePrgRom` aliases.
`pceArcadeCardRam` separately exposes the 2 MiB Arcade Card expansion RAM when
that hardware is active. Disc images and System Card firmware remain private
inputs and are never copied into this repository.

Start deterministic PC Engine CD evidence from a new session and advance with
`reset=false`. In the source-built MesenCE version validated here, calling
`emu.reset()` from the bridge after a cue sheet has started closes the testrunner
instead of returning a frame response. A fresh isolated session supplies the
cold-boot boundary without that reset call.

### PC Engine CD READ(6) compatibility patch

MesenCE commit `20ba206cef5ba207c21203176d02cb9f43dda9fb` treats a zero
READ(6) transfer-length byte as an empty request. SCSI READ(6) defines that byte
as 256 sectors, and commercial PC Engine CD software can depend on it. Apply
`patches/mesence-pce-read6-zero-length.patch` to that revision before building:

```sh
git apply /path/to/mesen-for-ai/patches/mesence-pce-read6-zero-length.patch
make core -j4
make ui
```

The patch widens the saved sector counter to 16 bits and maps command byte zero
to `0x100`. It was validated with the Japanese PC Engine CD release of World
Heroes 2: command `08 00 22 78 00 00` transfers sectors 8824 through 9079 and
allows the original post-versus loader to reach CPU `$C15B`. No game bytes or
firmware are included here.

For deterministic evidence runs, call `run.step_frames` with `reset=true`. That
makes reset plus N frames one bridge operation and avoids variable frames
between separate MCP calls. A newly loaded ROM is held before its first frame
starts until that explicit run request, so watches and CDL can be armed without
recording an uncontrolled pre-reset interval.

`input.set` latches named controller buttons and applies them from Mesen's
`inputPolled` callback, which is the only safe point for scripted input. Change
the latch while held at a frame boundary, then advance the intended number of
frames. `video.export_frame` writes the held rendered frame as binary P6 RGB.

## Code/Data Logger Semantics

Mesen's Lua API exposes `getCdlData`; it does not expose a logger on/off switch.
`cdl.start` and `cdl.stop` are MCP-side window markers only. Collection is
continuous inside Mesen.

The Lua `getCdlData` table is zero-indexed even though ordinary Lua arrays are
usually one-indexed. The bridge preserves physical ROM offset zero as JSON
element zero; do not add an index adjustment in callers.

`cdl.export` returns `coveredBytes` and `memorySize`. Equality means the exported
map has one decoded record for every byte in that ROM region. It does not mean
the run executed or read the whole ROM.

The evidence that CDL is live is growth in `codeBytes`, `dataBytes`, and
`summaryRanges` when a deterministic run is driven for longer or through more
gameplay.

NES CHR is the platform-specific exception to the generic flag names. Mesen's
source defines bit `0x01` as `NesChrDrawn` for CHR ROM, not CPU `Code`.
Inline/exported CHR records therefore expose `drawn`, summaries classify those
ranges as `drawn`, and export counts report `drawnBytes`; `codeBytes` and
`dataBytes` remain zero for CHR.

## Skills

The repo ships Codex/Codex-compatible skills in [skills/](skills/):

- `skills/mesen-emulator` - load ROMs, manage session handles, step frames,
  read/write memory, and inspect CPU registers.
- `skills/mesen-debug` - answer debugging questions with watches, breakpoints,
  traces, registers, and memory inspection.
- `skills/mesen-codedata` - export and interpret Mesen Code/Data Logger maps.

Install them by symlinking or copying the skill directories into your agent's
skill directory. If the skills are installed outside this checkout, set
`MESEN_FOR_AI_REPO` to the checkout root so `scripts/mesen_client.py` can find
the daemon.

## Validation

Unit and static smoke tests:

```sh
python3 -m py_compile src/mesen_mcp/*.py scripts/test_mcpd.py
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Real emulator validation requires a private test ROM supplied by the user:

```sh
MESEN_BIN=/path/to/Mesen PYTHONPATH=src scripts/test_mcpd.py --rom /path/to/test-rom.zip --frames 60
```

Do not commit, upload, or redistribute ROM, BIOS, firmware, disc-image, or
other copyrighted game material.

## License

`mesen-for-ai` is licensed under GPL-3.0-only. See [LICENSE](LICENSE).

Mesen itself is an upstream GPL-3.0 emulator and is not vendored in this
repository. The wrapper code in this repository is original, but `bridge.lua`
runs inside the Mesen process and calls Mesen's Lua API directly. The
conservative licensing position is therefore to publish the wrapper under
GPL-3.0-only as well.

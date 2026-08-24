---
name: mesen-codedata
description: 'Use Mesen Code/Data Logger coverage for SNES, NES, PC Engine, and Game Boy Advance ROM reverse engineering over MCP: record executed code bytes, data reads, jump targets, subroutine entry points, export per-byte maps and contiguous summaries, and prove ROM-map coverage. Route plain Mega Drive / Genesis code/data work to megadrive-disassembly on Exodus; route 32X, Mega CD / Sega CD, and 32X CD to sega32x-disassembly on ares-for-ai. Mesen has no CDL for Master System or Game Boy despite emulating them.'
---

# Mesen Code/Data Logger

This is the capability that justifies Mesen-for-ai for SNES, NES, PC Engine, and GBA
conversion work: ask the original game which ROM bytes executed as code and which were
read as data instead of guessing from screenshots.

Read `mesen-emulator` first for loading, sessions, and the `mesen_client.py` helper.

## What CDL means here

Mesen's Lua API exposes `getCdlData`. Each ROM byte has these flags:

- `Code` = `0x01`
- `Data` = `0x02`
- `JumpTarget` = `0x04`
- `SubEntryPoint` = `0x08`

Mesen-for-ai decodes those into booleans and exports:

- a per-byte `bytes` array,
- a contiguous `summary` with `start`, `end`, `classification`, `jumpTarget`, and
  `subEntryPoint`,
- counts such as `codeBytes`, `dataBytes`, `summaryRanges`, `coveredBytes`, and
  `memorySize`.

`coveredBytes` must equal `memorySize`; otherwise the map does not cover the full ROM
region.

Do not confuse map completeness with observed execution coverage. `coveredBytes ==
memorySize` means Mesen returned one decoded CDL record for every byte in that ROM region.
It does not mean the run executed or read the whole ROM. Use `codeBytes`, `dataBytes`, and
`summaryRanges` to judge what the game actually touched during the driven window. On a
healthy run those numbers should grow when you run longer or drive more gameplay.

## Continuous collection

Important: Mesen's CDL collection is continuous in Lua and cannot be turned on or off
through the exposed API. `cdl.start` and `cdl.stop` only mark the intended coverage window
in the MCP session. They do not reset or disable the underlying logger.

For deterministic evidence runs, call `run.step_frames` with `reset=True` immediately
before the window you want to measure.

## Supported ROM regions

- SNES: `snesPrgRom`
- NES: `nesPrgRom`, `nesChrRom`
- PC Engine: `pcePrgRom`
- GBA: `gbaPrgRom`

Do not promise CDL for Master System, Game Boy, or WonderSwan. Mesen does not register
those CDL loggers.

NES CHR is the platform-specific exception to the generic flag names: bit `0x01`
means `NesChrDrawn` in Mesen's source, not CPU code. CHR records expose `drawn`,
summaries classify those ranges as `drawn`, and exports count `drawnBytes` while
keeping `codeBytes` and `dataBytes` at zero.

## Export workflow

Executed example:

```python
from mesen_client import Mesen
import os
import tempfile

rom = os.environ["MESEN_TEST_ROM"]
out = tempfile.mktemp(prefix="mesen-cdl-", suffix=".json")

with Mesen() as mesen:
    mesen.load_rom(rom, timeout=180)
    mesen.tool("cdl.start")
    mesen.tool("run.step_frames", frames=60, reset=True)
    cdl = mesen.tool("cdl.export", memoryType="snesPrgRom", path=out)
    print("cdl", cdl["memoryType"], "code", cdl["codeBytes"],
          "data", cdl["dataBytes"], "ranges", cdl["summaryRanges"])
    print("coverage", cdl["coveredBytes"], cdl["memorySize"],
          cdl["coveredBytes"] == cdl["memorySize"])
    print("first_range", cdl["sampleRanges"][0])
```

Observed output with a private SNES test ROM:

```text
cdl snesPrgRom code 1032 data 16448 ranges 124
coverage 1310720 1310720 True
first_range {'classification': 'code', 'end': 2, 'jumpTarget': False, 'start': 0, 'subEntryPoint': False}
```

The same ROM run for 900 frames produced:

```text
cdl900 snesPrgRom code 4690 data 72336 ranges 596
coverage 1310720 1310720 True
```

The growth from 60 to 900 frames is expected: more init and DMA paths execute or read
tables as the game runs. Treat this as an execution coverage map, not a whole-ROM proof
unless you have driven the game through the paths you care about.

## Reading inline data

Use `cdl.get` for small windows:

```python
window = mesen.tool("cdl.get", memoryType="snesPrgRom", offset=0, length=16)
print(window["bytes"][0])
```

Use `cdl.export` for real work. A SNES ROM export can be around 100 MB; write it to a
file and inspect summaries rather than pulling every byte through conversation.

## How to use the result

- Code ranges answer "what actually executed".
- Data ranges answer "what ROM bytes the game read as tables, graphics source, vectors,
  DMA source, or constants".
- `jumpTarget` and `subEntryPoint` are the first places to label when building a
  disassembly.
- Diff two exports after different input paths to see what new code/data became covered.

Do not infer uncovered bytes are unused. They are only unobserved in that run.

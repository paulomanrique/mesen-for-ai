---
name: mesen-debug
description: 'Debug SNES, NES, PC Engine, and Game Boy Advance execution in Mesen over MCP: watch writes to answer "who wrote this address", breakpoint hits returned by run.step_frames, trace cycle windows, CPU registers, and memory inspection. Use for SNES/NES/PCE/GBA crashes, hangs, corrupt RAM, wrong routine behavior, or "what code ran when X happened". Route plain Mega Drive / Genesis debugging to megadrive-debug on Exodus; route 32X, Mega CD / Sega CD, and 32X CD debugging to sega32x-debug on ares-for-ai. Mesen has no Master System or Game Boy CDL logger; do not promise SMS/GB code-data coverage.'
---

# Debugging on Mesen MCP

Read `mesen-emulator` first. This skill assumes the session model and
`mesen_client.py` helper from that skill.

## Where to start, by symptom

| Symptom | Reach for |
|---|---|
| Need to know who wrote a RAM address | `watch.create` with `access="write"` |
| Need to stop when known code executes | `breakpoint.create`, then inspect `run.step_frames()["breakpoint_hit"]` |
| Need to know where the CPU is | `cpu.registers` |
| Need a coarse cycle window | `trace.start`, run frames, `trace.stop` |
| Need to inspect or patch RAM | `cpu.read_memory` / `cpu.write_memory` |
| Need to separate ROM code from data | Use `mesen-codedata` |

## Watch: who wrote this address?

Mesen memory callbacks fire inline during emulation. Watch events record the watched
address, value, frame, master clock, CPU cycle count, and the CPU PC at the write. For
SNES the PC display includes bank, e.g. `$80:A4DE`.

Executed example:

```python
from mesen_client import Mesen
import os

rom = os.environ["MESEN_TEST_ROM"]

with Mesen() as mesen:
    mesen.load_rom(rom, timeout=120)
    watch = mesen.tool("watch.create", memoryType="snesWorkRam",
                       address=0, length=256, access="write", cpuType="snes")
    mesen.tool("run.step_frames", frames=60, reset=True)
    events = mesen.tool("watch.list")["events"]
    print("watch", watch["handle"], "events", len(events),
          "first_pc", events[0]["pcDisplay"], "first_addr", events[0]["address"])
```

Observed output:

```text
watch watch-1 events 2048 first_pc $80:A4DE first_addr 10
```

The event buffer is capped to the most recent 2048 events to keep MCP responses bounded.
Narrow the watched range when you need every hit.

## Breakpoints

Breakpoint notification is request/response. A hit is returned in the result of
`run.step_frames` as `breakpoint_hit`; there is no async push notification. This is the
same MCP-friendly pattern used by ares-for-ai.

Executed example:

```python
from mesen_client import Mesen
import os

rom = os.environ["MESEN_TEST_ROM"]

with Mesen() as mesen:
    mesen.load_rom(rom, timeout=120)
    bp = mesen.tool("breakpoint.create", memoryType="snesPrgRom",
                    address=0, length=1, access="exec", cpuType="snes")
    stepped = mesen.tool("run.step_frames", frames=60, reset=True)
    listed = mesen.tool("breakpoint.list")["breakpoints"]
    mesen.tool("breakpoint.delete", handle=bp["handle"])
    print("breakpoint", bp["handle"],
          "hit_pc", stepped["breakpoint_hit"]["pcDisplay"],
          "listed_hit", listed[0]["hit"])
```

Observed output from the same run shape:

```text
breakpoint breakpoint-1 hit_pc $00:8000 listed_hit True
```

Mesen-for-ai deliberately does not leave the session frozen after a breakpoint hit. It
records `lastHit` and returns early from `run.step_frames`, then the session keeps
accepting MCP commands.

## Trace windows

`trace.start` and `trace.stop` measure elapsed frames, master clocks, and CPU cycles. It
is a timing window, not a full instruction log.

Executed output in the same debug example:

```text
trace trace-3 frames 7 cycles 369584
```

For full code/data coverage, use `mesen-codedata`; for a few current registers, use
`cpu.registers`.

## Limits

- Breakpoints and watches are Mesen Lua memory callbacks, not a full symbolic debugger.
- No async event stream exists; poll `watch.list`/`breakpoint.list` after running.
- Watch events identify PC and cycle, but not a decoded instruction mnemonic.
- `run.step_frames` returns early on breakpoint hits. If there is no hit, Mesen may omit
  the `breakpoint_hit` key instead of returning JSON null.

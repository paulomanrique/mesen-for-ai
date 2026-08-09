local frames = tonumber(os.getenv("MESEN_MCP_FRAMES") or "60")
local out_path = os.getenv("MESEN_MCP_DUMP_PATH")

if out_path == nil or out_path == "" then
  error("MESEN_MCP_DUMP_PATH is required")
end

local function choose_ram_type()
  local candidates = {
    emu.memType.snesWorkRamDebug or emu.memType.snesWorkRam,
    emu.memType.nesInternalRamDebug or emu.memType.nesInternalRam,
    emu.memType.pceWorkRamDebug or emu.memType.pceWorkRam,
    emu.memType.gbaIntWorkRamDebug or emu.memType.gbaIntWorkRam,
    emu.memType.gbWorkRamDebug or emu.memType.gbWorkRam,
  }

  for _, mem_type in ipairs(candidates) do
    local ok, size = pcall(emu.getMemorySize, mem_type)
    if ok and size and size > 0 then
      return mem_type, size
    end
  end

  error("no supported RAM memory type found")
end

local function dump_ram()
  local mem_type, size = choose_ram_type()
  local file = assert(io.open(out_path, "wb"))
  for address = 0, size - 1 do
    file:write(string.char(emu.read(address, mem_type, false)))
  end
  file:close()
end

local frame_count = 0

emu.addEventCallback(function()
  frame_count = frame_count + 1
  if frame_count >= frames then
    dump_ram()
    emu.stop(0)
  end
end, emu.eventType.endFrame)

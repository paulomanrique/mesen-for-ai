local socket = require("socket.core")

local host = os.getenv("MESEN_BRIDGE_HOST") or "127.0.0.1"
local port = tonumber(os.getenv("MESEN_BRIDGE_PORT") or "0")
local ready_path = os.getenv("MESEN_BRIDGE_READY")

if port == 0 then
  error("MESEN_BRIDGE_PORT is required")
end

local json = {}

local function parse_error(text, pos, message)
  error(message .. " at byte " .. tostring(pos) .. " in " .. text)
end

local function skip_ws(text, pos)
  while true do
    local c = text:sub(pos, pos)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      pos = pos + 1
    else
      return pos
    end
  end
end

local parse_value

local escapes = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

local function parse_string(text, pos)
  if text:sub(pos, pos) ~= '"' then
    parse_error(text, pos, "expected string")
  end
  pos = pos + 1
  local out = {}
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == '"' then
      return table.concat(out), pos + 1
    end
    if c == "\\" then
      local e = text:sub(pos + 1, pos + 1)
      if e == "u" then
        local hex = text:sub(pos + 2, pos + 5)
        local code = tonumber(hex, 16)
        if code == nil then
          parse_error(text, pos, "invalid unicode escape")
        end
        if code < 128 then
          out[#out + 1] = string.char(code)
        else
          out[#out + 1] = "?"
        end
        pos = pos + 6
      elseif escapes[e] ~= nil then
        out[#out + 1] = escapes[e]
        pos = pos + 2
      else
        parse_error(text, pos, "invalid escape")
      end
    else
      out[#out + 1] = c
      pos = pos + 1
    end
  end
  parse_error(text, pos, "unterminated string")
end

local function parse_number(text, pos)
  local start = pos
  local c = text:sub(pos, pos)
  if c == "-" then
    pos = pos + 1
  end
  while text:sub(pos, pos):match("%d") do
    pos = pos + 1
  end
  if text:sub(pos, pos) == "." then
    pos = pos + 1
    while text:sub(pos, pos):match("%d") do
      pos = pos + 1
    end
  end
  c = text:sub(pos, pos)
  if c == "e" or c == "E" then
    pos = pos + 1
    c = text:sub(pos, pos)
    if c == "+" or c == "-" then
      pos = pos + 1
    end
    while text:sub(pos, pos):match("%d") do
      pos = pos + 1
    end
  end
  local value = tonumber(text:sub(start, pos - 1))
  if value == nil then
    parse_error(text, start, "invalid number")
  end
  return value, pos
end

local function parse_array(text, pos)
  pos = skip_ws(text, pos + 1)
  local out = {}
  if text:sub(pos, pos) == "]" then
    return out, pos + 1
  end
  while true do
    local value
    value, pos = parse_value(text, pos)
    out[#out + 1] = value
    pos = skip_ws(text, pos)
    local c = text:sub(pos, pos)
    if c == "]" then
      return out, pos + 1
    end
    if c ~= "," then
      parse_error(text, pos, "expected ',' or ']'")
    end
    pos = skip_ws(text, pos + 1)
  end
end

local function parse_object(text, pos)
  pos = skip_ws(text, pos + 1)
  local out = {}
  if text:sub(pos, pos) == "}" then
    return out, pos + 1
  end
  while true do
    local key
    key, pos = parse_string(text, pos)
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) ~= ":" then
      parse_error(text, pos, "expected ':'")
    end
    out[key], pos = parse_value(text, skip_ws(text, pos + 1))
    pos = skip_ws(text, pos)
    local c = text:sub(pos, pos)
    if c == "}" then
      return out, pos + 1
    end
    if c ~= "," then
      parse_error(text, pos, "expected ',' or '}'")
    end
    pos = skip_ws(text, pos + 1)
  end
end

function parse_value(text, pos)
  pos = skip_ws(text, pos)
  local c = text:sub(pos, pos)
  if c == '"' then
    return parse_string(text, pos)
  elseif c == "{" then
    return parse_object(text, pos)
  elseif c == "[" then
    return parse_array(text, pos)
  elseif c == "t" and text:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif c == "f" and text:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif c == "n" and text:sub(pos, pos + 3) == "null" then
    return nil, pos + 4
  elseif c == "-" or c:match("%d") then
    return parse_number(text, pos)
  end
  parse_error(text, pos, "unexpected value")
end

function json.decode(text)
  local value, pos = parse_value(text, 1)
  pos = skip_ws(text, pos)
  if pos <= #text then
    parse_error(text, pos, "trailing data")
  end
  return value
end

local function encode_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
    if c == '"' then
      return '\\"'
    elseif c == "\\" then
      return "\\\\"
    elseif c == "\n" then
      return "\\n"
    elseif c == "\r" then
      return "\\r"
    elseif c == "\t" then
      return "\\t"
    end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(value)
  local max = 0
  local count = 0
  for k, _ in pairs(value) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      return false
    end
    if k > max then
      max = k
    end
    count = count + 1
  end
  return max == count
end

function json.encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "number" then
    return tostring(value)
  elseif t == "string" then
    return encode_string(value)
  elseif t == "table" then
    local out = {}
    if is_array(value) then
      for i = 1, #value do
        out[#out + 1] = json.encode(value[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k, _ in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      out[#out + 1] = encode_string(tostring(k)) .. ":" .. json.encode(value[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return encode_string("<" .. t .. ">")
end

local memory_aliases = {
  snesMemory = emu.memType.snesMemory,
  snesPrgRom = emu.memType.snesPrgRom,
  snesWorkRam = emu.memType.snesWorkRamDebug or emu.memType.snesWorkRam,
  nesMemory = emu.memType.nesMemory,
  nesPrgRom = emu.memType.nesPrgRom,
  nesChrRom = emu.memType.nesChrRom,
  nesInternalRam = emu.memType.nesInternalRamDebug or emu.memType.nesInternalRam,
  pceMemory = emu.memType.pceMemory,
  pcePrgRom = emu.memType.pcePrgRom,
  pceWorkRam = emu.memType.pceWorkRamDebug or emu.memType.pceWorkRam,
  gbaMemory = emu.memType.gbaMemory,
  gbaPrgRom = emu.memType.gbaPrgRom,
  gbaIntWorkRam = emu.memType.gbaIntWorkRamDebug or emu.memType.gbaIntWorkRam,
  gbaExtWorkRam = emu.memType.gbaExtWorkRamDebug or emu.memType.gbaExtWorkRam,
}

local prg_rom_by_console = {
  Snes = "snesPrgRom",
  Nes = "nesPrgRom",
  PcEngine = "pcePrgRom",
  Gba = "gbaPrgRom",
}

local callback_aliases = {
  read = emu.callbackType.read,
  write = emu.callbackType.write,
  exec = emu.callbackType.exec,
}

local cpu_aliases = {
  main = nil,
  snes = emu.cpuType.snes,
  spc = emu.cpuType.spc,
  nes = emu.cpuType.nes,
  pce = emu.cpuType.pce,
  gba = emu.cpuType.gba,
}

local function mem_type(name_or_id)
  if type(name_or_id) == "number" then
    return name_or_id
  end
  local value = memory_aliases[name_or_id]
  if value == nil then
    error("unknown memory type: " .. tostring(name_or_id))
  end
  return value
end

local function cpu_type(name_or_id)
  if name_or_id == nil or name_or_id == "main" then
    return nil
  end
  if type(name_or_id) == "number" then
    return name_or_id
  end
  local value = cpu_aliases[name_or_id]
  if value == nil then
    error("unknown cpu type: " .. tostring(name_or_id))
  end
  return value
end

local function read_memory(args)
  local address = assert(args.address, "address is required")
  local length = assert(args.length, "length is required")
  local mt = mem_type(args.memoryType)
  local bytes = {}
  for i = 0, length - 1 do
    bytes[#bytes + 1] = emu.read(address + i, mt, false)
  end
  return {
    address = address,
    length = length,
    memoryType = args.memoryType,
    bytes = bytes,
  }
end

local commands = {}
local frame_count = 0
local next_handle = 1
local watches = {}
local watch_events = {}
local breakpoints = {}
local breakpoint_events = {}
local traces = {}
local cdl_active = false
local max_event_buffer = tonumber(os.getenv("MESEN_BRIDGE_MAX_EVENTS") or "2048")
local pending_responses = {}
local pending_marker = {}

local function new_handle(prefix)
  local handle = prefix .. "-" .. tostring(next_handle)
  next_handle = next_handle + 1
  return handle
end

local function callback_type(name_or_id)
  if type(name_or_id) == "number" then
    return name_or_id
  end
  local value = callback_aliases[name_or_id or "write"]
  if value == nil then
    error("unknown callback type: " .. tostring(name_or_id))
  end
  return value
end

function commands.ping()
  return { ok = true, message = "pong" }
end

function commands.romInfo()
  return emu.getRomInfo()
end

function commands.readMemory(args)
  return read_memory(args or {})
end

function commands.writeMemory(args)
  args = args or {}
  local address = assert(args.address, "address is required")
  local bytes = assert(args.bytes, "bytes is required")
  local mt = mem_type(args.memoryType)
  for i, value in ipairs(bytes) do
    emu.write(address + i - 1, value, mt)
  end
  return { address = address, length = #bytes, memoryType = args.memoryType }
end

function commands.cpuState(args)
  args = args or {}
  local ct = cpu_type(args.cpuType)
  if ct == nil then
    return emu.getCpuState()
  end
  return emu.getCpuState(ct)
end

function commands.setCpuState(args)
  args = args or {}
  local state = assert(args.state, "state is required")
  local ct = cpu_type(args.cpuType)
  if ct == nil then
    emu.setCpuState(state)
  else
    emu.setCpuState(state, ct)
  end
  return { ok = true }
end

function commands.reset()
  emu.reset()
  frame_count = 0
  return { ok = true }
end

function commands.status()
  local ok_cycles, cycles = pcall(emu.getCpuCycleCount)
  return {
    frame = frame_count,
    masterClock = emu.getMasterClock(),
    cpuCycleCount = ok_cycles and cycles or nil,
  }
end

function commands.resetRunFrames(args, request_context)
  args = args or {}
  local frames = assert(args.frames, "frames is required")
  emu.reset()
  frame_count = 0
  pending_responses[#pending_responses + 1] = {
    client = request_context.client,
    id = request_context.id,
    startFrame = 0,
    targetFrame = frames,
  }
  return pending_marker
end

local function event_record(handle, address, value, cpu)
  return {
    handle = handle,
    address = address,
    value = value,
    cpuType = cpu,
    frame = frame_count,
    masterClock = emu.getMasterClock(),
    cpuCycleCount = emu.getCpuCycleCount(cpu),
  }
end

local function append_event(buffer, event)
  buffer[#buffer + 1] = event
  if #buffer > max_event_buffer then
    table.remove(buffer, 1)
  end
end

function commands.createWatch(args)
  args = args or {}
  local address = assert(args.address, "address is required")
  local length = args.length or 1
  local mt = mem_type(args.memoryType)
  local ct = cpu_type(args.cpuType) or emu.cpuType.snes
  local cb = callback_type(args.access or "write")
  local handle = new_handle("watch")
  local ref
  ref = emu.addMemoryCallback(function(addr, value)
    append_event(watch_events, event_record(handle, addr, value, ct))
  end, cb, address, address + length - 1, ct, mt)
  watches[handle] = {
    handle = handle,
    reference = ref,
    address = address,
    length = length,
    memoryType = args.memoryType,
    cpuType = args.cpuType,
    access = args.access or "write",
    callbackType = cb,
  }
  return watches[handle]
end

function commands.listWatches()
  local out = {}
  for _, watch in pairs(watches) do
    out[#out + 1] = watch
  end
  return { watches = out, events = watch_events }
end

function commands.deleteWatch(args)
  args = args or {}
  local handle = assert(args.handle, "handle is required")
  local watch = watches[handle]
  if watch == nil then
    error("unknown watch handle: " .. tostring(handle))
  end
  emu.removeMemoryCallback(watch.reference, watch.callbackType, watch.address, watch.address + watch.length - 1, cpu_type(watch.cpuType) or emu.cpuType.snes, mem_type(watch.memoryType))
  watches[handle] = nil
  return { ok = true, handle = handle }
end

function commands.createBreakpoint(args)
  args = args or {}
  local address = assert(args.address, "address is required")
  local length = args.length or 1
  local mt = mem_type(args.memoryType)
  local ct = cpu_type(args.cpuType) or emu.cpuType.snes
  local cb = callback_type(args.access or "exec")
  local handle = new_handle("breakpoint")
  local ref
  ref = emu.addMemoryCallback(function(addr, value)
    append_event(breakpoint_events, event_record(handle, addr, value, ct))
    emu.breakExecution()
  end, cb, address, address + length - 1, ct, mt)
  breakpoints[handle] = {
    handle = handle,
    reference = ref,
    address = address,
    length = length,
    memoryType = args.memoryType,
    cpuType = args.cpuType,
    access = args.access or "exec",
    callbackType = cb,
  }
  return breakpoints[handle]
end

function commands.listBreakpoints()
  local out = {}
  for _, breakpoint in pairs(breakpoints) do
    out[#out + 1] = breakpoint
  end
  return { breakpoints = out, events = breakpoint_events }
end

function commands.deleteBreakpoint(args)
  args = args or {}
  local handle = assert(args.handle, "handle is required")
  local breakpoint = breakpoints[handle]
  if breakpoint == nil then
    error("unknown breakpoint handle: " .. tostring(handle))
  end
  emu.removeMemoryCallback(breakpoint.reference, breakpoint.callbackType, breakpoint.address, breakpoint.address + breakpoint.length - 1, cpu_type(breakpoint.cpuType) or emu.cpuType.snes, mem_type(breakpoint.memoryType))
  breakpoints[handle] = nil
  return { ok = true, handle = handle }
end

local function default_cdl_memory_type()
  local info = emu.getRomInfo()
  local console = emu.getState().consoleType
  local alias = prg_rom_by_console[console]
  if alias == nil then
    if info.name:lower():match("%.nes$") then
      alias = "nesPrgRom"
    elseif info.name:lower():match("%.gba$") then
      alias = "gbaPrgRom"
    elseif info.name:lower():match("%.pce$") then
      alias = "pcePrgRom"
    else
      alias = "snesPrgRom"
    end
  end
  return alias
end

local function decode_cdl_flags(value)
  return {
    raw = value,
    code = (value & 0x01) ~= 0,
    data = (value & 0x02) ~= 0,
    jumpTarget = (value & 0x04) ~= 0,
    subEntryPoint = (value & 0x08) ~= 0,
  }
end

local function cdl_class(value)
  local code = (value & 0x01) ~= 0
  local data = (value & 0x02) ~= 0
  if code and data then
    return "code+data"
  elseif code then
    return "code"
  elseif data then
    return "data"
  end
  return "unknown"
end

function commands.startCdl()
  cdl_active = true
  return { ok = true, note = "Mesen records CDL data continuously; start marks this session active." }
end

function commands.stopCdl()
  cdl_active = false
  return { ok = true }
end

function commands.getCdl(args)
  args = args or {}
  local memory_name = args.memoryType or default_cdl_memory_type()
  local mt = mem_type(memory_name)
  local offset = args.offset or 0
  local length = args.length or emu.getMemorySize(mt)
  local data = emu.getCdlData(mt)
  local bytes = {}
  for i = offset + 1, math.min(offset + length, #data) do
    bytes[#bytes + 1] = decode_cdl_flags(data[i])
  end
  return {
    active = cdl_active,
    memoryType = memory_name,
    offset = offset,
    length = #bytes,
    memorySize = emu.getMemorySize(mt),
    bytes = bytes,
  }
end

local function write_cdl_export(path, memory_name, data, memory_size)
  local file = assert(io.open(path, "w"))
  file:write("{\"memoryType\":", json.encode(memory_name), ",\"memorySize\":", tostring(memory_size), ",\"bytes\":[")
  local summaries = {}
  local current = nil
  for i = 1, memory_size do
    local value = data[i] or 0
    if i > 1 then
      file:write(",")
    end
    file:write(json.encode(decode_cdl_flags(value)))
    local class = cdl_class(value)
    local jump = (value & 0x04) ~= 0
    local sub = (value & 0x08) ~= 0
    if current and current.classification == class and current.jumpTarget == jump and current.subEntryPoint == sub then
      current["end"] = i - 1
    else
      current = { start = i - 1, ["end"] = i - 1, classification = class, jumpTarget = jump, subEntryPoint = sub }
      summaries[#summaries + 1] = current
    end
  end
  file:write("],\"summary\":", json.encode(summaries), "}\n")
  file:close()
  return summaries
end

function commands.exportCdl(args)
  args = args or {}
  local path = assert(args.path, "path is required")
  local memory_name = args.memoryType or default_cdl_memory_type()
  local mt = mem_type(memory_name)
  local size = emu.getMemorySize(mt)
  local data = emu.getCdlData(mt)
  local summaries = write_cdl_export(path, memory_name, data, size)
  local covered = 0
  local code = 0
  local data_count = 0
  local sample = {}
  for i = 1, size do
    local value = data[i] or 0
    if (value & 0x01) ~= 0 then code = code + 1 end
    if (value & 0x02) ~= 0 then data_count = data_count + 1 end
  end
  for _, summary in ipairs(summaries) do
    covered = covered + (summary["end"] - summary.start + 1)
    if #sample < 12 and summary.classification ~= "unknown" then
      sample[#sample + 1] = summary
    end
  end
  return {
    path = path,
    memoryType = memory_name,
    memorySize = size,
    summaryRanges = #summaries,
    coveredBytes = covered,
    codeBytes = code,
    dataBytes = data_count,
    sampleRanges = sample,
  }
end

function commands.startTrace(args)
  args = args or {}
  local ct = cpu_type(args.cpuType)
  local handle = new_handle("trace")
  traces[handle] = {
    handle = handle,
    cpuType = args.cpuType,
    startFrame = frame_count,
    startMasterClock = emu.getMasterClock(),
    startCpuCycleCount = ct and emu.getCpuCycleCount(ct) or emu.getCpuCycleCount(),
  }
  return traces[handle]
end

function commands.stopTrace(args)
  args = args or {}
  local handle = assert(args.handle, "handle is required")
  local trace = traces[handle]
  if trace == nil then
    error("unknown trace handle: " .. tostring(handle))
  end
  local ct = cpu_type(trace.cpuType)
  trace.endFrame = frame_count
  trace.endMasterClock = emu.getMasterClock()
  trace.endCpuCycleCount = ct and emu.getCpuCycleCount(ct) or emu.getCpuCycleCount()
  trace.elapsedFrames = trace.endFrame - trace.startFrame
  trace.elapsedMasterClocks = trace.endMasterClock - trace.startMasterClock
  trace.elapsedCpuCycles = trace.endCpuCycleCount - trace.startCpuCycleCount
  return trace
end

function commands.listTraces()
  local out = {}
  for _, trace in pairs(traces) do
    out[#out + 1] = trace
  end
  return { traces = out }
end

function commands.shutdown()
  emu.stop(0)
  return { ok = true }
end

local server = assert(socket.tcp())
server:setoption("reuseaddr", true)
assert(server:bind(host, port))
assert(server:listen(8))
server:settimeout(0)

if ready_path and ready_path ~= "" then
  local file = assert(io.open(ready_path, "w"))
  file:write(host, ":", tostring(port), "\n")
  file:close()
end

local clients = {}

local function send_response(client, response)
  client:send(json.encode(response) .. "\n")
end

local function handle_line(client, line)
  local ok, request = pcall(json.decode, line)
  if not ok then
    send_response(client, { id = nil, error = { code = "parse_error", message = request } })
    return
  end

  local id = request.id
  local command = commands[request.command]
  if command == nil then
    send_response(client, { id = id, error = { code = "unknown_command", message = "unknown command: " .. tostring(request.command) } })
    return
  end

  local ran, result = pcall(command, request.args or {}, { client = client, id = id })
  if ran then
    if result ~= pending_marker then
      send_response(client, { id = id, result = result })
    end
  else
    send_response(client, { id = id, error = { code = "command_error", message = tostring(result) } })
  end
end

local function process_pending()
  if #pending_responses == 0 then
    return
  end
  local remaining = {}
  for _, pending in ipairs(pending_responses) do
    if frame_count >= pending.targetFrame then
      send_response(pending.client, {
        id = pending.id,
        result = {
          startFrame = pending.startFrame,
          targetFrame = pending.targetFrame,
          status = {
            frame = frame_count,
            masterClock = emu.getMasterClock(),
            cpuCycleCount = emu.getCpuCycleCount(),
          },
        },
      })
    else
      remaining[#remaining + 1] = pending
    end
  end
  pending_responses = remaining
end

local function pump_socket()
  while true do
    local client = server:accept()
    if not client then
      break
    end
    client:settimeout(0)
    clients[client] = ""
  end

  local readable = {}
  for client, _ in pairs(clients) do
    readable[#readable + 1] = client
  end

  if #readable == 0 then
    return
  end

  local ready = socket.select(readable, nil, 0)
  for _, client in ipairs(ready) do
    while true do
      local chunk, err, partial = client:receive(1024)
      local data = chunk or partial
      if data and #data > 0 then
        local buffer = clients[client] .. data
        while true do
          local nl = buffer:find("\n", 1, true)
          if not nl then
            break
          end
          local line = buffer:sub(1, nl - 1)
          buffer = buffer:sub(nl + 1)
          if #line > 0 then
            handle_line(client, line)
          end
        end
        clients[client] = buffer
      end
      if err == "closed" then
        clients[client] = nil
        client:close()
        break
      end
      if err == "timeout" or chunk == nil then
        break
      end
    end
  end
end

emu.addEventCallback(function()
  frame_count = frame_count + 1
  process_pending()
  pump_socket()
end, emu.eventType.endFrame)

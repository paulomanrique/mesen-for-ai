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
    for k, v in pairs(value) do
      out[#out + 1] = encode_string(tostring(k)) .. ":" .. json.encode(v)
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

  local ran, result = pcall(command, request.args or {})
  if ran then
    send_response(client, { id = id, result = result })
  else
    send_response(client, { id = id, error = { code = "command_error", message = tostring(result) } })
  end
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
  pump_socket()
end, emu.eventType.endFrame)

local out_path = assert(os.getenv("MESEN_SOCKET_CHECK"))
local file = assert(io.open(out_path, "w"))
local ok, socket = pcall(require, "socket.core")
file:write("ok=", tostring(ok), "\n")
file:write("type=", type(socket), "\n")
if ok and socket then
  for _, key in ipairs({ "tcp", "bind", "select", "_VERSION" }) do
    file:write(key, "=", tostring(socket[key]), "\n")
  end
end
file:close()
emu.stop(0)

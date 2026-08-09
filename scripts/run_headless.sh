#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <rom> <script.lua>" >&2
  exit 64
fi

ROM=$1
LUA_SCRIPT=$2

if [[ ! -f "$ROM" ]]; then
  echo "ROM not found: $ROM" >&2
  exit 66
fi

if [[ ! -f "$LUA_SCRIPT" ]]; then
  echo "Lua script not found: $LUA_SCRIPT" >&2
  exit 66
fi

ROM=$(realpath "$ROM")
LUA_SCRIPT=$(realpath "$LUA_SCRIPT")

MESEN_BIN=${MESEN_BIN:-"$HOME/tools/mesen-src/bin/linux-x64/Release/Mesen"}
if [[ ! -x "$MESEN_BIN" ]]; then
  echo "Mesen binary not executable: $MESEN_BIN" >&2
  exit 69
fi

SESSION_ROOT=${MESEN_MCP_SESSION_ROOT:-"$(mktemp -d -t mesen-for-ai.XXXXXX)"}
SESSION_HOME="$SESSION_ROOT/home"
SESSION_WORK="$SESSION_ROOT/work"
MESEN_CONFIG_HOME="$SESSION_HOME/.config/MesenCE"

mkdir -p "$MESEN_CONFIG_HOME" "$SESSION_WORK"

cat > "$MESEN_CONFIG_HOME/settings.json" <<'JSON'
{
  "Debug": {
    "ScriptWindow": {
      "AllowIoOsAccess": true,
      "AllowNetworkAccess": true
    }
  },
  "Snes": {
    "RamPowerOnState": 1,
    "EnableRandomPowerOnState": false
  },
  "Nes": {
    "RamPowerOnState": 1,
    "RandomizeMapperPowerOnState": false,
    "RandomizeCpuPpuAlignment": false
  },
  "PcEngine": {
    "RamPowerOnState": 1,
    "EnableRandomPowerOnState": false
  },
  "Gba": {
    "RamPowerOnState": 1
  },
  "Gameboy": {
    "RamPowerOnState": 1
  }
}
JSON

export HOME="$SESSION_HOME"
export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"

cd "$SESSION_WORK"
exec xvfb-run -a "$MESEN_BIN" --testrunner "$ROM" "$LUA_SCRIPT" --timeout="${MESEN_TESTRUNNER_TIMEOUT:-30}" >"$SESSION_ROOT/mesen.stdout.log" 2>"$SESSION_ROOT/mesen.stderr.log"

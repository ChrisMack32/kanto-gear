-- Standalone letterbox / coordinate tests for the desktop companion bridge.
-- Run with: lua mod/kanto_gear/tests/desktop_bridge_test.lua
-- (plain Lua or LuaJIT; no LÖVE / modkit required)

local path = arg and arg[0] or "?"
local root = path:match("(.*/)") or "./"
local bridgePath = root .. "../desktop_bridge.lua"
local f = assert(io.open(bridgePath, "r"), "missing " .. bridgePath)
local source = f:read("*a")
f:close()

local chunk = assert(load(source, "@desktop_bridge.lua"))
local Bridge = chunk()

local failures = 0
local function check(cond, msg)
  if cond then
    io.write("ok  - ", msg, "\n")
  else
    failures = failures + 1
    io.write("FAIL - ", msg, "\n")
  end
end

local function eq(a, b, msg)
  check(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b)))
end

-- 3x integer letterbox in a perfect 480x432 window
do
  local dx, dy, dw, dh, scale = Bridge.letterbox(480, 432, 160, 144)
  eq(scale, 3, "perfect 3x scale")
  eq(dx, 0, "perfect 3x dx")
  eq(dy, 0, "perfect 3x dy")
  eq(dw, 480, "perfect 3x dw")
  eq(dh, 432, "perfect 3x dh")
end

-- Wider window centers horizontally
do
  local dx, dy, dw, dh, scale = Bridge.letterbox(640, 432, 160, 144)
  eq(scale, 3, "wide window scale")
  eq(dx, 80, "wide window dx")
  eq(dy, 0, "wide window dy")
  eq(dw, 480, "wide window dw")
end

-- Logical mapping: top-left pixel inside content
do
  local lx, ly = Bridge.logicalPoint(80, 0, 640, 432, 160, 144)
  eq(lx, 0, "top-left logical x")
  eq(ly, 0, "top-left logical y")
end

-- Center of letterboxed content -> center of GB screen
do
  local lx, ly = Bridge.logicalPoint(80 + 240, 216, 640, 432, 160, 144)
  eq(lx, 80, "center logical x")
  eq(ly, 72, "center logical y")
end

-- Click in the side pillarbox is ignored
do
  local lx = Bridge.logicalPoint(10, 100, 640, 432, 160, 144)
  check(lx == nil, "pillarbox click ignored")
end

-- Bottom-right content pixel
do
  local lx, ly = Bridge.logicalPoint(80 + 479, 431, 640, 432, 160, 144)
  eq(lx, 159, "bottom-right logical x")
  eq(ly, 143, "bottom-right logical y")
end

-- rgb24 helper
do
  local r, g, b = Bridge.rgb24ToFloat(0x0F380F)
  check(math.abs(r - 15 / 255) < 1e-6, "rgb24 red")
  check(math.abs(g - 56 / 255) < 1e-6, "rgb24 green")
  check(math.abs(b - 15 / 255) < 1e-6, "rgb24 blue")
end

if failures > 0 then
  io.write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
io.write("desktop bridge letterbox tests passed\n")

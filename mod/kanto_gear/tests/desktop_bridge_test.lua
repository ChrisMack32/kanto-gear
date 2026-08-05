-- Standalone letterbox / coordinate tests for the desktop companion bridge.
-- Run with: lua mod/kanto_gear/tests/desktop_bridge_test.lua

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

local function nearly(a, b, msg)
  check(math.abs(a - b) < 1e-6, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b)))
end

-- Perfect 3x window fills exactly
do
  local dx, dy, dw, dh, scale = Bridge.letterbox(480, 432, 160, 144)
  nearly(scale, 3, "perfect 3x scale")
  eq(dx, 0, "perfect 3x dx")
  eq(dy, 0, "perfect 3x dy")
  eq(dw, 480, "perfect 3x dw")
  eq(dh, 432, "perfect 3x dh")
end

-- Too-wide window letterboxes horizontally
do
  local dx, dy, dw, dh, scale = Bridge.letterbox(640, 432, 160, 144)
  nearly(scale, 3, "wide window scale")
  eq(dx, 80, "wide window dx")
  eq(dy, 0, "wide window dy")
  eq(dw, 480, "wide window dw")
end

-- Logical mapping
do
  local lx, ly = Bridge.logicalPoint(80, 0, 640, 432, 160, 144)
  eq(lx, 0, "top-left logical x")
  eq(ly, 0, "top-left logical y")
end
do
  local lx, ly = Bridge.logicalPoint(80 + 240, 216, 640, 432, 160, 144)
  eq(lx, 80, "center logical x")
  eq(ly, 72, "center logical y")
end
do
  local lx = Bridge.logicalPoint(10, 100, 640, 432, 160, 144)
  check(lx == nil, "pillarbox click ignored")
end

-- Aspect constrain keeps 160:144
do
  local w, h = Bridge.constrainAspect(500, 400, 160, 144)
  eq(w * 144, h * 160, "wide proposal keeps aspect product")
  check(w >= 160 and h >= 144, "wide proposal above minimum")
end
do
  local w, h = Bridge.constrainAspect(200, 900, 160, 144)
  eq(w * 144, h * 160, "tall proposal keeps aspect product")
end
do
  local w, h = Bridge.constrainAspect(80, 80, 160, 144)
  eq(w, 160, "below-min width floors to 160")
  eq(h, 144, "below-min height floors to 144")
end
do
  local w, h = Bridge.constrainAspect(480, 432, 160, 144)
  eq(w, 480, "exact 3x width unchanged")
  eq(h, 432, "exact 3x height unchanged")
end

-- rgb24 helper
do
  local r, g, b = Bridge.rgb24ToFloat(0x0F380F)
  nearly(r, 15 / 255, "rgb24 red")
  nearly(g, 56 / 255, "rgb24 green")
  nearly(b, 15 / 255, "rgb24 blue")
end

if failures > 0 then
  io.write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
io.write("desktop bridge letterbox tests passed\n")

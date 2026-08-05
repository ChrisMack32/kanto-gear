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

-- Drag-aware aspect: width-dominant when width changed more
do
  local w, h, widthDriven = Bridge.constrainAspectDrag(700, 300, 480, 432, 160, 144)
  check(widthDriven == true, "wide drag is width-driven")
  eq(w * 144, h * 160, "wide drag keeps aspect product")
  eq(w, 700, "wide drag keeps proposed width")
end
-- Height-dominant when height changed more
do
  local w, h, widthDriven = Bridge.constrainAspectDrag(200, 900, 480, 432, 160, 144)
  check(widthDriven == false, "tall drag is height-driven")
  eq(w * 144, h * 160, "tall drag keeps aspect product")
  eq(h, 900, "tall drag keeps proposed height")
end

-- Clamp oversized 160:144 proposals to fit a 16:9 monitor
do
  local w, h = Bridge.clampAspectToMax(1920, 1728, 1904, 1016, 160, 144)
  check(w <= 1904 and h <= 1016, "clamped inside 16:9 usable area")
  eq(w * 144, h * 160, "clamped size keeps aspect product")
  eq(w, 1120, "16:9 clamp uses integer GB scale width")
  eq(h, 1008, "16:9 clamp uses integer GB scale height")
end
do
  local w, h = Bridge.clampAspectToMax(800, 720, 1904, 1016, 160, 144)
  eq(w, 800, "already-fitting width unchanged")
  eq(h, 720, "already-fitting height unchanged")
end

-- HiDPI: scale window-point letterbox into 2× renderer pixels
do
  local dx, dy, dw, dh = Bridge.letterbox(480, 432, 160, 144)
  local ox, oy, ow, oh, sx, sy = Bridge.scaleToOutput(dx, dy, dw, dh, 480, 432, 960, 864)
  nearly(sx, 2, "retina scale x")
  nearly(sy, 2, "retina scale y")
  eq(ox, 0, "retina dx")
  eq(oy, 0, "retina dy")
  eq(ow, 960, "retina dw fills output width")
  eq(oh, 864, "retina dh fills output height")
end
do
  local ox, oy, ow, oh, sx, sy = Bridge.scaleToOutput(80, 0, 480, 432, 640, 432, 1280, 864)
  nearly(sx, 2, "retina wide scale x")
  eq(ox, 160, "retina wide pillarbox dx")
  eq(ow, 960, "retina wide content width")
  eq(oh, 864, "retina wide content height")
end
-- 1× DPI is a no-op
do
  local ox, oy, ow, oh, sx, sy = Bridge.scaleToOutput(0, 0, 480, 432, 480, 432, 480, 432)
  nearly(sx, 1, "1x scale x")
  nearly(sy, 1, "1x scale y")
  eq(ow, 480, "1x dw unchanged")
  eq(oh, 432, "1x dh unchanged")
end

-- Windows aspect helper (post-resize path; SysWM hook removed)
do
  local rect = { left = 100, top = 50, right = 600, bottom = 400 }
  Bridge._applyWinSizing(rect, 2) -- WMSZ_RIGHT
  eq(rect.left, 100, "right-edge resize keeps left")
  eq((rect.right - rect.left) * 144, (rect.bottom - rect.top) * 160,
    "right-edge resize keeps aspect product")
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

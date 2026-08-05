-- Desktop secondary-display bridge for stock Gen1Recomp (Windows / macOS /
-- Linux). When the Android host APIs are missing, this polyfills the same
-- love.system + Canvas readback surface Kanto Gear already uses, backed by a
-- second SDL2 window.

local Bridge = {}

local WIDTH, HEIGHT = 160, 144
local DEFAULT_SCALE = 3
local MAX_TOUCHES = 64

local FRAME_W = WIDTH
local FRAME_H = HEIGHT

------------------------------------------------------------------------
-- Pure helpers (also used by unit tests)
------------------------------------------------------------------------

function Bridge.letterbox(vw, vh, fw, fh)
  fw = fw or FRAME_W
  fh = fh or FRAME_H
  vw = math.max(1, math.floor(vw or 0))
  vh = math.max(1, math.floor(vh or 0))
  local scale = math.min(math.floor(vw / fw), math.floor(vh / fh))
  if scale < 1 then scale = 1 end
  local dw, dh = fw * scale, fh * scale
  local dx = math.floor((vw - dw) / 2)
  local dy = math.floor((vh - dh) / 2)
  return dx, dy, dw, dh, scale
end

function Bridge.logicalPoint(x, y, vw, vh, fw, fh)
  fw = fw or FRAME_W
  fh = fh or FRAME_H
  local dx, dy, dw, dh = Bridge.letterbox(vw, vh, fw, fh)
  if dw <= 0 or dh <= 0 then return nil end
  if x < dx or y < dy or x >= dx + dw or y >= dy + dh then return nil end
  local lx = math.min(fw - 1, math.max(0, math.floor((x - dx) * fw / dw)))
  local ly = math.min(fh - 1, math.max(0, math.floor((y - dy) * fh / dh)))
  return lx, ly
end

function Bridge.rgb24ToFloat(color)
  color = color or 0
  local r = math.floor(color / 0x10000) % 0x100
  local g = math.floor(color / 0x100) % 0x100
  local b = color % 0x100
  return r / 255, g / 255, b / 255, 1
end

------------------------------------------------------------------------
-- SDL loader
------------------------------------------------------------------------

local function tryLoadSDL(ffi)
  local names = {}
  if ffi.os == "Windows" then
    names = { "SDL2", "SDL2.dll" }
  elseif ffi.os == "OSX" then
    names = {
      "SDL2",
      "libSDL2-2.0.0.dylib",
      "libSDL2.dylib",
      "/usr/local/lib/libSDL2.dylib",
      "/opt/homebrew/lib/libSDL2.dylib",
    }
  else
    names = {
      "SDL2",
      "libSDL2-2.0.so.0",
      "libSDL2.so",
      "libSDL2-2.0.so",
    }
  end

  -- Prefer symbols already linked into the host binary when exported.
  local okC = pcall(function() return ffi.C.SDL_CreateWindow end)
  if okC then return ffi.C, "C" end

  local bases = {}
  local love = rawget(_G, "love")
  if love and love.filesystem then
    pcall(function()
      bases[#bases + 1] = love.filesystem.getSourceBaseDirectory()
    end)
    pcall(function()
      bases[#bases + 1] = love.filesystem.getWorkingDirectory()
    end)
  end

  local sep = ffi.os == "Windows" and "\\" or "/"
  local tried = {}
  local function attempt(name)
    if tried[name] then return nil end
    tried[name] = true
    local ok, lib = pcall(ffi.load, name)
    if ok and lib then return lib, name end
    return nil
  end

  for _, name in ipairs(names) do
    local lib, label = attempt(name)
    if lib then return lib, label end
    for _, base in ipairs(bases) do
      if type(base) == "string" and base ~= "" then
        local lib2, label2 = attempt(base .. sep .. name)
        if lib2 then return lib2, label2 end
        -- macOS app bundles often keep dylibs beside the executable.
        if ffi.os == "OSX" then
          local lib3, label3 = attempt(base .. "/../Frameworks/" .. name)
          if lib3 then return lib3, label3 end
        end
      end
    end
  end
  return nil, nil
end

local function defineSDL(ffi)
  ffi.cdef[[
    typedef struct SDL_Window SDL_Window;
    typedef struct SDL_Renderer SDL_Renderer;
    typedef struct SDL_Texture SDL_Texture;

    typedef enum {
      SDL_WINDOWEVENT_NONE = 0,
      SDL_WINDOWEVENT_SHOWN = 1,
      SDL_WINDOWEVENT_HIDDEN = 2,
      SDL_WINDOWEVENT_EXPOSED = 3,
      SDL_WINDOWEVENT_MOVED = 4,
      SDL_WINDOWEVENT_RESIZED = 5,
      SDL_WINDOWEVENT_SIZE_CHANGED = 6,
      SDL_WINDOWEVENT_MINIMIZED = 7,
      SDL_WINDOWEVENT_MAXIMIZED = 8,
      SDL_WINDOWEVENT_RESTORED = 9,
      SDL_WINDOWEVENT_ENTER = 10,
      SDL_WINDOWEVENT_LEAVE = 11,
      SDL_WINDOWEVENT_FOCUS_GAINED = 12,
      SDL_WINDOWEVENT_FOCUS_LOST = 13,
      SDL_WINDOWEVENT_CLOSE = 14
    } SDL_WindowEventID;

    typedef struct SDL_WindowEvent {
      uint32_t type;
      uint32_t timestamp;
      uint32_t windowID;
      uint8_t event;
      uint8_t padding1;
      uint8_t padding2;
      uint8_t padding3;
      int32_t data1;
      int32_t data2;
    } SDL_WindowEvent;

    typedef union SDL_Event {
      uint32_t type;
      SDL_WindowEvent window;
      uint8_t padding[128];
    } SDL_Event;

    SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags);
    void SDL_DestroyWindow(SDL_Window *window);
    uint32_t SDL_GetWindowID(SDL_Window *window);
    void SDL_GetWindowSize(SDL_Window *window, int *w, int *h);
    void SDL_GetWindowPosition(SDL_Window *window, int *x, int *y);
    uint32_t SDL_GetWindowFlags(SDL_Window *window);
    void SDL_ShowWindow(SDL_Window *window);
    void SDL_RaiseWindow(SDL_Window *window);
    void SDL_SetWindowTitle(SDL_Window *window, const char *title);

    SDL_Renderer *SDL_CreateRenderer(SDL_Window *window, int index, uint32_t flags);
    void SDL_DestroyRenderer(SDL_Renderer *renderer);
    int SDL_SetRenderDrawColor(SDL_Renderer *renderer, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
    int SDL_RenderClear(SDL_Renderer *renderer);
    int SDL_RenderCopy(SDL_Renderer *renderer, SDL_Texture *texture, const void *srcrect, const void *dstrect);
    void SDL_RenderPresent(SDL_Renderer *renderer);
    int SDL_RenderSetLogicalSize(SDL_Renderer *renderer, int w, int h);

    SDL_Texture *SDL_CreateTexture(SDL_Renderer *renderer, uint32_t format, int access, int w, int h);
    void SDL_DestroyTexture(SDL_Texture *texture);
    int SDL_UpdateTexture(SDL_Texture *texture, const void *rect, const void *pixels, int pitch);
    int SDL_SetTextureScaleMode(SDL_Texture *texture, int scaleMode);

    void SDL_PumpEvents(void);
    int SDL_PeepEvents(SDL_Event *events, int numevents, int action, uint32_t minType, uint32_t maxType);
    int SDL_PushEvent(SDL_Event *event);
    uint32_t SDL_GetGlobalMouseState(int *x, int *y);
    uint32_t SDL_GetMouseState(int *x, int *y);
    SDL_Window *SDL_GetMouseFocus(void);
    const char *SDL_GetError(void);

    typedef struct SDL_Rect { int x, y, w, h; } SDL_Rect;
  ]]
end

------------------------------------------------------------------------
-- Runtime state
------------------------------------------------------------------------

local state = {
  installed = false,
  usable = false,
  reason = nil,
  ffi = nil,
  sdl = nil,
  window = nil,
  renderer = nil,
  texture = nil,
  windowId = 0,
  bg = 0x0F380F,
  touches = {},
  prevButtons = 0,
  pointerDown = false,
  userClosed = false,
  frameW = FRAME_W,
  frameH = FRAME_H,
  log = nil,
}

local SDL_WINDOWPOS_CENTERED = 0x2FFF0000
local SDL_WINDOW_RESIZABLE = 0x00000020
local SDL_WINDOW_ALLOW_HIGHDPI = 0x00002000
local SDL_RENDERER_ACCELERATED = 0x00000002
local SDL_RENDERER_PRESENTVSYNC = 0x00000004
-- SDL_PIXELFORMAT_RGBA32 resolves to ABGR8888 on little-endian, matching
-- LÖVE ImageData's R,G,B,A byte order.
-- Little-endian RGBA32 == ABGR8888; matches LÖVE ImageData R,G,B,A bytes.
local SDL_PIXELFORMAT_RGBA32 = 0x16762004
local SDL_TEXTUREACCESS_STREAMING = 1
local SDL_ScaleModeNearest = 0
local SDL_WINDOWEVENT = 0x200
local SDL_GETEVENT = 2
local SDL_BUTTON_LMASK = 1

local function log(fmt, ...)
  if state.log then
    state.log:info(fmt, ...)
  end
end

local function warn(fmt, ...)
  if state.log then
    state.log:warn(fmt, ...)
  end
end

local function enqueueTouch(event)
  if #state.touches >= MAX_TOUCHES then
    state.touches = { "cancel,0,0" }
  end
  state.touches[#state.touches + 1] = event
end

local function destroyWindow()
  local sdl, ffi = state.sdl, state.ffi
  if not sdl then
    state.window, state.renderer, state.texture = nil, nil, nil
    state.windowId = 0
    return
  end
  if state.texture ~= nil then
    sdl.SDL_DestroyTexture(state.texture)
    state.texture = nil
  end
  if state.renderer ~= nil then
    sdl.SDL_DestroyRenderer(state.renderer)
    state.renderer = nil
  end
  if state.window ~= nil then
    sdl.SDL_DestroyWindow(state.window)
    state.window = nil
  end
  state.windowId = 0
  state.pointerDown = false
  state.prevButtons = 0
end

local function ensureWindow()
  if state.window ~= nil then return true end
  if not state.usable or not state.sdl then return false end
  if state.userClosed then return false end

  local sdl = state.sdl
  local w = FRAME_W * DEFAULT_SCALE
  local h = FRAME_H * DEFAULT_SCALE
  local window = sdl.SDL_CreateWindow(
    "Kanto Gear",
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    w, h,
    SDL_WINDOW_RESIZABLE + SDL_WINDOW_ALLOW_HIGHDPI)
  if window == nil then
    warn("SDL_CreateWindow failed: %s", tostring(sdl.SDL_GetError()))
    return false
  end

  local renderer = sdl.SDL_CreateRenderer(window, -1,
    SDL_RENDERER_ACCELERATED + SDL_RENDERER_PRESENTVSYNC)
  if renderer == nil then
    renderer = sdl.SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED)
  end
  if renderer == nil then
    warn("SDL_CreateRenderer failed: %s", tostring(sdl.SDL_GetError()))
    sdl.SDL_DestroyWindow(window)
    return false
  end

  local texture = sdl.SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32,
    SDL_TEXTUREACCESS_STREAMING, FRAME_W, FRAME_H)
  if texture == nil then
    warn("SDL_CreateTexture failed: %s", tostring(sdl.SDL_GetError()))
    sdl.SDL_DestroyRenderer(renderer)
    sdl.SDL_DestroyWindow(window)
    return false
  end
  pcall(function()
    sdl.SDL_SetTextureScaleMode(texture, SDL_ScaleModeNearest)
  end)

  state.window = window
  state.renderer = renderer
  state.texture = texture
  state.windowId = tonumber(sdl.SDL_GetWindowID(window)) or 0
  state.frameW, state.frameH = FRAME_W, FRAME_H
  log("companion window opened id=%s", tostring(state.windowId))
  return true
end

local function drainWindowEvents()
  local sdl, ffi = state.sdl, state.ffi
  if not sdl or state.window == nil then return end
  sdl.SDL_PumpEvents()
  local events = ffi.new("SDL_Event[32]")
  local n = sdl.SDL_PeepEvents(events, 32, SDL_GETEVENT, SDL_WINDOWEVENT, SDL_WINDOWEVENT)
  if n < 0 then return end
  for i = 0, n - 1 do
    local ev = events[i]
    if ev.window.windowID == state.windowId then
      if ev.window.event == 14 then -- SDL_WINDOWEVENT_CLOSE
        log("companion window closed by user")
        state.userClosed = true
        destroyWindow()
        enqueueTouch("cancel,0,0")
      end
    else
      -- Leave other windows' events for LÖVE.
      sdl.SDL_PushEvent(ev)
    end
  end
end

local function windowSize()
  local sdl, ffi = state.sdl, state.ffi
  local w = ffi.new("int[1]")
  local h = ffi.new("int[1]")
  sdl.SDL_GetWindowSize(state.window, w, h)
  return tonumber(w[0]), tonumber(h[0])
end

local function pollMouse()
  local sdl, ffi = state.sdl, state.ffi
  if not sdl or state.window == nil then return end

  local x, y, buttons
  local focused = sdl.SDL_GetMouseFocus() == state.window
  if focused then
    local mx = ffi.new("int[1]")
    local my = ffi.new("int[1]")
    buttons = tonumber(sdl.SDL_GetMouseState(mx, my)) or 0
    x, y = tonumber(mx[0]), tonumber(my[0])
  else
    local gx = ffi.new("int[1]")
    local gy = ffi.new("int[1]")
    buttons = tonumber(sdl.SDL_GetGlobalMouseState(gx, gy)) or 0
    local wx = ffi.new("int[1]")
    local wy = ffi.new("int[1]")
    sdl.SDL_GetWindowPosition(state.window, wx, wy)
    x = tonumber(gx[0]) - tonumber(wx[0])
    y = tonumber(gy[0]) - tonumber(wy[0])
  end

  local vw, vh = windowSize()
  local inside = x >= 0 and y >= 0 and x < vw and y < vh
  -- SDL_BUTTON_LMASK == 1
  local down = (buttons % 2) == 1
  local wasDown = (state.prevButtons % 2) == 1

  if down and not wasDown and (focused or inside) then
    local lx, ly = Bridge.logicalPoint(x, y, vw, vh, state.frameW, state.frameH)
    if lx then
      state.pointerDown = true
      enqueueTouch(string.format("down,%d,%d", lx, ly))
    end
  elseif (not down) and wasDown and state.pointerDown then
    local lx, ly = Bridge.logicalPoint(x, y, vw, vh, state.frameW, state.frameH)
    if not lx then
      -- Release outside the letterbox still ends the gesture at the clamped edge.
      lx = math.min(state.frameW - 1, math.max(0, math.floor(x * state.frameW / math.max(1, vw))))
      ly = math.min(state.frameH - 1, math.max(0, math.floor(y * state.frameH / math.max(1, vh))))
    end
    state.pointerDown = false
    enqueueTouch(string.format("up,%d,%d", lx, ly))
  elseif (not down) and wasDown then
    state.pointerDown = false
  end

  state.prevButtons = buttons
end

local function present(imageData, backgroundColor, _preference)
  if not state.usable then return false end
  if state.userClosed then
    -- Soft reopen on the next present attempt so the companion comes back
    -- after the player closes it, matching Android's retry behavior.
    state.userClosed = false
  end
  if type(imageData) ~= "userdata" and type(imageData) ~= "table" then
    return false
  end
  if not imageData.getWidth or not imageData.getFFIPointer then
    return false
  end

  local fw = imageData:getWidth()
  local fh = imageData:getHeight()
  if fw <= 0 or fh <= 0 then return false end

  if not ensureWindow() then return false end

  if fw ~= state.frameW or fh ~= state.frameH then
    local sdl = state.sdl
    if state.texture ~= nil then
      sdl.SDL_DestroyTexture(state.texture)
      state.texture = nil
    end
    state.texture = sdl.SDL_CreateTexture(state.renderer, SDL_PIXELFORMAT_RGBA32,
      SDL_TEXTUREACCESS_STREAMING, fw, fh)
    if state.texture == nil then return false end
    pcall(function()
      sdl.SDL_SetTextureScaleMode(state.texture, SDL_ScaleModeNearest)
    end)
    state.frameW, state.frameH = fw, fh
  end

  state.bg = backgroundColor or state.bg
  local ptr = imageData:getFFIPointer()
  local pitch = fw * 4
  if state.sdl.SDL_UpdateTexture(state.texture, nil, ptr, pitch) ~= 0 then
    warn("SDL_UpdateTexture failed: %s", tostring(state.sdl.SDL_GetError()))
    return false
  end

  local r = math.floor(state.bg / 0x10000) % 0x100
  local g = math.floor(state.bg / 0x100) % 0x100
  local b = state.bg % 0x100
  state.sdl.SDL_SetRenderDrawColor(state.renderer, r, g, b, 255)
  state.sdl.SDL_RenderClear(state.renderer)

  local vw, vh = windowSize()
  local dx, dy, dw, dh = Bridge.letterbox(vw, vh, state.frameW, state.frameH)
  local dest = state.ffi.new("SDL_Rect", { x = dx, y = dy, w = dw, h = dh })
  state.sdl.SDL_RenderCopy(state.renderer, state.texture, nil, dest)
  state.sdl.SDL_RenderPresent(state.renderer)

  drainWindowEvents()
  return state.window ~= nil
end

local function hasSecondaryDisplay()
  -- Always advertise while the bridge works. present() reopens after the
  -- player closes the companion, matching Android's retry behavior.
  return state.usable == true
end

local function pollSecondaryDisplayTouch()
  if not state.usable then return nil end
  drainWindowEvents()
  if state.window ~= nil then
    pollMouse()
  end
  if #state.touches == 0 then return nil end
  return table.remove(state.touches, 1)
end

local function closeSecondaryDisplay()
  state.userClosed = true
  destroyWindow()
  state.touches = {}
end

------------------------------------------------------------------------
-- Canvas async-readback polyfill (sync newImageData under the hood)
------------------------------------------------------------------------

local function installCanvasReadback(canvas)
  if not canvas or canvas.requestImageData then return canvas end
  local pending = false
  local pendingData = nil

  function canvas:requestImageData()
    if pending then return true end
    local ok, data = pcall(self.newImageData, self)
    if not ok or not data then return false end
    pending, pendingData = true, data
    return true
  end

  function canvas:pollImageData()
    if not pending then return nil end
    pending = false
    local data = pendingData
    pendingData = nil
    return data
  end

  return canvas
end

------------------------------------------------------------------------
-- Public install
------------------------------------------------------------------------

function Bridge.install(mod)
  if state.installed then return state.usable end
  state.installed = true
  state.log = mod and mod.log or nil

  local runtime = rawget(_G, "love")
  local system = runtime and runtime.system
  if system and system.hasSecondaryDisplay and system.presentSecondaryDisplay
      and system.pollSecondaryDisplayTouch then
    state.usable = false
    state.reason = "host bridge present"
    log("desktop bridge skipped; host secondary-display APIs present")
    return false
  end

  local ok, ffi = pcall(require, "ffi")
  if not (ok and ffi) then
    state.reason = "ffi unavailable"
    warn("desktop bridge inactive: %s", state.reason)
    return false
  end

  local defined, defErr = pcall(defineSDL, ffi)
  if not defined then
    -- Types may already exist from another bridge; continue and try load.
    log("sdl cdef note: %s", tostring(defErr))
  end

  local sdl, sdlName = tryLoadSDL(ffi)
  if not sdl then
    state.reason = "SDL2 library not found"
    warn("desktop bridge inactive: %s", state.reason)
    return false
  end

  local probeOk = pcall(function() return sdl.SDL_CreateWindow end)
  if not probeOk then
    state.reason = "SDL_CreateWindow missing"
    warn("desktop bridge inactive: %s", state.reason)
    return false
  end

  state.ffi = ffi
  state.sdl = sdl
  state.usable = true
  log("desktop bridge ready via %s (%s)", tostring(sdlName), tostring(ffi.os))

  if not system then
    warn("desktop bridge inactive: love.system missing")
    state.usable = false
    return false
  end

  system.hasSecondaryDisplay = hasSecondaryDisplay
  system.presentSecondaryDisplay = present
  system.pollSecondaryDisplayTouch = pollSecondaryDisplayTouch
  system.closeSecondaryDisplay = closeSecondaryDisplay

  if runtime then
    pcall(function()
      local prev = runtime.quit
      runtime.quit = function(...)
        destroyWindow()
        if type(prev) == "function" then return prev(...) end
      end
    end)
  end

  Bridge._state = state
  return true
end

function Bridge.installCanvasReadback(canvas)
  return installCanvasReadback(canvas)
end

function Bridge.isUsable()
  return state.usable == true
end

function Bridge.close()
  closeSecondaryDisplay()
end

return Bridge

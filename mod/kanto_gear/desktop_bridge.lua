-- Desktop secondary-display bridge for stock Gen1Recomp (Windows / macOS /
-- Linux). Polyfills the Android love.system secondary-display API with a
-- second SDL2 window. Aspect ratio is locked to 160:144 using native OS
-- hooks where possible (Cocoa / Win32) plus a per-frame fallback, because
-- LÖVE's event pump consumes SDL resize events before mods can see them.

local Bridge = {}

local WIDTH, HEIGHT = 160, 144
local DEFAULT_SCALE = 3
local MAX_TOUCHES = 64
local FRAME_W, FRAME_H = WIDTH, HEIGHT
local ASPECT = FRAME_W / FRAME_H -- 10/9

------------------------------------------------------------------------
-- Pure helpers (also used by unit tests)
------------------------------------------------------------------------

-- Fit the GB frame inside the window, preserving aspect (nearest-neighbour
-- friendly continuous scale so a correctly-proportioned window fills).
function Bridge.letterbox(vw, vh, fw, fh)
  fw = fw or FRAME_W
  fh = fh or FRAME_H
  vw = math.max(1, math.floor(vw or 0))
  vh = math.max(1, math.floor(vh or 0))
  local scale = math.min(vw / fw, vh / fh)
  if scale <= 0 then scale = 1 end
  local dw = math.max(1, math.floor(fw * scale + 0.5))
  local dh = math.max(1, math.floor(fh * scale + 0.5))
  local dx = math.floor((vw - dw) / 2)
  local dy = math.floor((vh - dh) / 2)
  return dx, dy, dw, dh, scale
end

-- Force a proposed window size onto the 160:144 aspect. Width-dominant when
-- the window is too wide; height-dominant when too tall.
function Bridge.constrainAspect(w, h, fw, fh)
  fw = fw or FRAME_W
  fh = fh or FRAME_H
  w = math.max(1, math.floor(tonumber(w) or fw))
  h = math.max(1, math.floor(tonumber(h) or fh))
  if (w / fw) >= (h / fh) then
    w = math.max(fw, w)
    h = math.max(fh, math.floor(w * fh / fw + 0.5))
  else
    h = math.max(fh, h)
    w = math.max(fw, math.floor(h * fw / fh + 0.5))
  end
  -- Final exact snap from width so floating error cannot drift the ratio.
  h = math.max(fh, math.floor(w * fh / fw + 0.5))
  return w, h, w / fw
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

-- Prefer the SDL2 already mapped into this process (LÖVE / Gen1Recomp).
-- Loading a second, different libSDL2.so on Linux (system vs AppImage)
-- creates a parallel SDL instance and hard-crashes shortly after window
-- create / present.
local function findMappedSDL(ffi)
  if ffi.os == "Windows" then return nil end
  local mapsPath = "/proc/self/maps"
  local f = io.open(mapsPath, "r")
  if not f then return nil end
  local best, bestScore = nil, -1
  for line in f:lines() do
    -- pathname is the last whitespace-separated field when present
    local path = line:match("%s(/[^%s]+)$")
    if path and path:find("libSDL2", 1, true) and path:find("%.so", 1, true)
        and not path:find("libSDL2_image", 1, true)
        and not path:find("libSDL2_mixer", 1, true)
        and not path:find("libSDL2_ttf", 1, true)
        and not path:find("libSDL2_net", 1, true) then
      local score = 1
      if path:find("libSDL2%-2%.0%.so%.0") then
        score = 4
      elseif path:find("libSDL2%-2%.0%.so") then
        score = 3
      elseif path:find("libSDL2%.so") then
        score = 2
      end
      if score > bestScore then
        best, bestScore = path, score
      end
    end
  end
  f:close()
  return best
end

local function tryLoadSDL(ffi)
  local names = {}
  local mapped = findMappedSDL(ffi)
  if mapped then
    names[#names + 1] = mapped
  end
  if ffi.os == "Windows" then
    names[#names + 1] = "SDL2"
    names[#names + 1] = "SDL2.dll"
  elseif ffi.os == "OSX" then
    names[#names + 1] = "SDL2"
    names[#names + 1] = "libSDL2-2.0.0.dylib"
    names[#names + 1] = "libSDL2.dylib"
    names[#names + 1] = "/usr/local/lib/libSDL2.dylib"
    names[#names + 1] = "/opt/homebrew/lib/libSDL2.dylib"
  else
    names[#names + 1] = "SDL2"
    names[#names + 1] = "libSDL2-2.0.so.0"
    names[#names + 1] = "libSDL2.so"
    names[#names + 1] = "libSDL2-2.0.so"
  end

  local okC = pcall(function() return ffi.C.SDL_CreateWindow end)
  if okC then return ffi.C, "C" end

  local bases = {}
  local love = rawget(_G, "love")
  if love and love.filesystem then
    pcall(function() bases[#bases + 1] = love.filesystem.getSourceBaseDirectory() end)
    pcall(function() bases[#bases + 1] = love.filesystem.getWorkingDirectory() end)
  end

  local sep = ffi.os == "Windows" and "\\" or "/"
  local tried = {}
  local function attempt(name)
    if tried[name] then return nil end
    tried[name] = true
    local ok, lib = pcall(ffi.load, name)
    if ok and lib then return lib, name end
  end

  for _, name in ipairs(names) do
    local lib, label = attempt(name)
    if lib then return lib, label end
    for _, base in ipairs(bases) do
      if type(base) == "string" and base ~= "" then
        local lib2, label2 = attempt(base .. sep .. name)
        if lib2 then return lib2, label2 end
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

    typedef struct SDL_SysWMEvent {
      uint32_t type;
      uint32_t timestamp;
      void *msg;
    } SDL_SysWMEvent;

    typedef union SDL_Event {
      uint32_t type;
      SDL_WindowEvent window;
      SDL_SysWMEvent syswm;
      uint8_t padding[128];
    } SDL_Event;

    typedef struct SDL_version {
      uint8_t major;
      uint8_t minor;
      uint8_t patch;
    } SDL_version;

    /* Enough of SDL_SysWMinfo for cocoa.window / win.window (first union ptr). */
    typedef struct SDL_SysWMinfo {
      SDL_version version;
      uint8_t _pad;
      int32_t subsystem;
      void *native_window;
      void *native_extra1;
      void *native_extra2;
      uint8_t _tail[64];
    } SDL_SysWMinfo;

    typedef struct SDL_Rect { int x, y, w, h; } SDL_Rect;

    SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags);
    void SDL_DestroyWindow(SDL_Window *window);
    uint32_t SDL_GetWindowID(SDL_Window *window);
    void SDL_GetWindowSize(SDL_Window *window, int *w, int *h);
    void SDL_GetWindowPosition(SDL_Window *window, int *x, int *y);
    uint32_t SDL_GetWindowFlags(SDL_Window *window);
    void SDL_SetWindowSize(SDL_Window *window, int w, int h);
    void SDL_SetWindowMinimumSize(SDL_Window *window, int min_w, int min_h);
    void SDL_GetVersion(SDL_version *ver);
    int SDL_GetWindowWMInfo(SDL_Window *window, SDL_SysWMinfo *info);

    SDL_Renderer *SDL_CreateRenderer(SDL_Window *window, int index, uint32_t flags);
    void SDL_DestroyRenderer(SDL_Renderer *renderer);
    int SDL_SetRenderDrawColor(SDL_Renderer *renderer, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
    int SDL_RenderClear(SDL_Renderer *renderer);
    int SDL_RenderCopy(SDL_Renderer *renderer, SDL_Texture *texture, const void *srcrect, const void *dstrect);
    void SDL_RenderPresent(SDL_Renderer *renderer);

    SDL_Texture *SDL_CreateTexture(SDL_Renderer *renderer, uint32_t format, int access, int w, int h);
    void SDL_DestroyTexture(SDL_Texture *texture);
    int SDL_UpdateTexture(SDL_Texture *texture, const void *rect, const void *pixels, int pitch);
    int SDL_SetTextureScaleMode(SDL_Texture *texture, int scaleMode);

    void SDL_PumpEvents(void);
    int SDL_PeepEvents(SDL_Event *events, int numevents, int action, uint32_t minType, uint32_t maxType);
    int SDL_PushEvent(SDL_Event *event);
    uint8_t SDL_EventState(uint32_t type, int state);
    uint32_t SDL_GetGlobalMouseState(int *x, int *y);
    uint32_t SDL_GetMouseState(int *x, int *y);
    SDL_Window *SDL_GetMouseFocus(void);
    const char *SDL_GetError(void);
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
  hwnd = nil,
  bg = 0x0F380F,
  touches = {},
  prevButtons = 0,
  pointerDown = false,
  userClosed = false,
  aspectLock = false,
  nativeAspect = false,
  frameW = FRAME_W,
  frameH = FRAME_H,
  log = nil,
}

local SDL_WINDOWPOS_CENTERED = 0x2FFF0000
local SDL_WINDOW_RESIZABLE = 0x00000020
local SDL_WINDOW_ALLOW_HIGHDPI = 0x00002000
local SDL_RENDERER_SOFTWARE = 0x00000001
local SDL_RENDERER_ACCELERATED = 0x00000002
local SDL_RENDERER_PRESENTVSYNC = 0x00000004
local SDL_PIXELFORMAT_RGBA32 = 0x16762004
local SDL_TEXTUREACCESS_STREAMING = 1
local SDL_ScaleModeNearest = 0
local SDL_WINDOWEVENT = 0x200
local SDL_SYSWMEVENT = 0x201
local SDL_GETEVENT = 2
local SDL_ENABLE = 1
local WM_SIZING = 0x0214
local WMSZ_LEFT = 1
local WMSZ_RIGHT = 2
local WMSZ_TOP = 3
local WMSZ_TOPLEFT = 4
local WMSZ_TOPRIGHT = 5
local WMSZ_BOTTOM = 6
local WMSZ_BOTTOMLEFT = 7
local WMSZ_BOTTOMRIGHT = 8

-- Linux/X11 SysWMinfo layout differs enough that an incomplete FFI cdef
-- writing through SDL_GetWindowWMInfo can corrupt the heap. Only call it
-- on platforms where we actually need the native handle.
local function wantsNativeWMInfo(ffi)
  return ffi.os == "OSX" or ffi.os == "Windows"
end

-- A second accelerated GL/Vulkan SDL_Renderer fights LÖVE's GL context on
-- Linux (especially Wayland / some NVIDIA drivers). Software is slower but
-- process-safe for a tiny 160×144 companion blit.
local function preferSoftwareRenderer(ffi)
  return ffi.os ~= "OSX" and ffi.os ~= "Windows"
end

local function log(fmt, ...)
  if state.log then state.log:info(fmt, ...) end
end

local function warn(fmt, ...)
  if state.log then state.log:warn(fmt, ...) end
end

local function enqueueTouch(event)
  if #state.touches >= MAX_TOUCHES then
    state.touches = { "cancel,0,0" }
  end
  state.touches[#state.touches + 1] = event
end

local function destroyWindow()
  local sdl = state.sdl
  if not sdl then
    state.window, state.renderer, state.texture, state.hwnd = nil, nil, nil, nil
    state.windowId = 0
    return
  end
  if state.texture ~= nil then sdl.SDL_DestroyTexture(state.texture) end
  if state.renderer ~= nil then sdl.SDL_DestroyRenderer(state.renderer) end
  if state.window ~= nil then sdl.SDL_DestroyWindow(state.window) end
  state.texture, state.renderer, state.window, state.hwnd = nil, nil, nil, nil
  state.windowId = 0
  state.pointerDown = false
  state.prevButtons = 0
  state.nativeAspect = false
end

------------------------------------------------------------------------
-- Native aspect-ratio locks
------------------------------------------------------------------------

local function nativeWindowHandle(window)
  local sdl, ffi = state.sdl, state.ffi
  if not (sdl and sdl.SDL_GetWindowWMInfo) then return nil, nil end
  if not wantsNativeWMInfo(ffi) then return nil, nil end
  local info = ffi.new("SDL_SysWMinfo")
  if sdl.SDL_GetVersion then
    sdl.SDL_GetVersion(info.version)
  else
    info.version.major, info.version.minor, info.version.patch = 2, 0, 0
  end
  local ok, result = pcall(function()
    return sdl.SDL_GetWindowWMInfo(window, info)
  end)
  if not ok then return nil, nil end
  -- Some builds return SDL_bool; accept either non-zero / true.
  if result == 0 or result == false then return nil, nil end
  return info.native_window, tonumber(info.subsystem)
end

local function lockAspectCocoa(nswindow)
  local ffi = state.ffi
  local ok, err = pcall(function()
    local objc = ffi.load("/usr/lib/libobjc.A.dylib")
    pcall(ffi.cdef, [[
      typedef struct objc_object *id;
      typedef struct objc_selector *SEL;
      SEL sel_registerName(const char *str);
      id objc_msgSend(id self, SEL op, ...);
      typedef struct { double width; double height; } CGSize;
    ]])
    local sendSize = ffi.cast(
      "id (*)(id, SEL, CGSize)",
      objc.objc_msgSend)
    local win = ffi.cast("id", nswindow)
    local aspect = ffi.new("CGSize", { FRAME_W, FRAME_H })
    local minSize = ffi.new("CGSize", { FRAME_W, FRAME_H })
    sendSize(win, objc.sel_registerName("setContentAspectRatio:"), aspect)
    sendSize(win, objc.sel_registerName("setContentMinSize:"), minSize)
  end)
  if ok then
    state.nativeAspect = true
    log("macOS contentAspectRatio locked to %dx%d", FRAME_W, FRAME_H)
    return true
  end
  warn("macOS aspect lock failed: %s", tostring(err))
  return false
end

local function applyWinSizing(rect, edge)
  local ffi = state.ffi
  -- RECT { LONG left, top, right, bottom }
  local left, top = tonumber(rect.left), tonumber(rect.top)
  local right, bottom = tonumber(rect.right), tonumber(rect.bottom)
  local w = right - left
  local h = bottom - top
  if w < FRAME_W then w = FRAME_W end
  if h < FRAME_H then h = FRAME_H end

  local edgeN = tonumber(edge) or 0
  local widthDriven = (edgeN == WMSZ_LEFT or edgeN == WMSZ_RIGHT
    or edgeN == WMSZ_TOPLEFT or edgeN == WMSZ_TOPRIGHT
    or edgeN == WMSZ_BOTTOMLEFT or edgeN == WMSZ_BOTTOMRIGHT)
  -- Prefer the axis the user is primarily dragging.
  if edgeN == WMSZ_TOP or edgeN == WMSZ_BOTTOM then
    widthDriven = false
  elseif edgeN == WMSZ_LEFT or edgeN == WMSZ_RIGHT then
    widthDriven = true
  else
    widthDriven = (w / FRAME_W) >= (h / FRAME_H)
  end

  local nw, nh
  if widthDriven then
    nw = w
    nh = math.max(FRAME_H, math.floor(nw * FRAME_H / FRAME_W + 0.5))
  else
    nh = h
    nw = math.max(FRAME_W, math.floor(nh * FRAME_W / FRAME_H + 0.5))
  end

  if edgeN == WMSZ_LEFT or edgeN == WMSZ_TOPLEFT or edgeN == WMSZ_BOTTOMLEFT then
    rect.left = right - nw
  else
    rect.right = left + nw
  end
  if edgeN == WMSZ_TOP or edgeN == WMSZ_TOPLEFT or edgeN == WMSZ_TOPRIGHT then
    rect.top = bottom - nh
  else
    rect.bottom = top + nh
  end
end

local function enableWindowsSizingHook()
  local sdl, ffi = state.sdl, state.ffi
  if ffi.os ~= "Windows" or not sdl.SDL_EventState then return end
  pcall(function()
    ffi.cdef[[
      typedef struct { long left, top, right, bottom; } RECT;
      typedef struct SDL_SysWMmsg_Win {
        SDL_version version;
        int subsystem;
        void *hwnd;
        unsigned int msg;
        uint64_t wParam;
        int64_t lParam;
      } SDL_SysWMmsg_Win;
    ]]
  end)
  sdl.SDL_EventState(SDL_SYSWMEVENT, SDL_ENABLE)
  state.nativeAspect = true
  log("Windows WM_SIZING aspect hook enabled")
end

local function lockNativeAspect(window)
  local ffi = state.ffi
  if not wantsNativeWMInfo(ffi) then
    -- Linux: per-frame SetWindowSize fallback only (see enforceAspect).
    return false
  end
  local handle = nativeWindowHandle(window)
  if not handle or handle == nil then
    warn("SDL_GetWindowWMInfo unavailable; using per-frame aspect fallback")
    return false
  end
  if ffi.os == "OSX" then
    return lockAspectCocoa(handle)
  elseif ffi.os == "Windows" then
    state.hwnd = handle
    enableWindowsSizingHook()
    return true
  end
  return false
end

------------------------------------------------------------------------
-- Window lifecycle
------------------------------------------------------------------------

local function windowSize()
  local sdl, ffi = state.sdl, state.ffi
  local w = ffi.new("int[1]")
  local h = ffi.new("int[1]")
  sdl.SDL_GetWindowSize(state.window, w, h)
  return tonumber(w[0]), tonumber(h[0])
end

local function enforceAspect()
  local sdl = state.sdl
  if not sdl or state.window == nil or state.aspectLock then return end
  local cw, ch = windowSize()
  local nw, nh = Bridge.constrainAspect(cw, ch, FRAME_W, FRAME_H)
  if nw == cw and nh == ch then return end
  state.aspectLock = true
  sdl.SDL_SetWindowSize(state.window, nw, nh)
  state.aspectLock = false
end

local function createCompanionRenderer(sdl, ffi, window)
  local attempts
  if preferSoftwareRenderer(ffi) then
    attempts = {
      SDL_RENDERER_SOFTWARE,
      SDL_RENDERER_SOFTWARE + SDL_RENDERER_PRESENTVSYNC,
      SDL_RENDERER_ACCELERATED,
      0,
    }
  else
    attempts = {
      SDL_RENDERER_ACCELERATED + SDL_RENDERER_PRESENTVSYNC,
      SDL_RENDERER_ACCELERATED,
      SDL_RENDERER_SOFTWARE,
      0,
    }
  end
  for _, flags in ipairs(attempts) do
    local renderer = sdl.SDL_CreateRenderer(window, -1, flags)
    if renderer ~= nil then
      return renderer, flags
    end
  end
  return nil, nil
end

local function ensureWindow()
  if state.window ~= nil then return true end
  if not state.usable or not state.sdl then return false end
  if state.userClosed then return false end

  local sdl, ffi = state.sdl, state.ffi
  local w = FRAME_W * DEFAULT_SCALE
  local h = FRAME_H * DEFAULT_SCALE
  -- High-DPI flag is useful on Cocoa/Win; on Linux it can interact badly
  -- with compositor scaling when a second window is created via FFI.
  local flags = SDL_WINDOW_RESIZABLE
  if ffi.os == "OSX" or ffi.os == "Windows" then
    flags = flags + SDL_WINDOW_ALLOW_HIGHDPI
  end
  local window = sdl.SDL_CreateWindow(
    "Kanto Gear",
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    w, h,
    flags)
  if window == nil then
    warn("SDL_CreateWindow failed: %s", tostring(sdl.SDL_GetError()))
    return false
  end

  local renderer, rflags = createCompanionRenderer(sdl, ffi, window)
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
  pcall(function() sdl.SDL_SetTextureScaleMode(texture, SDL_ScaleModeNearest) end)
  pcall(function() sdl.SDL_SetWindowMinimumSize(window, FRAME_W, FRAME_H) end)

  state.window = window
  state.renderer = renderer
  state.texture = texture
  state.windowId = tonumber(sdl.SDL_GetWindowID(window)) or 0
  state.frameW, state.frameH = FRAME_W, FRAME_H
  lockNativeAspect(window)
  -- Immediate snap in case the OS ignored the initial size.
  enforceAspect()
  log("companion window opened id=%s nativeAspect=%s rendererFlags=%s",
    tostring(state.windowId), tostring(state.nativeAspect), tostring(rflags))
  return true
end

local function mainWindowOpen()
  local love = rawget(_G, "love")
  if not (love and love.window) then return true end
  if love.window.isOpen then
    local ok, open = pcall(love.window.isOpen)
    if ok then return open ~= false end
  end
  return true
end

local function handleSysWM(ev)
  if state.ffi.os ~= "Windows" or not state.window then return end
  local ffi = state.ffi
  local msg = ev.syswm.msg
  if msg == nil then return end
  local ok, wm = pcall(function()
    return ffi.cast("SDL_SysWMmsg_Win*", msg)
  end)
  if not ok or wm == nil then return end
  if tonumber(wm.msg) ~= WM_SIZING then return end
  if state.hwnd ~= nil and wm.hwnd ~= nil and wm.hwnd ~= state.hwnd then
    return
  end
  local rect = ffi.cast("RECT*", wm.lParam)
  if rect ~= nil then
    applyWinSizing(rect, wm.wParam)
  end
end

local function drainWindowEvents()
  local sdl, ffi = state.sdl, state.ffi
  if not sdl or state.window == nil then return end
  sdl.SDL_PumpEvents()

  -- Windows live-resize hook (WM_SIZING).
  if ffi.os == "Windows" then
    local sys = ffi.new("SDL_Event[16]")
    local n = sdl.SDL_PeepEvents(sys, 16, SDL_GETEVENT, SDL_SYSWMEVENT, SDL_SYSWMEVENT)
    if n > 0 then
      for i = 0, n - 1 do
        handleSysWM(sys[i])
        sdl.SDL_PushEvent(sys[i])
      end
    end
  end

  local events = ffi.new("SDL_Event[32]")
  local n = sdl.SDL_PeepEvents(events, 32, SDL_GETEVENT, SDL_WINDOWEVENT, SDL_WINDOWEVENT)
  if n < 0 then return end
  for i = 0, n - 1 do
    local ev = events[i]
    local kind = ev.window.event
    if ev.window.windowID == state.windowId then
      if kind == 14 then -- CLOSE
        log("companion window closed by user")
        state.userClosed = true
        destroyWindow()
        enqueueTouch("cancel,0,0")
      elseif kind == 5 or kind == 6 then -- RESIZED / SIZE_CHANGED
        enforceAspect()
      end
    else
      if kind == 14 then
        log("host window closed; closing companion")
        destroyWindow()
      end
      sdl.SDL_PushEvent(ev)
    end
  end
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
  if not mainWindowOpen() then
    destroyWindow()
    return false
  end
  if state.userClosed then
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

  local okEnsure, ensured = pcall(ensureWindow)
  if not okEnsure then
    warn("companion ensureWindow error: %s", tostring(ensured))
    destroyWindow()
    return false
  end
  if not ensured then return false end

  -- LÖVE eats most WINDOWEVENTs for foreign windows, so never rely on them
  -- alone: correct the OS window size every presented frame.
  pcall(enforceAspect)

  local okPresent, presentErr = pcall(function()
    if fw ~= state.frameW or fh ~= state.frameH then
      local sdl = state.sdl
      if state.texture ~= nil then
        sdl.SDL_DestroyTexture(state.texture)
        state.texture = nil
      end
      state.texture = sdl.SDL_CreateTexture(state.renderer, SDL_PIXELFORMAT_RGBA32,
        SDL_TEXTUREACCESS_STREAMING, fw, fh)
      if state.texture == nil then
        error("SDL_CreateTexture failed: " .. tostring(sdl.SDL_GetError()))
      end
      pcall(function()
        sdl.SDL_SetTextureScaleMode(state.texture, SDL_ScaleModeNearest)
      end)
      state.frameW, state.frameH = fw, fh
    end

    state.bg = backgroundColor or state.bg
    local ptr = imageData:getFFIPointer()
    if state.sdl.SDL_UpdateTexture(state.texture, nil, ptr, fw * 4) ~= 0 then
      error("SDL_UpdateTexture failed: " .. tostring(state.sdl.SDL_GetError()))
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
  end)

  if not okPresent then
    warn("companion present error: %s", tostring(presentErr))
    destroyWindow()
    return false
  end

  pcall(drainWindowEvents)
  -- One more pass after events (macOS often applies the drag size at end).
  if state.window ~= nil then pcall(enforceAspect) end
  return state.window ~= nil
end

local function hasSecondaryDisplay()
  return state.usable == true
end

local function pollSecondaryDisplayTouch()
  if not state.usable then return nil end
  if not mainWindowOpen() then
    destroyWindow()
    return nil
  end
  drainWindowEvents()
  if state.window ~= nil then
    enforceAspect()
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
-- Canvas readback polyfill
------------------------------------------------------------------------

local function installCanvasReadback(canvas)
  if not canvas or canvas.requestImageData then return canvas end
  local pending, pendingData = false, nil
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
    log("sdl cdef note: %s", tostring(defErr))
  end

  local sdl, sdlName = tryLoadSDL(ffi)
  if not sdl then
    state.reason = "SDL2 library not found"
    warn("desktop bridge inactive: %s", state.reason)
    return false
  end
  if not pcall(function() return sdl.SDL_CreateWindow end) then
    state.reason = "SDL_CreateWindow missing"
    warn("desktop bridge inactive: %s", state.reason)
    return false
  end

  state.ffi, state.sdl, state.usable = ffi, sdl, true
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
      local prevQuit = runtime.quit
      runtime.quit = function(...)
        destroyWindow()
        if type(prevQuit) == "function" then return prevQuit(...) end
      end
    end)
    pcall(function()
      if not (runtime.handlers and type(runtime.handlers) == "table") then return end
      local prev = runtime.handlers.quit
      runtime.handlers.quit = function(...)
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

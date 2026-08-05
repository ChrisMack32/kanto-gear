-- Desktop secondary-display bridge for stock Gen1Recomp (Windows / macOS /
-- Linux). Polyfills the Android love.system secondary-display API with a
-- second window.
--
-- Windows / macOS: second SDL2 window (native aspect hooks + GL context
-- restore so LÖVE keeps its MakeCurrent state).
-- Linux: pure X11 companion window. A second SDL window next to LÖVE's GL
-- context hard-crashes on many Linux setups even with a software renderer.

local Bridge = {}

local WIDTH, HEIGHT = 160, 144
local DEFAULT_SCALE = 3
local MAX_TOUCHES = 64
local FRAME_W, FRAME_H = WIDTH, HEIGHT
local ASPECT = FRAME_W / FRAME_H -- 10/9
local DEBUG_LOG = "/tmp/kanto-gear-bridge.log"

------------------------------------------------------------------------
-- Pure helpers (also used by unit tests)
------------------------------------------------------------------------

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

-- Like constrainAspect, but prefers the axis that changed more since the last
-- locked size. Needed during live window-manager drags where both width and
-- height jitter every ConfigureNotify.
function Bridge.constrainAspectDrag(w, h, prevW, prevH, fw, fh)
  fw = fw or FRAME_W
  fh = fh or FRAME_H
  w = math.max(1, math.floor(tonumber(w) or fw))
  h = math.max(1, math.floor(tonumber(h) or fh))
  prevW = math.max(1, math.floor(tonumber(prevW) or w))
  prevH = math.max(1, math.floor(tonumber(prevH) or h))
  local dw = math.abs(w - prevW)
  local dh = math.abs(h - prevH)
  local widthDriven
  if dw == 0 and dh == 0 then
    widthDriven = (w / fw) >= (h / fh)
  else
    widthDriven = dw >= dh
  end
  if widthDriven then
    w = math.max(fw, w)
    h = math.max(fh, math.floor(w * fh / fw + 0.5))
  else
    h = math.max(fh, h)
    w = math.max(fw, math.floor(h * fw / fh + 0.5))
  end
  return w, h, widthDriven
end

-- Largest fw:fh window that fits inside maxW×maxH. Used when a drag would
-- otherwise ask for a taller-than-screen 160:144 size on a 16:9 monitor.
-- Oversized proposals snap to an integer multiple of the GB frame so the
-- ratio stays exact (avoids pillarbox bars from a WM-clamped 16:9 size).
function Bridge.clampAspectToMax(w, h, maxW, maxH, fw, fh)
  fw = fw or FRAME_W
  fh = fh or FRAME_H
  w = math.max(fw, math.floor(tonumber(w) or fw))
  h = math.max(fh, math.floor(tonumber(h) or fh))
  maxW = math.max(fw, math.floor(tonumber(maxW) or w))
  maxH = math.max(fh, math.floor(tonumber(maxH) or h))
  if w <= maxW and h <= maxH then
    return w, h
  end
  local iscale = math.max(1, math.floor(math.min(maxW / fw, maxH / fh)))
  return fw * iscale, fh * iscale
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
-- Runtime state
------------------------------------------------------------------------

local state = {
  installed = false,
  usable = false,
  reason = nil,
  backend = nil, -- "x11" | "sdl"
  ffi = nil,
  sdl = nil,
  x11 = nil,
  window = nil,
  renderer = nil,
  texture = nil,
  windowId = 0,
  hwnd = nil,
  -- X11
  xDisplay = nil,
  xWindow = nil,
  xScreen = 0,
  xGc = nil,
  xVisual = nil,
  xDepth = 24,
  xImage = nil,
  xPixels = nil,
  xPixW = 0,
  xPixH = 0,
  xWmDelete = nil,
  xinerama = nil,
  xWinW = 0,
  xWinH = 0,
  needsRedraw = false,
  aspectTargetW = 0,
  aspectTargetH = 0,
  lastLockedW = 0,
  lastLockedH = 0,
  xExpanded = false,
  xHandlingMax = false, -- re-entrancy guard for maximize → max-fit
  pendingAspectSnap = false, -- after unmaximize, keep absolute snapping until locked
  xAtomNetWmState = nil,
  xAtomMaxHorz = nil,
  xAtomMaxVert = nil,
  xAtomFullscreen = nil,
  bg = 0x0F380F,
  touches = {},
  prevButtons = 0,
  pointerDown = false,
  userClosed = false,
  aspectLock = false,
  nativeAspect = false,
  frameW = FRAME_W,
  frameH = FRAME_H,
  pinImage = nil,
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

-- X11 event / input masks
local X_KeyPressMask = 1
local X_ButtonPressMask = 4
local X_ButtonReleaseMask = 8
local X_ExposureMask = 32768
local X_StructureNotifyMask = 131072
local X_Expose = 12
local X_ClientMessage = 33
local X_DestroyNotify = 17
local X_ConfigureNotify = 22
local X_ButtonPress = 4
local X_ButtonRelease = 5
local X_ZPixmap = 2
local X_PMinSize = 16
local X_PAspect = 256
local X_PBaseSize = 512
local X_CWX = 1
local X_CWY = 2
local X_CWWidth = 4
local X_CWHeight = 8
local X_SubstructureNotifyMask = 524288
local X_SubstructureRedirectMask = 1048576
local X_NET_WM_STATE_REMOVE = 0

local function breadcrumb(msg)
  pcall(function()
    local f = io.open(DEBUG_LOG, "a")
    if not f then return end
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), tostring(msg), "\n")
    f:close()
  end)
end

local function log(fmt, ...)
  local msg = string.format(fmt, ...)
  breadcrumb(msg)
  if state.log then state.log:info("%s", msg) end
end

local function warn(fmt, ...)
  local msg = string.format(fmt, ...)
  breadcrumb("WARN " .. msg)
  if state.log then state.log:warn("%s", msg) end
end

local function enqueueTouch(event)
  if #state.touches >= MAX_TOUCHES then
    state.touches = { "cancel,0,0" }
  end
  state.touches[#state.touches + 1] = event
end

local function wantsNativeWMInfo(ffi)
  return ffi.os == "OSX" or ffi.os == "Windows"
end

------------------------------------------------------------------------
-- SDL loader
------------------------------------------------------------------------

local function findMappedSDL(ffi)
  if ffi.os == "Windows" then return nil end
  local f = io.open("/proc/self/maps", "r")
  if not f then return nil end
  local best, bestScore = nil, -1
  for line in f:lines() do
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
  if mapped then names[#names + 1] = mapped end
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
    typedef void *SDL_GLContext;

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

    SDL_Window *SDL_GL_GetCurrentWindow(void);
    SDL_GLContext SDL_GL_GetCurrentContext(void);
    int SDL_GL_MakeCurrent(SDL_Window *window, SDL_GLContext context);

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

-- Run fn while preserving LÖVE's current OpenGL context. Creating / presenting
-- a second SDL window can steal MakeCurrent on Linux and crash the host.
local function withHostGL(fn)
  local sdl = state.sdl
  local win, ctx
  if sdl and sdl.SDL_GL_GetCurrentWindow and sdl.SDL_GL_GetCurrentContext then
    win = sdl.SDL_GL_GetCurrentWindow()
    ctx = sdl.SDL_GL_GetCurrentContext()
  end
  local ok, a, b, c = pcall(fn)
  if sdl and win ~= nil and ctx ~= nil and sdl.SDL_GL_MakeCurrent then
    pcall(function() sdl.SDL_GL_MakeCurrent(win, ctx) end)
  end
  if not ok then error(a) end
  return a, b, c
end

------------------------------------------------------------------------
-- X11 Linux companion (avoids a second SDL window entirely)
------------------------------------------------------------------------

local function defineX11(ffi)
  ffi.cdef[[
    typedef struct _XDisplay Display;
    typedef unsigned long XID;
    typedef XID Window;
    typedef XID Drawable;
    typedef XID Colormap;
    typedef XID Atom;
    typedef XID Time;
    typedef unsigned long VisualID;
    typedef int BoolStatus;
    typedef struct { int x, y; } XPointPair;

    typedef struct {
      XID visualid;
      int _pad_class;
      unsigned long red_mask, green_mask, blue_mask;
      int bits_per_rgb, map_entries;
    } VisualLite;

    typedef struct {
      long flags;
      int x, y;
      int width, height;
      int min_width, min_height;
      int max_width, max_height;
      int width_inc, height_inc;
      XPointPair min_aspect;
      XPointPair max_aspect;
      int base_width, base_height;
      int win_gravity;
    } XSizeHints;

    typedef struct {
      int type;
      unsigned long serial;
      int send_event;
      Display *display;
      Window window;
      Window root;
      Window subwindow;
      Time time;
      int x, y;
      int x_root, y_root;
      unsigned int state;
      unsigned int button;
      int same_screen;
    } XButtonEvent;

    typedef struct {
      int type;
      unsigned long serial;
      int send_event;
      Display *display;
      Window event;
      Window window;
      int x, y;
      int width, height;
      int border_width;
      Window above;
      int override_redirect;
    } XConfigureEvent;

    typedef struct {
      int type;
      unsigned long serial;
      int send_event;
      Display *display;
      Window window;
      Atom message_type;
      int format;
      long data_l[5];
    } XClientMessageEvent;

    typedef union {
      int type;
      XButtonEvent xbutton;
      XConfigureEvent xconfigure;
      XClientMessageEvent xclient;
      char pad[192];
    } XEvent;

    typedef struct _XImage XImage;
    struct _XImage {
      int width, height;
      int xoffset;
      int format;
      char *data;
      int byte_order;
      int bitmap_unit;
      int bitmap_bit_order;
      int bitmap_pad;
      int depth;
      int bytes_per_line;
      int bits_per_pixel;
      unsigned long red_mask;
      unsigned long green_mask;
      unsigned long blue_mask;
      void *obdata;
      struct {
        void *create_image;
        int (*destroy_image)(XImage *image);
        void *get_pixel;
        void *put_pixel;
        void *sub_image;
        void *add_pixel;
      } f;
    };

    int XInitThreads(void);
    Display *XOpenDisplay(const char *name);
    int XCloseDisplay(Display *display);
    int XDefaultScreen(Display *display);
    Window XDefaultRootWindow(Display *display);
    void *XDefaultVisual(Display *display, int screen);
    int XDefaultDepth(Display *display, int screen);
    unsigned long XBlackPixel(Display *display, int screen);
    unsigned long XWhitePixel(Display *display, int screen);
    void *XDefaultGC(Display *display, int screen);
    Window XCreateSimpleWindow(Display *display, Window parent,
      int x, int y, unsigned int width, unsigned int height,
      unsigned int border_width, unsigned long border, unsigned long background);
    int XMapRaised(Display *display, Window w);
    int XStoreName(Display *display, Window w, const char *name);
    int XSelectInput(Display *display, Window w, long event_mask);
    int XPending(Display *display);
    int XNextEvent(Display *display, XEvent *event_return);
    int XFlush(Display *display);
    int XSync(Display *display, int discard);
    int XDestroyWindow(Display *display, Window w);
    int XResizeWindow(Display *display, Window w, unsigned int width, unsigned int height);
    typedef struct {
      int x, y;
      int width, height;
      int border_width;
      Window sibling;
      int stack_mode;
    } XWindowChanges;
    int XConfigureWindow(Display *display, Window w, unsigned int value_mask,
      XWindowChanges *changes);
    int XGetGeometry(Display *display, Drawable d, Window *root,
      int *x, int *y, unsigned int *width, unsigned int *height,
      unsigned int *border_width, unsigned int *depth);
    Atom XInternAtom(Display *display, const char *atom_name, int only_if_exists);
    int XSetWMProtocols(Display *display, Window w, Atom *protocols, int count);
    void XSetWMNormalHints(Display *display, Window w, XSizeHints *hints);
    int XGetWindowProperty(Display *display, Window w, Atom property,
      long long_offset, long long_length, int delete, Atom req_type,
      Atom *actual_type_return, int *actual_format_return,
      unsigned long *nitems_return, unsigned long *bytes_after_return,
      unsigned char **prop_return);
    int XFree(void *data);
    int XDisplayWidth(Display *display, int screen_number);
    int XDisplayHeight(Display *display, int screen_number);
    int XTranslateCoordinates(Display *display, Window src_w, Window dest_w,
      int src_x, int src_y, int *dest_x_return, int *dest_y_return,
      Window *child_return);
    int XMoveResizeWindow(Display *display, Window w, int x, int y,
      unsigned int width, unsigned int height);
    int XSendEvent(Display *display, Window w, int propagate, long event_mask,
      XEvent *event_send);
    XImage *XCreateImage(Display *display, void *visual, unsigned int depth,
      int format, int offset, char *data, unsigned int width, unsigned int height,
      int bitmap_pad, int bytes_per_line);
    int XPutImage(Display *display, Drawable d, void *gc, XImage *image,
      int src_x, int src_y, int dest_x, int dest_y,
      unsigned int width, unsigned int height);
  ]]
end

local function tryLoadX11(ffi)
  local names = {
    "X11", "libX11.so.6", "libX11.so",
    "/usr/lib/x86_64-linux-gnu/libX11.so.6",
    "/usr/lib64/libX11.so.6",
    "/usr/lib/libX11.so.6",
  }
  local mapped
  local f = io.open("/proc/self/maps", "r")
  if f then
    for line in f:lines() do
      local path = line:match("%s(/[^%s]*libX11%.so[^%s]*)")
      if path then mapped = path; break end
    end
    f:close()
  end
  if mapped then table.insert(names, 1, mapped) end
  for _, name in ipairs(names) do
    local ok, lib = pcall(ffi.load, name)
    if ok and lib then return lib, name end
  end
  return nil, nil
end

local function tryLoadXinerama(ffi)
  pcall(function()
    ffi.cdef[[
      typedef struct {
        int screen_number;
        short x_org;
        short y_org;
        short width;
        short height;
      } XineramaScreenInfo;
      int XineramaIsActive(Display *dpy);
      XineramaScreenInfo *XineramaQueryScreens(Display *dpy, int *number);
    ]]
  end)
  local names = {
    "Xinerama", "libXinerama.so.1", "libXinerama.so",
    "/usr/lib/x86_64-linux-gnu/libXinerama.so.1",
    "/usr/lib64/libXinerama.so.1",
  }
  local mapped
  local f = io.open("/proc/self/maps", "r")
  if f then
    for line in f:lines() do
      local path = line:match("%s(/[^%s]*libXinerama%.so[^%s]*)")
      if path then mapped = path; break end
    end
    f:close()
  end
  if mapped then table.insert(names, 1, mapped) end
  for _, name in ipairs(names) do
    local ok, lib = pcall(ffi.load, name)
    if ok and lib then return lib, name end
  end
  return nil, nil
end

local function x11DestroyImage()
  local img = state.xImage
  if img == nil then return end
  -- Detach our Lua-owned buffer so destroy_image does not free it twice.
  img.data = nil
  if img.f.destroy_image ~= nil then
    pcall(function() img.f.destroy_image(img) end)
  end
  state.xImage, state.xPixels = nil, nil
  state.xPixW, state.xPixH = 0, 0
end

local function x11DestroyWindow()
  local x11 = state.x11
  local display = state.xDisplay
  local win = state.xWindow
  state.xWindow = nil
  state.xWinW, state.xWinH = 0, 0
  state.pointerDown = false
  state.prevButtons = 0
  x11DestroyImage()
  if x11 and display ~= nil and win ~= nil then
    pcall(function() x11.XDestroyWindow(display, win) end)
    pcall(function() x11.XFlush(display) end)
  end
end

local function x11CloseDisplay()
  x11DestroyWindow()
  if state.x11 and state.xDisplay ~= nil then
    pcall(function() state.x11.XCloseDisplay(state.xDisplay) end)
  end
  state.xDisplay, state.xGc, state.xVisual, state.xWmDelete = nil, nil, nil, nil
end

local function x11EnsureImage(vw, vh)
  local ffi, x11 = state.ffi, state.x11
  if state.xImage ~= nil and state.xPixW == vw and state.xPixH == vh then
    return true
  end
  x11DestroyImage()
  local nbytes = vw * vh * 4
  local pixels = ffi.new("char[?]", nbytes)
  local image = x11.XCreateImage(
    state.xDisplay, state.xVisual, state.xDepth,
    X_ZPixmap, 0, pixels, vw, vh, 32, vw * 4)
  if image == nil then
    warn("XCreateImage failed")
    return false
  end
  state.xImage = image
  state.xPixels = pixels
  state.xPixW, state.xPixH = vw, vh
  return true
end

local function x11EnsureWindow()
  if state.xWindow ~= nil then return true end
  if not state.usable or state.backend ~= "x11" or not state.x11 then return false end
  if state.userClosed then return false end
  if state.xDisplay == nil then return false end

  local x11 = state.x11
  local w = FRAME_W * DEFAULT_SCALE
  local h = FRAME_H * DEFAULT_SCALE
  local root = x11.XDefaultRootWindow(state.xDisplay)
  local win = x11.XCreateSimpleWindow(
    state.xDisplay, root,
    64, 64, w, h, 1,
    x11.XBlackPixel(state.xDisplay, state.xScreen),
    x11.XBlackPixel(state.xDisplay, state.xScreen))
  if win == nil or win == 0 then
    warn("XCreateSimpleWindow failed")
    return false
  end

  x11.XStoreName(state.xDisplay, win, "Kanto Gear")
  local mask = X_ButtonPressMask + X_ButtonReleaseMask
      + X_ExposureMask + X_StructureNotifyMask
  x11.XSelectInput(state.xDisplay, win, mask)

  local protocols = state.ffi.new("Atom[1]")
  protocols[0] = state.xWmDelete
  x11.XSetWMProtocols(state.xDisplay, win, protocols, 1)

  local hints = state.ffi.new("XSizeHints")
  hints.flags = X_PMinSize + X_PAspect + X_PBaseSize
  hints.min_width, hints.min_height = FRAME_W, FRAME_H
  hints.base_width, hints.base_height = FRAME_W, FRAME_H
  hints.min_aspect.x, hints.min_aspect.y = FRAME_W, FRAME_H
  hints.max_aspect.x, hints.max_aspect.y = FRAME_W, FRAME_H
  x11.XSetWMNormalHints(state.xDisplay, win, hints)

  x11.XMapRaised(state.xDisplay, win)
  x11.XFlush(state.xDisplay)

  state.xWindow = win
  state.xWinW, state.xWinH = w, h
  state.lastLockedW, state.lastLockedH = w, h
  state.frameW, state.frameH = FRAME_W, FRAME_H
  state.nativeAspect = true
  log("x11 companion window opened %dx%d", w, h)
  return true
end

local function x11WindowSize()
  if state.xWindow == nil then return state.xWinW, state.xWinH end
  local ffi, x11 = state.ffi, state.x11
  local root = ffi.new("Window[1]")
  local x = ffi.new("int[1]")
  local y = ffi.new("int[1]")
  local w = ffi.new("unsigned int[1]")
  local h = ffi.new("unsigned int[1]")
  local bw = ffi.new("unsigned int[1]")
  local depth = ffi.new("unsigned int[1]")
  local ok = pcall(function()
    x11.XGetGeometry(state.xDisplay, state.xWindow, root, x, y, w, h, bw, depth)
  end)
  if ok then
    state.xWinW = tonumber(w[0]) or state.xWinW
    state.xWinH = tonumber(h[0]) or state.xWinH
  end
  return state.xWinW, state.xWinH
end

-- Client top-left in root coordinates (handles reparenting WMs).
local function x11WindowRootPos()
  local ffi, x11 = state.ffi, state.x11
  local ww, wh = x11WindowSize()
  if not (x11 and state.xDisplay and state.xWindow and x11.XTranslateCoordinates) then
    return 0, 0, ww, wh
  end
  local root = x11.XDefaultRootWindow(state.xDisplay)
  local dx = ffi.new("int[1]")
  local dy = ffi.new("int[1]")
  local child = ffi.new("Window[1]")
  local ok = pcall(function()
    x11.XTranslateCoordinates(
      state.xDisplay, state.xWindow, root, 0, 0, dx, dy, child)
  end)
  if not ok then return 0, 0, ww, wh end
  return tonumber(dx[0]) or 0, tonumber(dy[0]) or 0, ww, wh
end

local function x11ListMonitors()
  local x11, ffi = state.x11, state.ffi
  local monitors = {}
  local xin = state.xinerama
  if xin and state.xDisplay and xin.XineramaIsActive and xin.XineramaQueryScreens then
    local active = false
    pcall(function() active = xin.XineramaIsActive(state.xDisplay) ~= 0 end)
    if active then
      local n = ffi.new("int[1]")
      local info
      local ok = pcall(function()
        info = xin.XineramaQueryScreens(state.xDisplay, n)
      end)
      local count = ok and tonumber(n[0]) or 0
      if info ~= nil and count > 0 then
        for i = 0, count - 1 do
          monitors[#monitors + 1] = {
            x = tonumber(info[i].x_org) or 0,
            y = tonumber(info[i].y_org) or 0,
            w = tonumber(info[i].width) or 0,
            h = tonumber(info[i].height) or 0,
          }
        end
        pcall(function() x11.XFree(info) end)
      end
    end
  end
  if #monitors == 0 and x11 and x11.XDisplayWidth and state.xDisplay then
    local sw = tonumber(x11.XDisplayWidth(state.xDisplay, state.xScreen)) or 0
    local sh = tonumber(x11.XDisplayHeight(state.xDisplay, state.xScreen)) or 0
    if sw > 0 and sh > 0 then
      monitors[1] = { x = 0, y = 0, w = sw, h = sh }
    end
  end
  return monitors
end

-- Monitor that currently contains the companion window center.
local function x11MonitorForWindow()
  local monitors = x11ListMonitors()
  if #monitors == 0 then
    return { x = 0, y = 0, w = 1920, h = 1080 }
  end
  local wx, wy, ww, wh = x11WindowRootPos()
  local cx = wx + math.floor(ww / 2)
  local cy = wy + math.floor(wh / 2)
  for _, m in ipairs(monitors) do
    if m.w > 0 and m.h > 0
        and cx >= m.x and cx < m.x + m.w
        and cy >= m.y and cy < m.y + m.h then
      return m
    end
  end
  local best, bestDist = monitors[1], nil
  for _, m in ipairs(monitors) do
    local mx = m.x + m.w / 2
    local my = m.y + m.h / 2
    local dist = (cx - mx) * (cx - mx) + (cy - my) * (cy - my)
    if bestDist == nil or dist < bestDist then
      best, bestDist = m, dist
    end
  end
  return best
end

-- Maximized / fullscreen via EWMH.
-- Do not treat "merely large" windows as expanded — on a 16:9 monitor a
-- big manual drag must still snap to the largest fitting 160:144 size.
local function x11IsExpanded(cw, ch)
  local x11, ffi = state.x11, state.ffi
  if not x11 or state.xDisplay == nil or state.xWindow == nil then return false end
  cw = cw or state.xWinW
  ch = ch or state.xWinH

  if state.xAtomNetWmState ~= nil and x11.XGetWindowProperty then
    local actualType = ffi.new("Atom[1]")
    local actualFormat = ffi.new("int[1]")
    local nitems = ffi.new("unsigned long[1]")
    local bytesAfter = ffi.new("unsigned long[1]")
    local prop = ffi.new("unsigned char *[1]")
    local statusOk = pcall(function()
      return x11.XGetWindowProperty(
        state.xDisplay, state.xWindow, state.xAtomNetWmState,
        0, 64, 0, 0, -- AnyPropertyType = 0
        actualType, actualFormat, nitems, bytesAfter, prop)
    end)
    if statusOk and prop[0] ~= nil then
      local count = tonumber(nitems[0]) or 0
      local atoms = ffi.cast("Atom *", prop[0])
      local expanded = false
      for i = 0, count - 1 do
        local a = atoms[i]
        if a == state.xAtomMaxHorz or a == state.xAtomMaxVert
            or a == state.xAtomFullscreen then
          expanded = true
          break
        end
      end
      pcall(function() x11.XFree(prop[0]) end)
      if expanded then return true end
    elseif prop[0] ~= nil then
      pcall(function() x11.XFree(prop[0]) end)
    end
  end

  -- Strict fallback: fills the monitor the window is on (not the whole
  -- virtual desktop spanning every display).
  local mon = x11MonitorForWindow()
  if mon and cw and ch and mon.w > 0 and mon.h > 0
      and cw >= mon.w - 8 and ch >= mon.h - 8 then
    return true
  end
  return false
end

-- Usable client max on the monitor that currently hosts the companion.
local function x11UsableMax()
  local mon = x11MonitorForWindow()
  if not mon or mon.w <= 0 or mon.h <= 0 then return nil, nil, nil end
  local maxW = math.max(FRAME_W, mon.w - 16)
  local maxH = math.max(FRAME_H, mon.h - 64)
  return maxW, maxH, mon
end

local function x11SnapSize(cw, ch, prevW, prevH, absolute)
  local nw, nh
  if absolute then
    nw, nh = Bridge.constrainAspect(cw, ch, FRAME_W, FRAME_H)
  else
    nw, nh = Bridge.constrainAspectDrag(cw, ch, prevW, prevH, FRAME_W, FRAME_H)
  end
  local maxW, maxH = x11UsableMax()
  if maxW and maxH then
    nw, nh = Bridge.clampAspectToMax(nw, nh, maxW, maxH, FRAME_W, FRAME_H)
  end
  return nw, nh
end

-- Mutual recursion: maximize-fit may fall back to apply-size.
local x11ApplySize
local x11ApplyMaxAspectFit

-- Ask the WM to drop maximized / fullscreen so we can apply a real size.
local function x11ClearExpandedState()
  local x11, ffi = state.x11, state.ffi
  if not (x11 and state.xDisplay and state.xWindow and state.xAtomNetWmState) then
    return
  end
  if not x11.XSendEvent then return end
  local root = x11.XDefaultRootWindow(state.xDisplay)
  local function remove(atomA, atomB)
    if not atomA or atomA == 0 then return end
    local ev = ffi.new("XEvent")
    ev.type = X_ClientMessage
    ev.xclient.display = state.xDisplay
    ev.xclient.window = state.xWindow
    ev.xclient.message_type = state.xAtomNetWmState
    ev.xclient.format = 32
    ev.xclient.data_l[0] = X_NET_WM_STATE_REMOVE
    ev.xclient.data_l[1] = atomA
    ev.xclient.data_l[2] = (atomB and atomB ~= 0) and atomB or 0
    ev.xclient.data_l[3] = 1
    ev.xclient.data_l[4] = 0
    x11.XSendEvent(
      state.xDisplay, root, 0,
      X_SubstructureNotifyMask + X_SubstructureRedirectMask, ev)
  end
  remove(state.xAtomMaxVert, state.xAtomMaxHorz)
  remove(state.xAtomFullscreen, 0)
  if x11.XSync then
    x11.XSync(state.xDisplay, 0)
  else
    x11.XFlush(state.xDisplay)
  end
end

-- Maximize / fullscreen on a 16:9 monitor would pillarbox the 160:144 frame
-- (theme filler often reads as red side bars). Turn that into the largest
-- exact 160:144 window that fits, centered on the *same* monitor.
x11ApplyMaxAspectFit = function()
  if state.xWindow == nil or not state.x11 then return state.xWinW, state.xWinH end
  if state.xHandlingMax then return state.xWinW, state.xWinH end
  state.xHandlingMax = true
  state.aspectLock = true
  -- Capture the host monitor BEFORE clearing maximize (geometry still valid).
  local maxW, maxH, mon = x11UsableMax()
  pcall(x11ClearExpandedState)

  local nw, nh
  if maxW and maxH then
    nw, nh = Bridge.clampAspectToMax(maxW + 1, maxH + 1, maxW, maxH, FRAME_W, FRAME_H)
  else
    nw = FRAME_W * DEFAULT_SCALE
    nh = FRAME_H * DEFAULT_SCALE
  end
  mon = mon or { x = 0, y = 0, w = nw, h = nh }

  local x11, ffi = state.x11, state.ffi
  local x = mon.x + math.max(0, math.floor((mon.w - nw) / 2))
  local y = mon.y + math.max(0, math.floor((mon.h - nh) / 2))
  pcall(function()
    if x11.XMoveResizeWindow then
      x11.XMoveResizeWindow(state.xDisplay, state.xWindow, x, y, nw, nh)
    elseif x11.XConfigureWindow then
      local changes = ffi.new("XWindowChanges")
      changes.x, changes.y = x, y
      changes.width, changes.height = nw, nh
      x11.XConfigureWindow(
        state.xDisplay, state.xWindow,
        X_CWX + X_CWY + X_CWWidth + X_CWHeight, changes)
    else
      x11.XResizeWindow(state.xDisplay, state.xWindow, nw, nh)
    end
    if x11.XSync then
      x11.XSync(state.xDisplay, 0)
    else
      x11.XFlush(state.xDisplay)
    end
  end)

  local aw, ah = x11WindowSize()
  state.xWinW, state.xWinH = aw, ah
  if aw ~= nw or ah ~= nh then
    -- WM may have ignored move while still marked maximized; force size.
    x11ApplySize(nw, nh)
  else
    state.lastLockedW, state.lastLockedH = nw, nh
  end
  -- Re-center on the original monitor after the size has actually stuck.
  aw, ah = state.xWinW, state.xWinH
  if aw == nw and ah == nh then
    local cx = mon.x + math.max(0, math.floor((mon.w - nw) / 2))
    local cy = mon.y + math.max(0, math.floor((mon.h - nh) / 2))
    pcall(function()
      if x11.XMoveResizeWindow then
        x11.XMoveResizeWindow(state.xDisplay, state.xWindow, cx, cy, nw, nh)
      end
      if x11.XSync then x11.XSync(state.xDisplay, 0) end
    end)
  end
  state.xExpanded = false
  state.pendingAspectSnap = false
  state.needsRedraw = true
  state.aspectLock = false
  state.xHandlingMax = false
  log("maximize remapped to max 160:144 fit %dx%d on monitor@%d,%d",
    nw, nh, mon.x, mon.y)
  return state.xWinW, state.xWinH
end

x11ApplySize = function(nw, nh)
  local ffi, x11 = state.ffi, state.x11
  if not x11 or state.xWindow == nil then return end
  if not state.xHandlingMax and x11IsExpanded(state.xWinW, state.xWinH) then
    x11ApplyMaxAspectFit()
    return
  end
  local maxW, maxH = x11UsableMax()
  if maxW and maxH then
    nw, nh = Bridge.clampAspectToMax(nw, nh, maxW, maxH, FRAME_W, FRAME_H)
  end
  nw = math.max(FRAME_W, math.floor(nw))
  nh = math.max(FRAME_H, math.floor(nh))
  state.aspectTargetW, state.aspectTargetH = nw, nh
  pcall(function()
    if x11.XConfigureWindow then
      local changes = ffi.new("XWindowChanges")
      changes.width = nw
      changes.height = nh
      x11.XConfigureWindow(state.xDisplay, state.xWindow, X_CWWidth + X_CWHeight, changes)
    else
      x11.XResizeWindow(state.xDisplay, state.xWindow, nw, nh)
    end
    if x11.XSync then
      x11.XSync(state.xDisplay, 0)
    else
      x11.XFlush(state.xDisplay)
    end
  end)
  -- Read back the real size. Updating lastLocked to a size the WM refused
  -- poisons the next drag snap (common right after unmaximize).
  local aw, ah = x11WindowSize()
  state.xWinW, state.xWinH = aw, ah
  if aw == nw and ah == nh then
    state.lastLockedW, state.lastLockedH = nw, nh
    state.pendingAspectSnap = false
  end
  state.needsRedraw = true
end

-- Snap the OS window onto 160:144. Many WMs ignore PAspect during live
-- drag; we keep forcing the locked size from the dominant drag axis.
-- Maximize / fullscreen is remapped to a max-fit 160:144 window.
local function x11EnforceAspect(force)
  if state.xWindow == nil or not state.x11 then return state.xWinW, state.xWinH end
  if state.aspectLock and not force then return state.xWinW, state.xWinH end
  local cw, ch = x11WindowSize()
  if x11IsExpanded(cw, ch) then
    return x11ApplyMaxAspectFit()
  end
  local wasExpanded = state.xExpanded
  if wasExpanded then
    state.pendingAspectSnap = true
  end
  state.xExpanded = false
  local prevW = state.lastLockedW > 0 and state.lastLockedW or cw
  local prevH = state.lastLockedH > 0 and state.lastLockedH or ch
  local nw, nh = x11SnapSize(cw, ch, prevW, prevH, wasExpanded or state.pendingAspectSnap)
  if nw == cw and nh == ch then
    state.lastLockedW, state.lastLockedH = cw, ch
    state.pendingAspectSnap = false
    return cw, ch
  end
  state.aspectLock = true
  x11ApplySize(nw, nh)
  state.aspectLock = false
  return state.xWinW, state.xWinH
end

local function x11Blit(imageData)
  if state.xWindow == nil or imageData == nil then return false end
  if not imageData.getWidth or not imageData.getFFIPointer then return false end

  local fw = imageData:getWidth()
  local fh = imageData:getHeight()
  if fw <= 0 or fh <= 0 then return false end
  state.frameW, state.frameH = fw, fh

  local vw, vh = x11WindowSize()
  if x11IsExpanded(vw, vh) then
    vw, vh = x11ApplyMaxAspectFit()
  else
    vw, vh = x11EnforceAspect(true)
  end
  if vw < 1 or vh < 1 then return false end
  if not x11EnsureImage(vw, vh) then return false end

  local src = state.ffi.cast("const uint8_t *", imageData:getFFIPointer())
  local dst = state.ffi.cast("uint32_t *", state.xPixels)
  -- Black gutters if any letterbox remains; theme filler read as "red bars"
  -- when a 16:9 maximize briefly outran the aspect snap.
  local bgPixel = 0
  local dx, dy, dw, dh = Bridge.letterbox(vw, vh, fw, fh)

  for i = 0, vw * vh - 1 do
    dst[i] = bgPixel
  end
  if dw > 0 and dh > 0 then
    for y = 0, dh - 1 do
      local sy = math.min(fh - 1, math.floor(y * fh / dh))
      local srcRow = sy * fw * 4
      local dstRow = (y + dy) * vw + dx
      for x = 0, dw - 1 do
        local sx = math.min(fw - 1, math.floor(x * fw / dw))
        local si = srcRow + sx * 4
        local r, g, b = src[si], src[si + 1], src[si + 2]
        dst[dstRow + x] = b + g * 0x100 + r * 0x10000
      end
    end
  end

  state.x11.XPutImage(
    state.xDisplay, state.xWindow, state.xGc, state.xImage,
    0, 0, 0, 0, vw, vh)
  state.x11.XFlush(state.xDisplay)
  state.needsRedraw = false
  return true
end

local function x11DrainEvents()
  local ffi, x11 = state.ffi, state.x11
  if not x11 or state.xDisplay == nil or state.xWindow == nil then return end
  local ev = ffi.new("XEvent")
  local cfgW, cfgH = nil, nil
  while x11.XPending(state.xDisplay) > 0 do
    x11.XNextEvent(state.xDisplay, ev)
    local t = ev.type
    if t == X_ClientMessage then
      if ev.xclient.window == state.xWindow then
        local atom = tonumber(ffi.cast("unsigned long", ev.xclient.data_l[0]))
        local del = tonumber(ffi.cast("unsigned long", state.xWmDelete))
        if atom ~= nil and atom == del then
          log("x11 companion closed by user")
          state.userClosed = true
          x11DestroyWindow()
          enqueueTouch("cancel,0,0")
          return
        end
      end
    elseif t == X_DestroyNotify then
      if state.xWindow ~= nil then
        state.userClosed = true
        x11DestroyWindow()
        enqueueTouch("cancel,0,0")
        return
      end
    elseif t == X_ConfigureNotify then
      if ev.xconfigure.window == state.xWindow then
        -- Last ConfigureNotify in the batch wins; correcting mid-batch let
        -- later WM sizes overwrite our lock while the user kept dragging.
        cfgW = tonumber(ev.xconfigure.width) or cfgW
        cfgH = tonumber(ev.xconfigure.height) or cfgH
        state.needsRedraw = true
      end
    elseif t == X_Expose then
      state.needsRedraw = true
    elseif t == X_ButtonPress or t == X_ButtonRelease then
      if ev.xbutton.window == state.xWindow and ev.xbutton.button == 1 then
        local vw, vh = x11WindowSize()
        local x = tonumber(ev.xbutton.x) or 0
        local y = tonumber(ev.xbutton.y) or 0
        local lx, ly = Bridge.logicalPoint(x, y, vw, vh, state.frameW, state.frameH)
        if t == X_ButtonPress then
          if lx then
            state.pointerDown = true
            enqueueTouch(string.format("down,%d,%d", lx, ly))
          end
        else
          if state.pointerDown then
            if not lx then
              lx = math.min(state.frameW - 1, math.max(0, math.floor(x * state.frameW / math.max(1, vw))))
              ly = math.min(state.frameH - 1, math.max(0, math.floor(y * state.frameH / math.max(1, vh))))
            end
            state.pointerDown = false
            enqueueTouch(string.format("up,%d,%d", lx, ly))
          end
        end
      end
    end
  end

  if cfgW and cfgH and state.xWindow ~= nil then
    state.xWinW, state.xWinH = cfgW, cfgH
    if x11IsExpanded(cfgW, cfgH) then
      x11ApplyMaxAspectFit()
    else
      local wasExpanded = state.xExpanded
      if wasExpanded then
        state.pendingAspectSnap = true
      end
      state.xExpanded = false
      local prevW = state.lastLockedW > 0 and state.lastLockedW or cfgW
      local prevH = state.lastLockedH > 0 and state.lastLockedH or cfgH
      local nw, nh = x11SnapSize(cfgW, cfgH, prevW, prevH,
        wasExpanded or state.pendingAspectSnap)
      if nw ~= cfgW or nh ~= cfgH then
        x11ApplySize(nw, nh)
        local guard = 0
        while guard < 16 and x11.XPending(state.xDisplay) > 0 do
          guard = guard + 1
          x11.XNextEvent(state.xDisplay, ev)
          if ev.type == X_ConfigureNotify and ev.xconfigure.window == state.xWindow then
            local aw = tonumber(ev.xconfigure.width) or nw
            local ah = tonumber(ev.xconfigure.height) or nh
            if aw ~= nw or ah ~= nh then
              if not x11IsExpanded(aw, ah) then
                x11ApplySize(nw, nh)
              else
                x11ApplyMaxAspectFit()
              end
            else
              state.xWinW, state.xWinH = aw, ah
              state.lastLockedW, state.lastLockedH = aw, ah
              state.pendingAspectSnap = false
            end
          elseif ev.type == X_Expose then
            state.needsRedraw = true
          elseif ev.type == X_ClientMessage then
            local atom = tonumber(ffi.cast("unsigned long", ev.xclient.data_l[0]))
            local del = tonumber(ffi.cast("unsigned long", state.xWmDelete))
            if atom == del then
              state.userClosed = true
              x11DestroyWindow()
              enqueueTouch("cancel,0,0")
              return
            end
          elseif ev.type == X_DestroyNotify then
            state.userClosed = true
            x11DestroyWindow()
            enqueueTouch("cancel,0,0")
            return
          end
        end
      else
        state.lastLockedW, state.lastLockedH = cfgW, cfgH
        state.pendingAspectSnap = false
      end
    end
  end

  -- Live resize clears the X11 backing store; repaint from the last frame.
  if state.needsRedraw and state.pinImage ~= nil and state.xWindow ~= nil then
    pcall(x11Blit, state.pinImage)
  end
end

local function x11Present(imageData, backgroundColor)
  if not x11EnsureWindow() then return false end
  state.bg = backgroundColor or state.bg
  state.pinImage = imageData

  x11DrainEvents()
  if state.xWindow == nil then return false end

  local ok = x11Blit(imageData)
  state.pinImage = imageData
  return ok
end

local function initX11Backend(ffi)
  breadcrumb("initX11Backend")
  local defined, defErr = pcall(defineX11, ffi)
  if not defined then
    log("x11 cdef note: %s", tostring(defErr))
  end
  local x11, name = tryLoadX11(ffi)
  if not x11 then
    warn("libX11 not found")
    return false
  end
  pcall(function() x11.XInitThreads() end)
  pcall(function()
    ffi.cdef[[
      int XSync(Display *display, int discard);
      typedef struct {
        int x, y;
        int width, height;
        int border_width;
        Window sibling;
        int stack_mode;
      } XWindowChanges;
      int XConfigureWindow(Display *display, Window w, unsigned int value_mask,
        XWindowChanges *changes);
      int XMoveResizeWindow(Display *display, Window w, int x, int y,
        unsigned int width, unsigned int height);
      int XSendEvent(Display *display, Window w, int propagate, long event_mask,
        XEvent *event_send);
      int XTranslateCoordinates(Display *display, Window src_w, Window dest_w,
        int src_x, int src_y, int *dest_x_return, int *dest_y_return,
        Window *child_return);
    ]]
  end)
  local display = x11.XOpenDisplay(nil)
  if display == nil then
    warn("XOpenDisplay failed (Wayland-only session?)")
    return false
  end
  local screen = x11.XDefaultScreen(display)
  state.ffi = ffi
  state.x11 = x11
  state.xDisplay = display
  state.xScreen = screen
  state.xVisual = x11.XDefaultVisual(display, screen)
  state.xDepth = x11.XDefaultDepth(display, screen)
  state.xGc = x11.XDefaultGC(display, screen)
  local xin, xinName = tryLoadXinerama(ffi)
  state.xinerama = xin
  state.xWmDelete = x11.XInternAtom(display, "WM_DELETE_WINDOW", 0)
  state.xAtomNetWmState = x11.XInternAtom(display, "_NET_WM_STATE", 1)
  state.xAtomMaxHorz = x11.XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_HORZ", 1)
  state.xAtomMaxVert = x11.XInternAtom(display, "_NET_WM_STATE_MAXIMIZED_VERT", 1)
  state.xAtomFullscreen = x11.XInternAtom(display, "_NET_WM_STATE_FULLSCREEN", 1)
  -- only_if_exists=1 can return None(0); treat that as unavailable
  if state.xAtomNetWmState == nil or state.xAtomNetWmState == 0 then
    state.xAtomNetWmState = nil
  end
  state.backend = "x11"
  state.usable = true
  log("desktop bridge ready via X11 (%s) depth=%s xinerama=%s monitors=%d",
    tostring(name), tostring(state.xDepth), tostring(xinName), #x11ListMonitors())
  return true
end

------------------------------------------------------------------------
-- SDL companion (Windows / macOS; Linux fallback only)
------------------------------------------------------------------------

local function destroySdlWindow()
  local sdl = state.sdl
  if not sdl then
    state.window, state.renderer, state.texture, state.hwnd = nil, nil, nil, nil
    state.windowId = 0
    return
  end
  withHostGL(function()
    if state.texture ~= nil then sdl.SDL_DestroyTexture(state.texture) end
    if state.renderer ~= nil then sdl.SDL_DestroyRenderer(state.renderer) end
    if state.window ~= nil then sdl.SDL_DestroyWindow(state.window) end
  end)
  state.texture, state.renderer, state.window, state.hwnd = nil, nil, nil, nil
  state.windowId = 0
  state.pointerDown = false
  state.prevButtons = 0
  state.nativeAspect = false
end

local function destroyWindow()
  if state.backend == "x11" then
    x11DestroyWindow()
  else
    destroySdlWindow()
  end
end

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
  local left, top = tonumber(rect.left), tonumber(rect.top)
  local right, bottom = tonumber(rect.right), tonumber(rect.bottom)
  local w = right - left
  local h = bottom - top
  if w < FRAME_W then w = FRAME_W end
  if h < FRAME_H then h = FRAME_H end

  local edgeN = tonumber(edge) or 0
  local widthDriven
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
  if not wantsNativeWMInfo(ffi) then return false end
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
  withHostGL(function()
    sdl.SDL_SetWindowSize(state.window, nw, nh)
  end)
  state.aspectLock = false
end

local function createCompanionRenderer(sdl, window)
  local attempts = {
    SDL_RENDERER_ACCELERATED + SDL_RENDERER_PRESENTVSYNC,
    SDL_RENDERER_ACCELERATED,
    SDL_RENDERER_SOFTWARE,
    0,
  }
  for _, flags in ipairs(attempts) do
    local renderer = sdl.SDL_CreateRenderer(window, -1, flags)
    if renderer ~= nil then
      return renderer, flags
    end
  end
  return nil, nil
end

local function ensureSdlWindow()
  if state.window ~= nil then return true end
  if not state.usable or not state.sdl then return false end
  if state.userClosed then return false end

  return withHostGL(function()
    local sdl, ffi = state.sdl, state.ffi
    local w = FRAME_W * DEFAULT_SCALE
    local h = FRAME_H * DEFAULT_SCALE
    local flags = SDL_WINDOW_RESIZABLE + SDL_WINDOW_ALLOW_HIGHDPI
    local window = sdl.SDL_CreateWindow(
      "Kanto Gear",
      SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
      w, h, flags)
    if window == nil then
      warn("SDL_CreateWindow failed: %s", tostring(sdl.SDL_GetError()))
      return false
    end

    local renderer, rflags = createCompanionRenderer(sdl, window)
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
    enforceAspect()
    log("sdl companion window opened id=%s nativeAspect=%s rendererFlags=%s",
      tostring(state.windowId), tostring(state.nativeAspect), tostring(rflags))
    return true
  end)
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
  -- Do not PumpEvents on Linux fallback; LÖVE owns the queue.
  if ffi.os ~= "Linux" then
    sdl.SDL_PumpEvents()
  end

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
      if kind == 14 then
        log("companion window closed by user")
        state.userClosed = true
        destroyWindow()
        enqueueTouch("cancel,0,0")
      elseif kind == 5 or kind == 6 then
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

local function presentSdl(imageData, backgroundColor)
  local okEnsure, ensured = pcall(ensureSdlWindow)
  if not okEnsure then
    warn("companion ensureWindow error: %s", tostring(ensured))
    destroyWindow()
    return false
  end
  if not ensured then return false end

  pcall(enforceAspect)
  state.pinImage = imageData

  local fw = imageData:getWidth()
  local fh = imageData:getHeight()

  local okPresent, presentErr = pcall(function()
    withHostGL(function()
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
  end)

  if not okPresent then
    warn("companion present error: %s", tostring(presentErr))
    destroyWindow()
    return false
  end

  pcall(drainWindowEvents)
  if state.window ~= nil then pcall(enforceAspect) end
  return state.window ~= nil
end

------------------------------------------------------------------------
-- Shared present / poll API
------------------------------------------------------------------------

local function present(imageData, backgroundColor, _preference)
  breadcrumb("present backend=" .. tostring(state.backend))
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

  if state.backend == "x11" then
    local ok, result = pcall(x11Present, imageData, backgroundColor)
    if not ok then
      warn("x11 present error: %s", tostring(result))
      x11DestroyWindow()
      return false
    end
    return result and state.xWindow ~= nil
  end
  return presentSdl(imageData, backgroundColor)
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
  if state.backend == "x11" then
    if state.xWindow ~= nil then
      x11DrainEvents()
      if state.xWindow ~= nil then
        -- Snap aspect even when the WM silently ignored PAspect / our
        -- mid-drag XResizeWindow (common on Mutter / KWin).
        x11EnforceAspect(false)
        if state.needsRedraw and state.pinImage ~= nil then
          pcall(x11Blit, state.pinImage)
        end
      end
    end
  else
    drainWindowEvents()
    if state.window ~= nil then
      enforceAspect()
      pollMouse()
    end
  end
  if #state.touches == 0 then return nil end
  return table.remove(state.touches, 1)
end

local function closeSecondaryDisplay()
  state.userClosed = true
  destroyWindow()
  state.touches = {}
end

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

local function initSdlBackend(ffi)
  breadcrumb("initSdlBackend os=" .. tostring(ffi.os))
  -- Linux must not use a second SDL window; caller should prefer X11.
  if ffi.os == "Linux" then
    warn("refusing SDL companion backend on Linux (use X11)")
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

  state.ffi, state.sdl = ffi, sdl
  state.backend = "sdl"
  state.usable = true
  log("desktop bridge ready via SDL %s (%s)", tostring(sdlName), tostring(ffi.os))
  return true
end

------------------------------------------------------------------------
-- Public install
------------------------------------------------------------------------

function Bridge.install(mod)
  if state.installed then return state.usable end
  state.installed = true
  state.log = mod and mod.log or nil
  breadcrumb("Bridge.install")

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
  state.ffi = ffi

  local ready = false
  if ffi.os == "Linux" then
    ready = initX11Backend(ffi)
    if not ready then
      state.reason = "X11 companion unavailable"
      warn("desktop bridge inactive on Linux: %s", state.reason)
      return false
    end
  else
    ready = initSdlBackend(ffi)
    if not ready then return false end
  end

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
        if state.backend == "x11" then x11CloseDisplay() end
        if type(prevQuit) == "function" then return prevQuit(...) end
      end
    end)
    pcall(function()
      if not (runtime.handlers and type(runtime.handlers) == "table") then return end
      local prev = runtime.handlers.quit
      runtime.handlers.quit = function(...)
        destroyWindow()
        if state.backend == "x11" then x11CloseDisplay() end
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

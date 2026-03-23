/*
 * main_appkit.mm - Native macOS AppKit host for PyMOL
 *
 * Replaces GLUT-based main.cpp with a native NSApplication + NSOpenGLView.
 * Uses the PyMOL_* embedding API (_PYMOL_LIB mode).
 *
 * Supports two rendering backends:
 *   - OpenGL via NSOpenGLView (PyMOLOpenGLView)
 *   - Metal via MTKView (PyMOLMetalView) — selected at runtime if available
 *
 * Build with: -framework Cocoa -framework OpenGL -framework Metal -framework MetalKit
 * Requires: _PYMOL_LIB, _PYMOL_NO_MAIN, _PYMOL_PRETEND_GLUT
 */

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/OpenGL.h>

#if __has_include(<MetalKit/MetalKit.h>)
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#define PYMOL_HAS_METAL 1
#else
#define PYMOL_HAS_METAL 0
#endif

#include "ov_port.h"
#include "ov_types.h"
#include "PyMOL.h"
#include "PyMOLOptions.h"
#include "os_python.h"
#include "PyMOLGlobals.h"
#include "Cmd.h"
#include "Renderer.h"

#if PYMOL_HAS_METAL
#include "RendererMetal.h"
#endif

// Defined in ImmediateHelper.h — forward-declared here to avoid
// pulling in GLEW which conflicts with the OpenGL framework headers.
void ImmBatch_SetActiveRenderer(pymol::Renderer* r);

// Defined in Cmd.cpp
extern "C" PyObject* PyInit__cmd(void);

// Defined in P.cpp (declared in P.h, but we can't include P.h here
// because it pulls in GLEW which conflicts with the OpenGL framework headers)
extern void PInit(PyMOLGlobals * G, int global_instance);
extern void PUnblock(PyMOLGlobals * G);

// Defined in Ortho.cpp
extern int OrthoButton(PyMOLGlobals * G, int button, int state, int x, int y, int mod);
extern void OrthoDrag(PyMOLGlobals * G, int x, int y, int mod);

// Symbols normally provided by main.cpp (GLUT host).
// The AppKit host uses the PyMOL_* embedding API instead.
int _gScaleFactor = 1;

int MainSavingUnderWhileIdle(void) { return 0; }
PyObject *MainAsPyList(PyMOLGlobals *) { Py_RETURN_NONE; }
int MainFromPyList(PyMOLGlobals *, PyObject *) { return 0; }

// Forward declarations
@class PyMOLOpenGLView;
#if PYMOL_HAS_METAL
@class PyMOLMetalView;
#endif

// Backend preference: 0 = auto (Metal first), 1 = force Metal, 2 = force OpenGL
enum RendererBackend { kBackendAuto = 0, kBackendMetal = 1, kBackendOpenGL = 2 };
static RendererBackend g_requestedBackend = kBackendAuto;

@interface PyMOLAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) NSView *chatContainer;
@property (strong) NSView *commandPanelContainer;
@property (assign) BOOL chatVisible;
@property (assign) BOOL usingMetal;
- (void)toggleChatPanel;
@end

static CPyMOL *pymolInstance = nullptr;
static NSView *glView = nullptr;  // Either PyMOLOpenGLView or PyMOLMetalView

// ---------------------------------------------------------------------------
#pragma mark - Shared input helpers
// ---------------------------------------------------------------------------
// These free functions are called by both PyMOLOpenGLView and PyMOLMetalView
// to avoid duplicating mouse/keyboard event handling.

static int pymolModifiers(NSEvent *event) {
    int mods = 0;
    NSEventModifierFlags flags = [event modifierFlags];
    if (flags & NSEventModifierFlagShift)   mods |= PYMOL_MODIFIER_SHIFT;
    if (flags & NSEventModifierFlagControl) mods |= PYMOL_MODIFIER_CTRL;
    if (flags & NSEventModifierFlagOption)  mods |= PYMOL_MODIFIER_ALT;
    return mods;
}

static NSPoint pymolPoint(NSView *view, NSEvent *event) {
    NSPoint loc = [view convertPoint:[event locationInWindow] fromView:nil];
    loc = [view convertPointToBacking:loc];
    return loc;
}

static void handleMouseButton(NSView *view, NSEvent *event, int button, int state) {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    NSPoint pt = pymolPoint(view, event);
    int mods = pymolModifiers(event);
    OrthoButton(G, button, state, (int)pt.x, (int)pt.y, mods);
}

static void handleMouseDrag(NSView *view, NSEvent *event) {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    NSPoint pt = pymolPoint(view, event);
    int mods = pymolModifiers(event);
    OrthoDrag(G, (int)pt.x, (int)pt.y, mods);
}

static void handleScrollWheel(NSView *view, NSEvent *event) {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    NSPoint pt = pymolPoint(view, event);
    int mods = pymolModifiers(event);
    float dy = [event deltaY];
    if (dy > 0.0f) {
        OrthoButton(G, PYMOL_BUTTON_SCROLL_FORWARD, PYMOL_BUTTON_DOWN,
                    (int)pt.x, (int)pt.y, mods);
    } else if (dy < 0.0f) {
        OrthoButton(G, PYMOL_BUTTON_SCROLL_REVERSE, PYMOL_BUTTON_DOWN,
                    (int)pt.x, (int)pt.y, mods);
    }
}

static void handleKeyDown(NSView *view, NSEvent *event) {
    if (!pymolInstance) return;

    // Handle Cmd+L toggle of the embedded chat panel
    NSEventModifierFlags flags = [event modifierFlags];
    if ((flags & NSEventModifierFlagCommand)
        && !(flags & NSEventModifierFlagShift)
        && !(flags & NSEventModifierFlagControl)
        && [[event charactersIgnoringModifiers] isEqualToString:@"l"]) {
        PyMOLAppDelegate *del = (PyMOLAppDelegate *)[NSApp delegate];
        if ([del respondsToSelector:@selector(toggleChatPanel)]) {
            [del toggleChatPanel];
        }
        return;
    }

    NSPoint pt = pymolPoint(view, event);
    int mods = pymolModifiers(event);
    NSString *chars = [event characters];

    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];
        if (c == NSUpArrowFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_UP, (int)pt.x, (int)pt.y, mods);
        } else if (c == NSDownArrowFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_DOWN, (int)pt.x, (int)pt.y, mods);
        } else if (c == NSLeftArrowFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_LEFT, (int)pt.x, (int)pt.y, mods);
        } else if (c == NSRightArrowFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_RIGHT, (int)pt.x, (int)pt.y, mods);
        } else if (c == NSPageUpFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_PAGE_UP, (int)pt.x, (int)pt.y, mods);
        } else if (c == NSPageDownFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_PAGE_DOWN, (int)pt.x, (int)pt.y, mods);
        } else if (c == NSHomeFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_HOME, (int)pt.x, (int)pt.y, mods);
        } else if (c == NSEndFunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_END, (int)pt.x, (int)pt.y, mods);
        } else if (c >= NSF1FunctionKey && c <= NSF12FunctionKey) {
            PyMOL_Special(pymolInstance, PYMOL_KEY_F1 + (c - NSF1FunctionKey),
                         (int)pt.x, (int)pt.y, mods);
        } else if (c < 256) {
            PyMOL_Key(pymolInstance, (unsigned char)c, (int)pt.x, (int)pt.y, mods);
        }
    }
}

// ---------------------------------------------------------------------------
#pragma mark - PyMOLOpenGLView
// ---------------------------------------------------------------------------

@interface PyMOLOpenGLView : NSOpenGLView {
    NSTimer *_renderTimer;
    BOOL _needsDisplay;
    BOOL _initialized;
}
@end

@implementation PyMOLOpenGLView

- (instancetype)initWithFrame:(NSRect)frame {
    // Request a double-buffered, depth-buffered RGBA context
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAStencilSize, 8,
        NSOpenGLPFAColorSize, 32,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy, // GL 2.1 compat
        NSOpenGLPFAAccelerated,
        NSOpenGLPFANoRecovery,
        0
    };
    NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf) {
        NSLog(@"Failed to create OpenGL pixel format");
        return nil;
    }
    self = [super initWithFrame:frame pixelFormat:pf];
    if (self) {
        _needsDisplay = YES;
        _initialized = NO;

        // Enable Retina/HiDPI rendering
        [self setWantsBestResolutionOpenGLSurface:YES];

        // Enable VSync
        GLint swapInterval = 1;
        [[self openGLContext] setValues:&swapInterval
                           forParameter:NSOpenGLContextParameterSwapInterval];
    }
    return self;
}

- (void)prepareOpenGL {
    [super prepareOpenGL];
    [[self openGLContext] makeCurrentContext];

    // Initialize PyMOL
    CPyMOLOptions *options = PyMOLOptions_New();
    options->show_splash = 1;
    options->internal_gui = 1;
    options->internal_feedback = 1;

    pymolInstance = PyMOL_NewWithOptions(options);
    PyMOLOptions_Free(options);

    // Initialize PyMOL with Python support
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    SingletonPyMOLGlobals = G;
    G->HaveGUI = true;

    // Start C-level subsystems
    PyMOL_Start(pymolInstance);

    // Initialize Python-to-C hooks as global singleton (allocates G->P_inst)
    PInit(G, true);

    // Set PythonInitStage=1 so PyMOL_Idle runs exec_deferred(),
    // which calls cmd.config_mouse() to set up mouse bindings.
    PyMOL_SetPythonInitStage(pymolInstance, 1);

    // Load API keys into Python's os.environ before importing ai_chat.
    // Finder-launched apps don't inherit shell env vars, so we also
    // check ~/.pymol_ai.conf (simple KEY=VALUE format).
    PyRun_SimpleString(
        "import os, os.path\n"
        "_conf = os.path.expanduser('~/.pymol_ai.conf')\n"
        "if os.path.isfile(_conf):\n"
        "    for _line in open(_conf):\n"
        "        _line = _line.strip()\n"
        "        if '=' in _line and not _line.startswith('#'):\n"
        "            _k, _v = _line.split('=', 1)\n"
        "            os.environ[_k.strip()] = _v.strip()\n"
    );

    // Build the native macOS menu bar from Python
    PyRun_SimpleString(
        "from pymol import appkit_menus; appkit_menus.setup_menus(__import__('pymol').cmd)\n"
    );

    // Initialize the AI chat engine and set up the embedded chat UI
    // The chat container NSView (tag=100) was created in applicationDidFinishLaunching.
    // We find it by tag and pass it to ai_chat_ui._setup_embedded().
    PyRun_SimpleString(
        "from pymol import ai_chat; ai_chat._init(__import__('pymol').cmd)\n"
        "import AppKit\n"
        "from pymol import ai_chat_ui\n"
        "for _win in AppKit.NSApp.windows():\n"
        "    if _win.title() == 'PyMOL Viewer':\n"
        "        for _sv in _win.contentView().subviews():\n"
        "            if _sv.identifier() == 'chatContainer':\n"
        "                ai_chat_ui._setup_embedded(_sv)\n"
        "                break\n"
        "        break\n"
    );

    // Initialize the command panel (log, input, buttons) below the GL viewport
    PyRun_SimpleString(
        "import AppKit\n"
        "from pymol import appkit_command_panel\n"
        "for _win in AppKit.NSApp.windows():\n"
        "    if _win.title() == 'PyMOL Viewer':\n"
        "        for _sv in _win.contentView().subviews():\n"
        "            if _sv.identifier() == 'commandPanel':\n"
        "                appkit_command_panel.setup(_sv, __import__('pymol').cmd)\n"
        "                break\n"
        "        break\n"
    );

    // Release the GIL


    // Compute Retina scale factor and set via the setting system
    NSRect pointBounds = [self bounds];
    NSRect pixelBounds = [self convertRectToBacking:pointBounds];
    int scaleFactor = (int)(pixelBounds.size.width / pointBounds.size.width);
    if (scaleFactor < 1) scaleFactor = 1;
    _gScaleFactor = scaleFactor;
    if (scaleFactor > 1) {
        char val[8];
        snprintf(val, sizeof(val), "%d", scaleFactor);
        PyMOL_CmdSet(pymolInstance, "display_scale_factor", val, "", -1, 1, 1);
    }

    // Set swap callback — glView is NSView*, cast to NSOpenGLView for GL path
    PyMOL_SetSwapBuffersFn(pymolInstance, []() {
        if (glView && [glView isKindOfClass:[NSOpenGLView class]]) {
            [[(NSOpenGLView *)glView openGLContext] flushBuffer];
        }
    });

    // Initial reshape — use pixel dimensions for OpenGL
    int w = (int)pixelBounds.size.width;
    int h = (int)pixelBounds.size.height;
    glViewport(0, 0, w, h);
    PyMOL_Reshape(pymolInstance, w, h, 1);

    _initialized = YES;

    // Use an NSTimer for the render loop — this cooperates with the
    // main run loop and allows mouse/keyboard events to be processed.
    // CVDisplayLink's performSelectorOnMainThread floods the run loop.
    _renderTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                    target:self
                                                  selector:@selector(renderFrame)
                                                  userInfo:nil
                                                   repeats:YES];
    // Ensure timer fires during event tracking (mouse drags)
    [[NSRunLoop currentRunLoop] addTimer:_renderTimer forMode:NSEventTrackingRunLoopMode];
}

- (void)renderFrame {
    if (!_initialized || !pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);

    [[self openGLContext] makeCurrentContext];

    // Process idle work (no API lock needed — render timer and mouse events
    // are serialized on the main thread by the NSRunLoop)
    PyMOL_Idle(pymolInstance);

    // Handle pending reshapes — GetReshapeInfo returns point dimensions
    // (divided by DIP2PIXEL), so scale back to pixels for GL and PyMOL_Reshape
    if (PyMOL_GetReshape(pymolInstance)) {
        PyMOLreturn_int_array info = PyMOL_GetReshapeInfo(pymolInstance, 1);
        if (info.array && info.size >= 5) {
            int w = info.array[3] * _gScaleFactor;
            int h = info.array[4] * _gScaleFactor;
            glViewport(0, 0, w, h);
            PyMOL_Reshape(pymolInstance, w, h, 0);
        }
        PyMOL_FreeResultArray(pymolInstance, info.array);
    }

    // Draw if needed
    if (PyMOL_GetRedisplay(pymolInstance, 1)) {
        PyMOL_PushValidContext(pymolInstance);
        PyMOL_Draw(pymolInstance);
        PyMOL_PopValidContext(pymolInstance);
    }

    // Swap if needed (may also be handled by swap callback)
    if (PyMOL_GetSwap(pymolInstance, 1)) {
        [[self openGLContext] flushBuffer];
    }
}

- (void)reshape {
    [super reshape];
    if (!pymolInstance) return;

    [[self openGLContext] makeCurrentContext];
    // Use pixel (backing) dimensions for Retina
    NSRect pixelBounds = [self convertRectToBacking:[self bounds]];
    int w = (int)pixelBounds.size.width;
    int h = (int)pixelBounds.size.height;
    glViewport(0, 0, w, h);
    PyMOL_Reshape(pymolInstance, w, h, 0);
    _needsDisplay = YES;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// Mouse and keyboard — delegate to shared helpers
- (void)mouseDown:(NSEvent *)e {
    int btn = ([e modifierFlags] & NSEventModifierFlagCommand) ? PYMOL_BUTTON_MIDDLE : PYMOL_BUTTON_LEFT;
    handleMouseButton(self, e, btn, PYMOL_BUTTON_DOWN);
}
- (void)mouseUp:(NSEvent *)e        { handleMouseButton(self, e, PYMOL_BUTTON_LEFT, PYMOL_BUTTON_UP); }
- (void)mouseDragged:(NSEvent *)e   { handleMouseDrag(self, e); }
- (void)rightMouseDown:(NSEvent *)e  { handleMouseButton(self, e, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_DOWN); }
- (void)rightMouseUp:(NSEvent *)e    { handleMouseButton(self, e, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_UP); }
- (void)rightMouseDragged:(NSEvent *)e { handleMouseDrag(self, e); }
- (void)otherMouseDown:(NSEvent *)e  { handleMouseButton(self, e, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_DOWN); }
- (void)otherMouseUp:(NSEvent *)e    { handleMouseButton(self, e, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_UP); }
- (void)otherMouseDragged:(NSEvent *)e { handleMouseDrag(self, e); }
- (void)scrollWheel:(NSEvent *)e     { handleScrollWheel(self, e); }
- (void)keyDown:(NSEvent *)e         { handleKeyDown(self, e); }
- (void)flagsChanged:(NSEvent *)event {}

// ---------------------------------------------------------------------------
#pragma mark - Cleanup
// ---------------------------------------------------------------------------

- (void)dealloc {
    if (_renderTimer) {
        [_renderTimer invalidate];
        _renderTimer = nil;
    }
    if (pymolInstance) {
        PyMOL_Stop(pymolInstance);
        PyMOL_Free(pymolInstance);
        pymolInstance = nullptr;
    }
}

@end

// ---------------------------------------------------------------------------
#pragma mark - PyMOLMetalView
// ---------------------------------------------------------------------------
#if PYMOL_HAS_METAL

@interface PyMOLMetalView : MTKView <MTKViewDelegate>
@end

@implementation PyMOLMetalView {
    id<MTLDevice> _metalDevice;
    id<MTLCommandQueue> _commandQueue;
    BOOL _initialized;
}

- (instancetype)initWithFrame:(NSRect)frame {
    _metalDevice = MTLCreateSystemDefaultDevice();
    if (!_metalDevice) return nil;

    self = [super initWithFrame:frame device:_metalDevice];
    if (self) {
        self.delegate = self;
        self.preferredFramesPerSecond = 60;
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        self.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        self.sampleCount = 1;
        _commandQueue = [_metalDevice newCommandQueue];

        // Enable Retina
        self.layer.contentsScale = [[NSScreen mainScreen] backingScaleFactor];

        // Initialize PyMOL
        [self initPyMOL];
    }
    return self;
}

- (void)initPyMOL {
    CPyMOLOptions *options = PyMOLOptions_New();
    options->show_splash = 1;
    options->internal_gui = 1;
    options->internal_feedback = 1;

    pymolInstance = PyMOL_NewWithOptions(options);
    PyMOLOptions_Free(options);

    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    SingletonPyMOLGlobals = G;
    G->HaveGUI = true;

    // Create the Metal renderer and attach it to globals
    G->Renderer = new pymol::RendererMetal(_metalDevice, _commandQueue);

    PyMOL_Start(pymolInstance);
    PInit(G, true);
    PyMOL_SetPythonInitStage(pymolInstance, 1);

    // Load API keys
    PyRun_SimpleString(
        "import os, os.path\n"
        "_conf = os.path.expanduser('~/.pymol_ai.conf')\n"
        "if os.path.isfile(_conf):\n"
        "    for _line in open(_conf):\n"
        "        _line = _line.strip()\n"
        "        if '=' in _line and not _line.startswith('#'):\n"
        "            _k, _v = _line.split('=', 1)\n"
        "            os.environ[_k.strip()] = _v.strip()\n"
    );

    // Build native menu bar
    PyRun_SimpleString(
        "from pymol import appkit_menus; appkit_menus.setup_menus(__import__('pymol').cmd)\n"
    );

    // Initialize AI chat
    PyRun_SimpleString(
        "from pymol import ai_chat; ai_chat._init(__import__('pymol').cmd)\n"
        "import AppKit\n"
        "from pymol import ai_chat_ui\n"
        "for _win in AppKit.NSApp.windows():\n"
        "    if _win.title() == 'PyMOL Viewer':\n"
        "        for _sv in _win.contentView().subviews():\n"
        "            if _sv.identifier() == 'chatContainer':\n"
        "                ai_chat_ui._setup_embedded(_sv)\n"
        "                break\n"
        "        break\n"
    );

    // Initialize command panel
    PyRun_SimpleString(
        "import AppKit\n"
        "from pymol import appkit_command_panel\n"
        "for _win in AppKit.NSApp.windows():\n"
        "    if _win.title() == 'PyMOL Viewer':\n"
        "        for _sv in _win.contentView().subviews():\n"
        "            if _sv.identifier() == 'commandPanel':\n"
        "                appkit_command_panel.setup(_sv, __import__('pymol').cmd)\n"
        "                break\n"
        "        break\n"
    );

    // Compute Retina scale factor
    NSRect pointBounds = [self bounds];
    NSRect pixelBounds = [self convertRectToBacking:pointBounds];
    int scaleFactor = (int)(pixelBounds.size.width / pointBounds.size.width);
    if (scaleFactor < 1) scaleFactor = 1;
    _gScaleFactor = scaleFactor;
    if (scaleFactor > 1) {
        char val[8];
        snprintf(val, sizeof(val), "%d", scaleFactor);
        PyMOL_CmdSet(pymolInstance, "display_scale_factor", val, "", -1, 1, 1);
    }

    // Metal swap is a no-op — MTKView presents drawables automatically
    PyMOL_SetSwapBuffersFn(pymolInstance, []() {});

    // Initial reshape using drawable size (pixels)
    CGSize drawSize = self.drawableSize;
    PyMOL_Reshape(pymolInstance, (int)drawSize.width, (int)drawSize.height, 1);

    _initialized = YES;
}

// MTKViewDelegate — replaces the NSTimer render loop
- (void)drawInMTKView:(MTKView *)view {
    if (!_initialized || !pymolInstance) return;

    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    auto* renderer = static_cast<pymol::RendererMetal*>(G->Renderer);
    if (!renderer) return;

    // Get drawable and pass descriptor for this frame
    id<CAMetalDrawable> drawable = self.currentDrawable;
    MTLRenderPassDescriptor *passDesc = self.currentRenderPassDescriptor;
    if (!drawable || !passDesc) return;

    // Hand the drawable to the renderer and begin the frame
    renderer->setDrawable(drawable, passDesc);

    // Set viewport to match drawable size
    CGSize sz = self.drawableSize;
    renderer->viewport(0, 0, (int)sz.width, (int)sz.height);
    renderer->beginFrame();

    // Process idle work
    PyMOL_Idle(pymolInstance);

    // Handle pending reshapes
    if (PyMOL_GetReshape(pymolInstance)) {
        PyMOLreturn_int_array info = PyMOL_GetReshapeInfo(pymolInstance, 1);
        if (info.array && info.size >= 5) {
            int w = info.array[3] * _gScaleFactor;
            int h = info.array[4] * _gScaleFactor;
            renderer->viewport(0, 0, w, h);
            PyMOL_Reshape(pymolInstance, w, h, 0);
        }
        PyMOL_FreeResultArray(pymolInstance, info.array);
    }

    // Route ImmBatch and CGO batch rendering through the Metal renderer.
    ImmBatch_SetActiveRenderer(renderer);

    // Run the actual PyMOL rendering pipeline.
    // GL calls inside will be no-ops (no GL context), but operations
    // routed through G->Renderer will produce Metal rendering.
    if (PyMOL_GetRedisplay(pymolInstance, 1)) {
        PyMOL_PushValidContext(pymolInstance);
        PyMOL_Draw(pymolInstance);
        PyMOL_PopValidContext(pymolInstance);
    }

    ImmBatch_SetActiveRenderer(nullptr);

    renderer->endFrame();
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    if (pymolInstance) {
        PyMOL_Reshape(pymolInstance, (int)size.width, (int)size.height, 0);
    }
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// Mouse and keyboard — same shared helpers as OpenGLView
- (void)mouseDown:(NSEvent *)e {
    int btn = ([e modifierFlags] & NSEventModifierFlagCommand) ? PYMOL_BUTTON_MIDDLE : PYMOL_BUTTON_LEFT;
    handleMouseButton(self, e, btn, PYMOL_BUTTON_DOWN);
}
- (void)mouseUp:(NSEvent *)e        { handleMouseButton(self, e, PYMOL_BUTTON_LEFT, PYMOL_BUTTON_UP); }
- (void)mouseDragged:(NSEvent *)e   { handleMouseDrag(self, e); }
- (void)rightMouseDown:(NSEvent *)e  { handleMouseButton(self, e, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_DOWN); }
- (void)rightMouseUp:(NSEvent *)e    { handleMouseButton(self, e, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_UP); }
- (void)rightMouseDragged:(NSEvent *)e { handleMouseDrag(self, e); }
- (void)otherMouseDown:(NSEvent *)e  { handleMouseButton(self, e, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_DOWN); }
- (void)otherMouseUp:(NSEvent *)e    { handleMouseButton(self, e, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_UP); }
- (void)otherMouseDragged:(NSEvent *)e { handleMouseDrag(self, e); }
- (void)scrollWheel:(NSEvent *)e     { handleScrollWheel(self, e); }
- (void)keyDown:(NSEvent *)e         { handleKeyDown(self, e); }
- (void)flagsChanged:(NSEvent *)event {}

- (void)dealloc {
    if (pymolInstance) {
        PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
        delete G->Renderer;
        G->Renderer = nullptr;
        PyMOL_Stop(pymolInstance);
        PyMOL_Free(pymolInstance);
        pymolInstance = nullptr;
    }
}

@end

#endif // PYMOL_HAS_METAL

// ---------------------------------------------------------------------------
#pragma mark - App Delegate
// ---------------------------------------------------------------------------

@implementation PyMOLAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    static const CGFloat kChatPanelWidth = 320.0;
    static const CGFloat kCommandPanelHeight = 200.0;

    // Create window
    NSRect frame = NSMakeRect(100, 100, 1024, 768);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"PyMOL Viewer"];
    [self.window setDelegate:self];
    [self.window setMinSize:NSMakeSize(400, 300)];

    // Create a container view that holds chat panel, GL view, and command panel
    NSRect contentBounds = [[self.window contentView] bounds];
    NSView *container = [[NSView alloc] initWithFrame:contentBounds];
    container.autoresizesSubviews = YES;
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Chat container on the left (320px wide, full height, dark background)
    NSRect chatFrame = NSMakeRect(0, 0, kChatPanelWidth, contentBounds.size.height);
    self.chatContainer = [[NSView alloc] initWithFrame:chatFrame];
    self.chatContainer.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    self.chatContainer.identifier = @"chatContainer";
    self.chatContainer.wantsLayer = YES;
    self.chatContainer.layer.backgroundColor =
        [[NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.17 alpha:1.0] CGColor];
    [container addSubview:self.chatContainer];

    // Right side: command panel (top) + GL viewport (bottom)
    CGFloat rightX = kChatPanelWidth;
    CGFloat rightWidth = contentBounds.size.width - kChatPanelWidth;
    CGFloat contentH = contentBounds.size.height;

    // Command panel container at the top of the right side
    NSRect cmdFrame = NSMakeRect(rightX, contentH - kCommandPanelHeight, rightWidth, kCommandPanelHeight);
    self.commandPanelContainer = [[NSView alloc] initWithFrame:cmdFrame];
    self.commandPanelContainer.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.commandPanelContainer.identifier = @"commandPanel";
    self.commandPanelContainer.wantsLayer = YES;
    self.commandPanelContainer.layer.backgroundColor =
        [[NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.17 alpha:1.0] CGColor];
    [container addSubview:self.commandPanelContainer];

    // Rendering view below the command panel — Metal if available, else OpenGL.
    // Respect --metal / --opengl flags and PYMOL_RENDERER env var.
    CGFloat glHeight = contentH - kCommandPanelHeight;
    NSRect glFrame = NSMakeRect(rightX, 0, rightWidth, glHeight);

    bool tryMetal = (g_requestedBackend != kBackendOpenGL);
    bool tryOpenGL = (g_requestedBackend != kBackendMetal);

#if PYMOL_HAS_METAL
    if (tryMetal) {
        id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
        if (metalDevice) {
            self.usingMetal = YES;
            glView = [[PyMOLMetalView alloc] initWithFrame:glFrame];
            NSLog(@"PyMOL: Using Metal backend (%@)", [metalDevice name]);
        } else if (g_requestedBackend == kBackendMetal) {
            NSLog(@"PyMOL: Metal requested but no Metal device available");
        }
    }
#else
    if (g_requestedBackend == kBackendMetal) {
        NSLog(@"PyMOL: Metal requested but not compiled in (PYMOL_HAS_METAL=0)");
    }
#endif
    if (!glView && tryOpenGL) {
        self.usingMetal = NO;
        glView = [[PyMOLOpenGLView alloc] initWithFrame:glFrame];
        NSLog(@"PyMOL: Using OpenGL backend");
    }

    if (!glView) {
        NSLog(@"PyMOL: FATAL — no rendering backend available");
        [NSApp terminate:nil];
        return;
    }

    glView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:glView];

    [self.window setContentView:container];
    self.chatVisible = YES;

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:glView];

    // Ensure app is properly activated and receives events
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (void)toggleChatPanel {
    static const CGFloat kChatPanelWidth = 320.0;
    static const CGFloat kCommandPanelHeight = 200.0;
    NSRect contentBounds = [[self.window contentView] bounds];

    self.chatVisible = !self.chatVisible;

    CGFloat cmdH = self.commandPanelContainer.isHidden ? 0 : kCommandPanelHeight;

    CGFloat H = contentBounds.size.height;

    if (self.chatVisible) {
        [self.chatContainer setHidden:NO];
        [self.chatContainer setFrame:NSMakeRect(0, 0, kChatPanelWidth, H)];

        CGFloat rightX = kChatPanelWidth;
        CGFloat rightW = contentBounds.size.width - kChatPanelWidth;
        [self.commandPanelContainer setFrame:NSMakeRect(rightX, H - cmdH, rightW, cmdH)];
        [glView setFrame:NSMakeRect(rightX, 0, rightW, H - cmdH)];
    } else {
        [self.chatContainer setHidden:YES];
        CGFloat rightW = contentBounds.size.width;
        [self.commandPanelContainer setFrame:NSMakeRect(0, H - cmdH, rightW, cmdH)];
        [glView setFrame:NSMakeRect(0, 0, rightW, H - cmdH)];
    }

    // Force reshape so PyMOL picks up the new viewport size
    if ([glView isKindOfClass:[NSOpenGLView class]]) {
        [(NSOpenGLView *)glView reshape];
    }
    // MTKView handles reshape automatically via drawableSizeWillChange
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    // Cleanup handled by view dealloc
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Main
// ---------------------------------------------------------------------------

static void initPython(int argc, const char *argv[]) {
    // Set up Python home and module search path for the bundle
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *resourcePath = [bundle resourcePath];
    NSString *modulesPath = [resourcePath stringByAppendingPathComponent:@"modules"];

    // Register built-in _cmd module before Py_Initialize
    // Note: PyImport_AppendInittab only supports top-level module names
    PyImport_AppendInittab("_cmd", PyInit__cmd);

    // Configure Python before initialization
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.isolated = 0;
    config.site_import = 1;

    // Set program name
    PyConfig_SetBytesString(&config, &config.program_name, argv[0]);

    // If a bundled Python framework exists, set PYTHONHOME to it.
    // This makes the app portable — it finds its stdlib in the bundle
    // instead of /opt/homebrew/. In development mode (no bundled framework),
    // this is skipped and the system Python is used.
    NSString *bundledPython = [[[bundle bundlePath]
        stringByAppendingPathComponent:@"Contents/Frameworks/Python.framework/Versions/3.14"] retain];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundledPython]) {
        PyConfig_SetBytesString(&config, &config.home, [bundledPython UTF8String]);
    }

    // Initialize Python
    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        NSLog(@"Failed to initialize Python: %s", status.err_msg);
        return;
    }

    // Register pymol._cmd in sys.modules so "import pymol._cmd" works.
    init_cmd();

    // Add our modules path to sys.path
    PyObject *sysPath = PySys_GetObject("path");
    if (sysPath) {
        PyObject *path = PyUnicode_FromString([modulesPath UTF8String]);
        PyList_Insert(sysPath, 0, path);
        Py_DECREF(path);

        // Add bundled site-packages (numpy, PyObjC, etc.) if present
        NSString *sitePackages = [resourcePath
            stringByAppendingPathComponent:@"lib/python3.14/site-packages"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:sitePackages]) {
            PyObject *spPath = PyUnicode_FromString([sitePackages UTF8String]);
            PyList_Insert(sysPath, 1, spPath);
            Py_DECREF(spPath);
        }
    }

    // Set PYMOL_PATH and PYMOL_DATA for pymol module initialization
    setenv("PYMOL_PATH", [resourcePath UTF8String], 1);
    NSString *dataPath = [resourcePath stringByAppendingPathComponent:@"data"];
    setenv("PYMOL_DATA", [dataPath UTF8String], 1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Parse --metal / --opengl command-line flags
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--metal") == 0) {
                g_requestedBackend = kBackendMetal;
            } else if (strcmp(argv[i], "--opengl") == 0) {
                g_requestedBackend = kBackendOpenGL;
            }
        }

        // Check PYMOL_RENDERER env var (command-line flags take precedence)
        if (g_requestedBackend == kBackendAuto) {
            const char *envRenderer = getenv("PYMOL_RENDERER");
            if (envRenderer) {
                if (strcasecmp(envRenderer, "metal") == 0) {
                    g_requestedBackend = kBackendMetal;
                } else if (strcasecmp(envRenderer, "opengl") == 0 ||
                           strcasecmp(envRenderer, "gl") == 0) {
                    g_requestedBackend = kBackendOpenGL;
                }
            }
        }

        // Initialize Python before anything else
        initPython(argc, argv);

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Create menu bar
        NSMenu *menuBar = [[NSMenu alloc] init];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];

        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"PyMOL"];
        [appMenu addItemWithTitle:@"About PyMOL" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit PyMOL" action:@selector(terminate:) keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];

        [app setMainMenu:menuBar];

        // Set delegate and run
        PyMOLAppDelegate *delegate = [[PyMOLAppDelegate alloc] init];
        [app setDelegate:delegate];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}

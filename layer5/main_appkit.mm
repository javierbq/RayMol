/*
 * main_appkit.mm - Native macOS AppKit host for PyMOL
 *
 * Replaces GLUT-based main.cpp with a native NSApplication + NSOpenGLView.
 * Uses the PyMOL_* embedding API (_PYMOL_LIB mode).
 *
 * Build with: -framework Cocoa -framework OpenGL
 * Requires: _PYMOL_LIB, _PYMOL_NO_MAIN, _PYMOL_PRETEND_GLUT
 */

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/OpenGL.h>

#include "ov_port.h"
#include "ov_types.h"
#include "PyMOL.h"
#include "PyMOLOptions.h"
#include "os_python.h"
#include "PyMOLGlobals.h"
#include "Cmd.h"

// Defined in Cmd.cpp
extern "C" PyObject* PyInit__cmd(void);

// Defined in P.cpp (declared in P.h, but we can't include P.h here
// because it pulls in GLEW which conflicts with the OpenGL framework headers)
extern void PInit(PyMOLGlobals * G, int global_instance);
extern void PBlock(PyMOLGlobals * G);
extern void PUnblock(PyMOLGlobals * G);
extern int PLockAPIAsGlut(PyMOLGlobals * G, int block_if_busy);
extern void PUnlockAPIAsGlut(PyMOLGlobals * G);

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

@interface PyMOLAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) NSView *chatContainer;
@property (assign) BOOL chatVisible;
- (void)toggleChatPanel;
@end

static CPyMOL *pymolInstance = nullptr;
static PyMOLOpenGLView *glView = nullptr;

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

    // Release the GIL
    PUnblock(G);

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

    // Set swap callback
    PyMOL_SetSwapBuffersFn(pymolInstance, []() {
        if (glView) {
            [[glView openGLContext] flushBuffer];
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

    if (!PLockAPIAsGlut(G, false)) return;

    // Process idle work
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

    PUnlockAPIAsGlut(G);

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

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - Modifier conversion
// ---------------------------------------------------------------------------

- (int)pymolModifiersFromEvent:(NSEvent *)event {
    int mods = 0;
    NSEventModifierFlags flags = [event modifierFlags];
    if (flags & NSEventModifierFlagShift)   mods |= PYMOL_MODIFIER_SHIFT;
    if (flags & NSEventModifierFlagControl) mods |= PYMOL_MODIFIER_CTRL;
    if (flags & NSEventModifierFlagOption)  mods |= PYMOL_MODIFIER_ALT;
    return mods;
}

- (NSPoint)pymolPointFromEvent:(NSEvent *)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];
    // Convert to backing (pixel) coordinates for Retina
    loc = [self convertPointToBacking:loc];
    // PyMOL uses top-left origin; backing coords use bottom-left
    NSRect pixelBounds = [self convertRectToBacking:[self bounds]];
    loc.y = pixelBounds.size.height - loc.y;
    return loc;
}

// ---------------------------------------------------------------------------
#pragma mark - Mouse events
// ---------------------------------------------------------------------------

- (void)mouseDown:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    int button = PYMOL_BUTTON_LEFT;
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        button = PYMOL_BUTTON_MIDDLE;
    }
    OrthoButton(G, button, PYMOL_BUTTON_DOWN, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)mouseUp:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoButton(G, PYMOL_BUTTON_LEFT, PYMOL_BUTTON_UP, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)mouseDragged:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoDrag(G, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)rightMouseDown:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoButton(G, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_DOWN, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)rightMouseUp:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoButton(G, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_UP, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)rightMouseDragged:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoDrag(G, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)otherMouseDown:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoButton(G, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_DOWN, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)otherMouseUp:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoButton(G, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_UP, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)otherMouseDragged:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    OrthoDrag(G, (int)pt.x, (int)pt.y, mods);
    PUnlockAPIAsGlut(G);
}

- (void)scrollWheel:(NSEvent *)event {
    if (!pymolInstance) return;
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    if (!PLockAPIAsGlut(G, false)) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    float dy = [event deltaY];
    if (dy > 0.0f) {
        OrthoButton(G, PYMOL_BUTTON_SCROLL_FORWARD, PYMOL_BUTTON_DOWN, (int)pt.x, (int)pt.y, mods);
    } else if (dy < 0.0f) {
        OrthoButton(G, PYMOL_BUTTON_SCROLL_REVERSE, PYMOL_BUTTON_DOWN, (int)pt.x, (int)pt.y, mods);
    }
    PUnlockAPIAsGlut(G);
}

// ---------------------------------------------------------------------------
#pragma mark - Keyboard events
// ---------------------------------------------------------------------------

- (void)keyDown:(NSEvent *)event {
    if (!pymolInstance) return;

    // Handle Cmd+L toggle of the embedded chat panel
    NSEventModifierFlags flags = [event modifierFlags];
    if ((flags & NSEventModifierFlagCommand)
        && !(flags & NSEventModifierFlagShift)
        && !(flags & NSEventModifierFlagControl)
        && [[event charactersIgnoringModifiers] isEqualToString:@"l"]) {
        // Find the app delegate and toggle
        PyMOLAppDelegate *del = (PyMOLAppDelegate *)[NSApp delegate];
        if ([del respondsToSelector:@selector(toggleChatPanel)]) {
            [del toggleChatPanel];
        }
        return;  // swallow the event
    }

    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    NSString *chars = [event characters];
    NSString *charsNoMod = [event charactersIgnoringModifiers];

    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];

        // Map special keys
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
            // ASCII key
            PyMOL_Key(pymolInstance, (unsigned char)c, (int)pt.x, (int)pt.y, mods);
        }
    }
}

- (void)flagsChanged:(NSEvent *)event {
    // Could track modifier key state changes if needed
}

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
#pragma mark - App Delegate
// ---------------------------------------------------------------------------

@implementation PyMOLAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    static const CGFloat kChatPanelWidth = 320.0;

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

    // Create a container view that holds both the chat panel and GL view
    NSRect contentBounds = [[self.window contentView] bounds];
    NSView *container = [[NSView alloc] initWithFrame:contentBounds];
    container.autoresizesSubviews = YES;
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Chat container on the left (320px wide, dark background)
    NSRect chatFrame = NSMakeRect(0, 0, kChatPanelWidth, contentBounds.size.height);
    self.chatContainer = [[NSView alloc] initWithFrame:chatFrame];
    self.chatContainer.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    self.chatContainer.identifier = @"chatContainer";
    // Dark background using a layer
    self.chatContainer.wantsLayer = YES;
    self.chatContainer.layer.backgroundColor =
        [[NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.17 alpha:1.0] CGColor];
    [container addSubview:self.chatContainer];

    // GL view on the right (fills remaining width)
    CGFloat glX = kChatPanelWidth;
    CGFloat glWidth = contentBounds.size.width - kChatPanelWidth;
    NSRect glFrame = NSMakeRect(glX, 0, glWidth, contentBounds.size.height);
    glView = [[PyMOLOpenGLView alloc] initWithFrame:glFrame];
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
    NSRect contentBounds = [[self.window contentView] bounds];

    self.chatVisible = !self.chatVisible;

    if (self.chatVisible) {
        // Show the chat panel
        [self.chatContainer setHidden:NO];
        NSRect chatFrame = NSMakeRect(0, 0, kChatPanelWidth, contentBounds.size.height);
        [self.chatContainer setFrame:chatFrame];
        NSRect glFrame = NSMakeRect(kChatPanelWidth, 0,
                                     contentBounds.size.width - kChatPanelWidth,
                                     contentBounds.size.height);
        [glView setFrame:glFrame];
    } else {
        // Hide the chat panel
        [self.chatContainer setHidden:YES];
        NSRect glFrame = NSMakeRect(0, 0,
                                     contentBounds.size.width,
                                     contentBounds.size.height);
        [glView setFrame:glFrame];
    }

    // Force reshape so PyMOL picks up the new viewport size
    [glView reshape];
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

    // Initialize Python
    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        NSLog(@"Failed to initialize Python: %s", status.err_msg);
        return;
    }

    // Register pymol._cmd in sys.modules so "import pymol._cmd" works.
    // init_cmd() calls PyInit__cmd() and inserts the module as "pymol._cmd".
    init_cmd();

    // Add our modules path to sys.path
    PyObject *sysPath = PySys_GetObject("path");
    if (sysPath) {
        PyObject *path = PyUnicode_FromString([modulesPath UTF8String]);
        PyList_Insert(sysPath, 0, path);
        Py_DECREF(path);
    }

    // Set PYMOL_PATH and PYMOL_DATA for pymol module initialization
    setenv("PYMOL_PATH", [resourcePath UTF8String], 1);
    NSString *dataPath = [resourcePath stringByAppendingPathComponent:@"data"];
    setenv("PYMOL_DATA", [dataPath UTF8String], 1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
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

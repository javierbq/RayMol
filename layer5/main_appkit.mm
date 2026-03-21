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
extern void PUnblock(PyMOLGlobals * G);

// Symbols normally provided by main.cpp (GLUT host).
// The AppKit host uses the PyMOL_* embedding API instead.
int _gScaleFactor = 1;

int MainSavingUnderWhileIdle(void) { return 0; }
PyObject *MainAsPyList(PyMOLGlobals *) { Py_RETURN_NONE; }
int MainFromPyList(PyMOLGlobals *, PyObject *) { return 0; }

// Forward declarations
@class PyMOLOpenGLView;
@class PyMOLAppDelegate;

static CPyMOL *pymolInstance = nullptr;
static PyMOLOpenGLView *glView = nullptr;

// ---------------------------------------------------------------------------
#pragma mark - PyMOLOpenGLView
// ---------------------------------------------------------------------------

@interface PyMOLOpenGLView : NSOpenGLView {
    CVDisplayLinkRef _displayLink;
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

    // Follow the same init sequence as the GLUT host (main.cpp):
    // 1. Set the global singleton so PInit can find it
    PyMOLGlobals *G = PyMOL_GetGlobals(pymolInstance);
    SingletonPyMOLGlobals = G;

    // 2. Start the C-level subsystems
    PyMOL_Start(pymolInstance);

    // 3. Initialize Python-to-C hooks as a global (singleton) instance
    PInit(G, true);

    // 4. Release the GIL so the main thread can proceed
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

    // Set up CVDisplayLink for rendering
    CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    CVDisplayLinkSetOutputCallback(_displayLink, &displayLinkCallback, (__bridge void *)self);

    CGLContextObj cglContext = [[self openGLContext] CGLContextObj];
    CGLPixelFormatObj cglPixelFormat = [[self pixelFormat] CGLPixelFormatObj];
    CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(_displayLink, cglContext, cglPixelFormat);

    CVDisplayLinkStart(_displayLink);
}

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink,
                                     const CVTimeStamp *now,
                                     const CVTimeStamp *outputTime,
                                     CVOptionFlags flagsIn,
                                     CVOptionFlags *flagsOut,
                                     void *displayLinkContext) {
    @autoreleasepool {
        PyMOLOpenGLView *view = (__bridge PyMOLOpenGLView *)displayLinkContext;
        [view performSelectorOnMainThread:@selector(renderFrame) withObject:nil waitUntilDone:NO];
    }
    return kCVReturnSuccess;
}

- (void)renderFrame {
    if (!_initialized || !pymolInstance) return;

    [[self openGLContext] makeCurrentContext];
    CGLLockContext([[self openGLContext] CGLContextObj]);

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

    // Swap if needed (may also be handled by swap callback)
    if (PyMOL_GetSwap(pymolInstance, 1)) {
        [[self openGLContext] flushBuffer];
    }

    CGLUnlockContext([[self openGLContext] CGLContextObj]);
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
    // PyMOL uses top-left origin; NSView uses bottom-left
    NSRect bounds = [self bounds];
    loc.y = bounds.size.height - loc.y;
    return loc;
}

// ---------------------------------------------------------------------------
#pragma mark - Mouse events
// ---------------------------------------------------------------------------

- (void)mouseDown:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    int button = PYMOL_BUTTON_LEFT;
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        button = PYMOL_BUTTON_MIDDLE; // Cmd+Click = middle button
    }
    PyMOL_Button(pymolInstance, button, PYMOL_BUTTON_DOWN,
                 (int)pt.x, (int)pt.y, mods);
}

- (void)mouseUp:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Button(pymolInstance, PYMOL_BUTTON_LEFT, PYMOL_BUTTON_UP,
                 (int)pt.x, (int)pt.y, mods);
}

- (void)mouseDragged:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Drag(pymolInstance, (int)pt.x, (int)pt.y, mods);
}

- (void)rightMouseDown:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Button(pymolInstance, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_DOWN,
                 (int)pt.x, (int)pt.y, mods);
}

- (void)rightMouseUp:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Button(pymolInstance, PYMOL_BUTTON_RIGHT, PYMOL_BUTTON_UP,
                 (int)pt.x, (int)pt.y, mods);
}

- (void)rightMouseDragged:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Drag(pymolInstance, (int)pt.x, (int)pt.y, mods);
}

- (void)otherMouseDown:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Button(pymolInstance, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_DOWN,
                 (int)pt.x, (int)pt.y, mods);
}

- (void)otherMouseUp:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Button(pymolInstance, PYMOL_BUTTON_MIDDLE, PYMOL_BUTTON_UP,
                 (int)pt.x, (int)pt.y, mods);
}

- (void)otherMouseDragged:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    PyMOL_Drag(pymolInstance, (int)pt.x, (int)pt.y, mods);
}

- (void)scrollWheel:(NSEvent *)event {
    if (!pymolInstance) return;
    NSPoint pt = [self pymolPointFromEvent:event];
    int mods = [self pymolModifiersFromEvent:event];
    float dy = [event deltaY];
    if (dy > 0.0f) {
        PyMOL_Button(pymolInstance, PYMOL_BUTTON_SCROLL_FORWARD, PYMOL_BUTTON_DOWN,
                     (int)pt.x, (int)pt.y, mods);
    } else if (dy < 0.0f) {
        PyMOL_Button(pymolInstance, PYMOL_BUTTON_SCROLL_REVERSE, PYMOL_BUTTON_DOWN,
                     (int)pt.x, (int)pt.y, mods);
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Keyboard events
// ---------------------------------------------------------------------------

- (void)keyDown:(NSEvent *)event {
    if (!pymolInstance) return;

    // Let the AI chat panel Cmd+L monitor handle it first
    // (NSEvent local monitors fire before this)

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
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
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

@interface PyMOLAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@end

@implementation PyMOLAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
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

    // Create OpenGL view
    glView = [[PyMOLOpenGLView alloc] initWithFrame:[[self.window contentView] bounds]];
    [glView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [[self.window contentView] addSubview:glView];

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:glView];
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

"""Ray/Draw image overlay for Metal viewport.

When ray tracing or draw completes on the Metal backend, the rendered image
is stored in CScene::Image but never displayed (the GL path uses
glDrawPixels; the Metal path has no equivalent). This module provides an
NSImageView overlay that shows the rendered image on top of the MTKView
and hides itself when the user interacts with the viewport.

Usage from Python:
    from pymol import appkit_ray_overlay
    appkit_ray_overlay.show_ray_image(cmd)   # after ray/draw completes
    appkit_ray_overlay.hide()                # dismiss overlay
"""

import os
import threading

from pymol import raymol_tmp

try:
    import objc
    import AppKit
    import Foundation
    _HAS_APPKIT = True
except ImportError:
    _HAS_APPKIT = False

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------

_image_view = None       # NSImageView overlay
_metal_view = None       # cached reference to the MTKView
_event_monitor = None    # NSEvent local monitor for dismissing overlay


def _find_metal_view():
    """Find the MTKView in the PyMOL Viewer window."""
    global _metal_view
    if _metal_view is not None:
        # Validate the cached view is still in a window
        if _metal_view.window() is not None:
            return _metal_view
        _metal_view = None

    for win in AppKit.NSApp.windows():
        if win.title() == "PyMOL Viewer":
            for sv in win.contentView().subviews():
                if sv.className() == "PyMOLMetalView":
                    _metal_view = sv
                    return sv
                for ssv in sv.subviews():
                    if ssv.className() == "PyMOLMetalView":
                        _metal_view = ssv
                        return ssv
    return None


def _install_event_monitor():
    """Install a local event monitor that hides the overlay on mouse/key events."""
    global _event_monitor
    if _event_monitor is not None:
        return

    mask = (AppKit.NSEventMaskLeftMouseDown
            | AppKit.NSEventMaskRightMouseDown
            | AppKit.NSEventMaskOtherMouseDown
            | AppKit.NSEventMaskScrollWheel
            | AppKit.NSEventMaskKeyDown)

    def handler(event):
        view = _find_metal_view()
        if view and event.window() == view.window():
            hide()
        return event

    _event_monitor = AppKit.NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
        mask, handler)


def _remove_event_monitor():
    """Remove the local event monitor."""
    global _event_monitor
    if _event_monitor is not None:
        AppKit.NSEvent.removeMonitor_(_event_monitor)
        _event_monitor = None


def _show_on_main_thread(png_path):
    """Display the PNG image as an overlay. Must run on the main thread."""
    global _image_view

    view = _find_metal_view()
    if view is None:
        return

    ns_image = AppKit.NSImage.alloc().initWithContentsOfFile_(png_path)
    if ns_image is None:
        return

    # Clean up temp file
    try:
        os.unlink(png_path)
    except OSError:
        pass

    # Create or reuse the image view
    bounds = view.bounds()
    if _image_view is None:
        _image_view = AppKit.NSImageView.alloc().initWithFrame_(bounds)
        _image_view.setImageScaling_(
            AppKit.NSImageScaleProportionallyUpOrDown)
        _image_view.setImageAlignment_(AppKit.NSImageAlignCenter)
        _image_view.setWantsLayer_(True)
        _image_view.layer().setBackgroundColor_(
            AppKit.NSColor.blackColor().CGColor())
        _image_view.setAutoresizingMask_(
            AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    else:
        _image_view.setFrame_(bounds)

    _image_view.setImage_(ns_image)

    # Add overlay on top of the Metal view
    if _image_view.superview() != view:
        if _image_view.superview():
            _image_view.removeFromSuperview()
        view.addSubview_positioned_relativeTo_(
            _image_view, AppKit.NSWindowAbove, None)

    _image_view.setHidden_(False)
    _image_view.setNeedsDisplay_(True)

    _install_event_monitor()


def show_ray_image(cmd_module):
    """Save the current ray-traced image to a temp file and display it.

    Safe to call from any thread. The image export (cmd.png) is done on the
    calling thread; the NSImageView display is dispatched to the main thread.
    """
    if not _HAS_APPKIT:
        return

    # Check if there is a Metal view (on the main thread this is safe;
    # from a background thread the cached _metal_view may already be set
    # from a previous call or the initial check from the main thread).
    if _metal_view is None and threading.current_thread() is threading.main_thread():
        if _find_metal_view() is None:
            return  # not running in Metal AppKit host

    # Save the scene image to a temporary PNG file.
    # prior=1 reads CScene::Image without re-rendering.
    tmp_path = raymol_tmp.channel_path("_pymol_ray_overlay", "png")
    try:
        cmd_module.png(tmp_path, prior=1, quiet=1)
    except Exception:
        return

    if not os.path.isfile(tmp_path):
        return

    # Dispatch UI work to the main thread
    if threading.current_thread() is threading.main_thread():
        _show_on_main_thread(tmp_path)
    else:
        # Use performSelectorOnMainThread to schedule on the AppKit run loop
        _OverlayHelper.showWithPath_(tmp_path)


def hide():
    """Hide the ray image overlay and return to the live Metal render."""
    global _image_view
    if _image_view is not None:
        _image_view.setHidden_(True)
        if _image_view.superview():
            _image_view.removeFromSuperview()
    _remove_event_monitor()


def is_visible():
    """Return True if the overlay is currently visible."""
    return (_image_view is not None
            and not _image_view.isHidden()
            and _image_view.superview() is not None)


# ---------------------------------------------------------------------------
# ObjC helper for cross-thread dispatch
# ---------------------------------------------------------------------------

if _HAS_APPKIT:
    class _OverlayHelper(AppKit.NSObject):
        """Tiny ObjC object to dispatch show_on_main_thread via
        performSelectorOnMainThread."""

        _pending_path = None

        @classmethod
        def showWithPath_(cls, path):
            cls._pending_path = path
            inst = cls.alloc().init()
            inst.performSelectorOnMainThread_withObject_waitUntilDone_(
                b'doShow:', None, False)

        @objc.typedSelector(b'v@:@')
        def doShow_(self, _sender):
            path = _OverlayHelper._pending_path
            if path:
                _OverlayHelper._pending_path = None
                _show_on_main_thread(path)

"""Per-process paths for the tempfile channels Python uses to hand payloads to
the native app.

Several payloads are too large for PyMOL's ~1 KB feedback-line cap, so Python
writes them to `$TMPDIR` and only the marker rides the feedback line. The file
name must therefore be unique PER PROCESS: two RayMol instances on one machine
(a dev build beside the installed app, or several windows launched as separate
processes) share `$TMPDIR`, so a fixed name lets one instance read the other's
payload — the sequence channels are written on one tick and read on the next, so
the swap window is wide (issue #399).

Python and Swift are the SAME process here (PyMOL is embedded in the app), so
`os.getpid()` and `ProcessInfo.processInfo.processIdentifier` agree. Every stem
passed to `channel_path` must have a twin in `TempChannel.Stem` on the Swift
side, which is both the reader and the list `TempChannel.removeAll()` clears on
quit.
"""
import os
import tempfile


def channel_path(stem, ext='json'):
    """Return `<tmpdir>/<stem>_<pid>.<ext>` for this process."""
    return os.path.join(tempfile.gettempdir(),
                        '%s_%d.%s' % (stem, os.getpid(), ext))

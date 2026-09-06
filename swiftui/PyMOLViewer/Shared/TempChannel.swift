// TempChannel.swift — per-process paths for the Python→Swift tempfile channels

import Foundation

/// The `$TMPDIR` files Python writes payloads into when they are too large for
/// PyMOL's ~1 KB feedback-line cap (only the marker rides the line).
///
/// Every name carries this process's pid. `$TMPDIR` is shared by every RayMol on
/// the machine — a dev build beside the installed app, or several windows
/// launched as separate processes — so a fixed name lets one instance read
/// another's payload (issue #399). The sequence channels are the worst case:
/// written on one 100 ms tick and read on the next, so a second instance has a
/// whole tick to replace the file in between; gizmo and hover are written and
/// read synchronously, so their window is small but real.
///
/// PyMOL is embedded in this process, so `os.getpid()` on the Python side and
/// `processIdentifier` here name the same file. Keep `Stem` in sync with the
/// stems passed to `raymol_tmp.channel_path` in modules/pymol.
enum TempChannel {
    enum Stem {
        static let sequence = "pymol_seq"
        static let sequenceSelection = "pymol_seqsel"
        static let gizmo = "pymol_gizmo"
        static let hoverInfo = "pymol_hover_info"
        static let settings = "pymol_settings"
        static let rayOverlay = "_pymol_ray_overlay"
        static let objectPanel = "pymol_objpanel"
        static let objectDetail = "pymol_objdetail"
        static let predictForm = "pymol_predict"
        static let designForm = "pymol_design"

        /// Every channel, for `removeAll()`. `.png` channels are listed with
        /// their extension; the rest are JSON.
        static let all: [(stem: String, ext: String)] = [
            (sequence, "json"), (sequenceSelection, "json"), (gizmo, "json"),
            (hoverInfo, "json"), (settings, "json"), (rayOverlay, "png"),
            (objectPanel, "json"), (objectDetail, "json"),
            (predictForm, "json"), (designForm, "json"),
        ]
    }

    /// `<tmpdir>/<stem>_<pid>.<ext>` for this process.
    static func path(_ stem: String, ext: String = "json") -> String {
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(stem)_\(ProcessInfo.processInfo.processIdentifier).\(ext)")
    }

    /// Delete this process's channel files. Called on quit so `$TMPDIR` does not
    /// accumulate one set per run — pid-scoping makes the names unique, which
    /// also makes them un-reusable, so nothing else ever overwrites them.
    /// Missing files are the normal case (a channel that never fired), so
    /// failures are ignored.
    static func removeAll() {
        for channel in Stem.all {
            try? FileManager.default.removeItem(atPath: path(channel.stem, ext: channel.ext))
        }
    }
}

// SetNoticeBanner.swift — the one-line strip over a set's tab in the Data drawer.
//
// It says what changed the set's staging WITHOUT the user asking: "Restaged top 6 by
// pLDDT" when a run finished and its staging moved from arrival order to the ranking
// (#546). The text is Python's (`meta` row `set_notice:<set id>`, read with the sets by
// `SetsStore.noticesBySet`), so the console, an MCP agent (`set_notice`) and this strip
// say the same thing. Gone after the next staging action, which clears the row, or on
// Dismiss, which is `set_notice <set>, 1` — every drawer action has a `set_*` command.
//
// Its own file, and one hook in `DataDrawer.tabHalf`, so the drawer's table and layout
// code (in flight elsewhere) is not touched. When it shows it takes `height` from the
// drawer's content; the drawer's layout budget has to charge that.

import SwiftUI

/// What the strip shows for a set, or nil when it shows nothing. Pure, so the rule is
/// testable without a view.
struct SetNoticeModel: Equatable {
    let text: String

    static func make(set: SetEntry) -> SetNoticeModel? {
        let text = set.notice.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : SetNoticeModel(text: text)
    }
}

#if os(macOS)
struct SetNoticeBanner: View {
    /// The strip's height, hairline included. The drawer's content loses this much
    /// while a notice shows.
    static let height: CGFloat = 23

    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager
    let set: SetEntry

    var body: some View {
        if let model = SetNoticeModel.make(set: set) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(PanelTheme.headerColor)
                    Text(model.text)
                        .font(.system(size: 10))
                        .foregroundColor(PanelTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(model.text)
                    Spacer(minLength: 8)
                    Button("Dismiss") { engine.dismissSetNotice(set) }
                        .font(.system(size: 10))
                        .controlSize(.small)
                        .help("Hide this line (set_notice \(set.name), 1)")
                }
                .padding(.horizontal, 10)
                .frame(height: Self.height - 1)
                Rectangle().fill(themeManager.active.panelText.color.opacity(0.18))
                    .frame(height: 1)
            }
        }
    }
}

extension PyMOLEngine {
    /// Dismiss: `set_notice name, 1`. The version bump re-reads the sets, which hides
    /// the strip.
    func dismissSetNotice(_ set: SetEntry) {
        runPythonQuiet("from pymol import cmd as _c\n_c.set_notice(\(Self.pythonLiteral(set.name)), 1)")
    }
}
#endif

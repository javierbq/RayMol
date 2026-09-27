// SetNoticeBanner.swift — a set's one-line notice, INLINE in the Data drawer's header row.
//
// It says what changed the set's staging WITHOUT the user asking: "Restaged top 6 by
// pLDDT" when a run finished and its staging moved from arrival order to the ranking
// (#546). The text is Python's (`meta` row `set_notice:<set id>`, read with the sets by
// `SetsStore.noticesBySet`), so the console, an MCP agent (`set_notice`) and this strip
// say the same thing. Gone after the next staging action, which clears the row, or on
// Dismiss, which is `set_notice <set>, 1` — every drawer action has a `set_*` command.
//
// Where it goes: in the header row that is already there (`DATA · <set>` on the left,
// `N of M staged · budget B ×` on the right), in the space between them. Not a strip of
// its own: at the default window a strip cost the table a row and pushed the Plot tab
// under its floor, so a notice appearing swapped the drawer for the "needs more room"
// hint (review). The header's height does not change, so the drawer's layout budget
// needs no charge for it. Narrow, it degrades in steps: the full text, the text
// truncated (the tooltip has all of it), and last the × alone.
//
// Its own file, and one hook in `DataDrawer.header`, so the drawer's table and layout
// code (in flight elsewhere) is not touched.

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
/// The notice in the drawer header. Takes the header's slack and nothing else: with no
/// notice it is only the spacer the header always had.
struct SetNoticeInline: View {
    @EnvironmentObject var engine: PyMOLEngine
    let set: SetEntry

    /// How much of the text the truncating step keeps before giving up on text.
    static let truncatedTextWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 0) {
            if let model = SetNoticeModel.make(set: set) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { message(model); dismiss(model) }
                    HStack(spacing: 6) {
                        message(model).frame(maxWidth: Self.truncatedTextWidth,
                                             alignment: .leading)
                        dismiss(model)
                    }
                    dismiss(model)
                }
                .padding(.leading, 4)
            }
            Spacer(minLength: 8)
        }
    }

    private func message(_ model: SetNoticeModel) -> some View {
        Text(model.text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(PanelTheme.accentColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(model.text)
    }

    private func dismiss(_ model: SetNoticeModel) -> some View {
        Button { engine.dismissSetNotice(set) } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.headerColor)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(model.text) -- hide this notice (set_notice \(set.name), 1)")
    }
}

extension PyMOLEngine {
    /// Dismiss: `set_notice name, 1`. The version bump re-reads the sets, which hides
    /// the notice.
    func dismissSetNotice(_ set: SetEntry) {
        runPythonQuiet("from pymol import cmd as _c\n_c.set_notice(\(Self.pythonLiteral(set.name)), 1)")
    }
}
#endif

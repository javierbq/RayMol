// SetNoticeBanner.swift — a set's one-line notice, INLINE in the Data drawer's header row.
//
// It says what changed the set WITHOUT the user asking, and — when there is one — offers
// the next step:
//
//   restage    "Restaged top 6 by pLDDT"                                   [Dismiss]
//              a run finished and its staging moved from arrival order to the ranking
//              (#546)
//   recovered  "Scene not recovered.  [Stage 4 starred]  [Apply top50]     [Dismiss]"
//              a recovery Open brought the sets, stars and views back but not the scene
//              (#547); the buttons appear only when they apply
//
// The notice is Python's (`meta` row `set_notice:<set id>`, read with the sets by
// `SetsStore.noticesBySet`), so the console, an MCP agent (`set_notice`) and this strip
// say the same thing. Gone after the next staging action, which clears the row, or on
// Dismiss, which is `set_notice <set>, 1`. Every button is a `set_*` command: Stage is
// `set_stage <set>, starred` (through `appkit_sets.stage_entries`, so a budget refusal
// is a warning, not a traceback), Apply is the drawer's own view apply
// (`set_filter` + `set_sort`).
//
// Where it goes: in the header row that is already there (`DATA · <set>` on the left,
// `N of M staged · budget B ×` on the right), in the space between them. Not a strip of
// its own: at the default window a strip cost the table a row and pushed the Plot tab
// under its floor, so a notice appearing swapped the drawer for the "needs more room"
// hint (review). The header's height does not change, so the drawer's layout budget
// needs no charge for it. Narrow, it degrades in steps: the full text, the text
// truncated (the tooltip has all of it), the buttons alone, and last a `⋯` menu.
//
// Its own file, and one hook in `DataDrawer.header`, so the drawer's table and layout
// code (in flight elsewhere) is not touched.

import SwiftUI

/// A set's notice as the file holds it: `{"kind", "text"}`.
struct SetNotice: Equatable {
    /// "restage" (#546), "recovered" (#547), or anything a later producer writes —
    /// an unknown kind still shows its text and Dismiss.
    let kind: String
    let text: String

    static let recoveredKind = "recovered"
}

/// What the strip shows for a set, or nil when it shows nothing. Pure, so the rules
/// are testable without a view.
struct SetNoticeModel: Equatable {
    let text: String
    /// A recovery notice (#547): its Dismiss is a word, not an ×, because it sits
    /// beside other verbs.
    var isRecovery: Bool = false
    /// Starred entries not staged yet: the count on "Stage N starred". 0 hides it.
    let starredToStage: Int
    /// Why those would not fit the stage budget, or nil when they fit. The button is
    /// disabled on it and the strip shows it, so the click never silently does nothing.
    let stageRefusal: String?
    /// The saved view "Apply <view>" applies (the set's most recent), or nil to hide it.
    let view: SetView?

    var showsStage: Bool { starredToStage > 0 }
    var stageTitle: String { "Stage \(starredToStage) starred" }
    var applyTitle: String? { view.map { "Apply \($0.name)" } }

    /// `rows` are the set's entries (all of them, not the filtered ones: `starred` as a
    /// selector names every starred entry, whatever the table shows).
    static func make(set: SetEntry, rows: [SetRow]) -> SetNoticeModel? {
        guard let notice = set.notice else { return nil }
        let text = notice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard notice.kind == SetNotice.recoveredKind else {
            return SetNoticeModel(text: text, starredToStage: 0, stageRefusal: nil, view: nil)
        }
        // Only for a set whose entries have structures: a sequences set has nothing
        // `set_stage` could put in the scene.
        let starred = set.kind == "sequences" ? 0
            : rows.filter { $0.starred && !$0.isStaged && $0.hasStructure }.count
        let budget = SetTableModel(set: set, rows: rows)
        return SetNoticeModel(text: text, isRecovery: true, starredToStage: starred,
                              stageRefusal: starred > 0 ? budget.stageRefusal(starred) : nil,
                              view: set.views.last)
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
            if let model = SetNoticeModel.make(set: set, rows: engine.setRows) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { message(model); buttons(model) }
                    HStack(spacing: 8) {
                        message(model).frame(maxWidth: Self.truncatedTextWidth,
                                             alignment: .leading)
                        buttons(model)
                    }
                    HStack(spacing: 8) { buttons(model) }
                    overflow(model)
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

    @ViewBuilder
    private func buttons(_ model: SetNoticeModel) -> some View {
        HStack(spacing: 8) {
            if model.showsStage {
                link(model.stageTitle,
                     help: model.stageRefusal
                        ?? "Put the starred entries back in the scene (set_stage \(set.name), starred)") {
                    engine.stageStarred(set)
                }
                .disabled(model.stageRefusal != nil)
            }
            if let view = model.view, let title = model.applyTitle {
                link(title, help: "Apply the saved view's filter, sort and columns") {
                    engine.applySetView(set, view)
                }
            }
            if model.isRecovery {
                link("Dismiss", help: dismissHelp) { engine.dismissSetNotice(set) }
            } else {
                Button { engine.dismissSetNotice(set) } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(PanelTheme.headerColor)
                }
                .buttonStyle(.plain)
                .help(dismissHelp)
            }
        }
        .fixedSize()
    }

    private func overflow(_ model: SetNoticeModel) -> some View {
        Menu {
            Text(model.text)
            if model.showsStage {
                Button(model.stageTitle) { engine.stageStarred(set) }
                    .disabled(model.stageRefusal != nil)
            }
            if let view = model.view, let title = model.applyTitle {
                Button(title) { engine.applySetView(set, view) }
            }
            Button("Dismiss") { engine.dismissSetNotice(set) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11))
                .foregroundColor(PanelTheme.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.text)
    }

    private var dismissHelp: String { "Hide this notice (set_notice \(set.name), 1)" }

    private func link(_ title: String, help: String,
                      action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.system(size: 10))
            .help(help)
    }
}

extension PyMOLEngine {
    /// Dismiss: `set_notice name, 1`. The version bump re-reads the sets, which hides
    /// the notice.
    func dismissSetNotice(_ set: SetEntry) {
        runPythonQuiet("from pymol import cmd as _c\n_c.set_notice(\(Self.pythonLiteral(set.name)), 1)")
    }

    /// "Stage N starred": `set_stage name, starred`, whose budget check is the one
    /// every other path answers to. Staging clears the notice.
    func stageStarred(_ set: SetEntry) {
        runPython("from pymol import appkit_sets as _s\n"
                  + "_s.stage_entries(\(Self.pythonLiteral(set.name)), 'starred')")
    }
}
#endif

// SetNoticeBanner.swift — the one-line strip over a set's tab in the Data drawer.
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
// Its own file, and one hook in `DataDrawer.tabHalf`, so the drawer's table and layout
// code (in flight elsewhere) is not touched. When it shows it takes `height` from the
// drawer's content; the drawer's layout budget has to charge that.

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
        return SetNoticeModel(text: text, starredToStage: starred,
                              stageRefusal: starred > 0 ? budget.stageRefusal(starred) : nil,
                              view: set.views.last)
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
        if let model = SetNoticeModel.make(set: set, rows: engine.setRows) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: set.notice?.kind == SetNotice.recoveredKind
                          ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(PanelTheme.headerColor)
                    Text(model.text)
                        .font(.system(size: 10))
                        .foregroundColor(PanelTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(model.text)
                    if model.showsStage {
                        Button(model.stageTitle) { engine.stageStarred(set) }
                            .font(.system(size: 10))
                            .controlSize(.small)
                            .disabled(model.stageRefusal != nil)
                            .help(model.stageRefusal
                                  ?? "Put the starred entries back in the scene (set_stage \(set.name), starred)")
                        if let refusal = model.stageRefusal {
                            Text("over budget")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(PanelTheme.atomTranspColor)
                                .help(refusal)
                        }
                    }
                    if let view = model.view, let title = model.applyTitle {
                        Button(title) { engine.applySetView(set, view) }
                            .font(.system(size: 10))
                            .controlSize(.small)
                            .help("Apply the saved view's filter, sort and columns")
                    }
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

    /// "Stage N starred": `set_stage name, starred`, whose budget check is the one
    /// every other path answers to. Staging clears the notice.
    func stageStarred(_ set: SetEntry) {
        runPython("from pymol import appkit_sets as _s\n"
                  + "_s.stage_entries(\(Self.pythonLiteral(set.name)), 'starred')")
    }
}
#endif

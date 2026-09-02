import SwiftUI

/// A selection text box with optional affordances that FILL it — the one form every
/// RayMol tool uses to ask "which structure / which residues" (#371).
///
/// Predict asks with `sequence / selection` plus an object dropdown; Design Backbone
/// asks with `target` plus the same dropdown and `hotspots` plus a scope button.
/// Design asked with a dropdown and nothing else, which is why this exists: the
/// FIELD is the input of record — it takes any selection expression — and the
/// dropdown or scope button is a convenience for filling it, never the only way in.
///
/// Deliberately non-generic (an `objects` list and an optional `scope` closure rather
/// than a `@ViewBuilder` accessory): every call site wants one of those two
/// accessories, and the concrete form keeps the body's type simple enough for the
/// Swift type-checker in the already-large views that host it.
struct SelectionInputField: View {
    let placeholder: String
    @Binding var text: String
    /// Accessibility identifier for the text box; the accessories derive theirs from
    /// it (`<id>.menu`, `<id>.scope`) so a UI test can drive all three.
    let identifier: String
    /// Objects the dropdown offers. Empty (the default) = no dropdown.
    var objects: [String] = []
    /// The object currently in use, ticked in the dropdown. nil = nothing ticked.
    var current: String? = nil
    /// When non-nil, a `scope` button that means "read the live selection" — the
    /// peer of Binder Design's hotspots button.
    var scope: (() -> Void)? = nil
    /// A DEFINITE width, never `minWidth` (the lesson BinderDesignBar learned the
    /// hard way): a TextField is greedy, so in a docked bar `minWidth` lets these
    /// absorb every spare point and push the controls that matter into a huddle on
    /// the right.
    var width: CGFloat = 150
    /// Tooltips, since "a loaded object" and "the current selection" mean slightly
    /// different things per tool (a target vs hotspots vs a design region).
    var menuHelp: String = "Use a loaded object"
    var scopeHelp: String = "Use the current selection"
    /// Re-apply on every keystroke rather than only on Return. For a tool whose
    /// `apply` is cheap validation (Binder Design re-prices its estimate); Design's
    /// apply focuses a structure or rewrites 'sele', so it waits for Return.
    var applyOnChange: Bool = false
    /// Commit the field: on Return, and whenever an accessory fills it.
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: width)
                .onSubmit(apply)
                .onChange(of: text) { if applyOnChange { apply() } }
                .accessibilityIdentifier(identifier)
            if !objects.isEmpty { objectMenu }
            if let scope { scopeButton(scope) }
        }
    }

    private var objectMenu: some View {
        Menu {
            ForEach(objects, id: \.self) { obj in
                Button {
                    text = obj
                    apply()
                } label: {
                    if obj == current {
                        Label(obj, systemImage: "checkmark")
                    } else {
                        Text(obj)
                    }
                }
            }
        } label: {
            Image(systemName: "cube")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(menuHelp)
        .accessibilityIdentifier(identifier + ".menu")
    }

    private func scopeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "scope")
        }
        .buttonStyle(.plain)
        .help(scopeHelp)
        .accessibilityIdentifier(identifier + ".scope")
    }
}

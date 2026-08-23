#if os(macOS)
import SwiftUI

/// The minimal entry point for backbone design (#342): pick a target, name the interface
/// residues, say how long, generate.
///
/// A SHEET rather than a mode, deliberately. Every other item in the Tools menu toggles an
/// interaction mode because every other one changes what a click in the viewport does; this
/// one does not — the picking it needs is the ordinary selection, which already works
/// everywhere. Adding a fifth mutually-exclusive mode to buy nothing would make Design mode
/// and this one fight over the viewport for no reason.
///
/// Deliberately thin. It composes a `design_backbone` command and hands it to the engine;
/// the validation, the refusals and the wording all live in `pymol.designing`, which is
/// where they are testable. A field's job here is to be typed into, not to second-guess
/// what the command will say about it.
///
/// **The word "binder" appears nowhere.** A generated chain is a designed backbone until it
/// has been refolded and passed an interface gate, and neither happens here.
struct DesignBackboneSheet: View {

    @EnvironmentObject private var engine: PyMOLEngine
    @Environment(\.dismiss) private var dismiss

    /// Prefilled with `sele`, because that is what the viewport writes and what Design
    /// mode's picking writes: click residues, open this, and the hotspots are already right.
    @State private var target = "sele"
    @State private var hotspots = "sele"
    @State private var length = 60
    @State private var count = 1
    @State private var seedText = ""

    /// The last thing the engine was asked to run, shown so a user can see the command that
    /// was issued and re-run or adapt it from the console. Not a status: the tray owns that.
    @State private var issued = ""

    private var lengthRange: ClosedRange<Int> { 1 ... 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Design a backbone")
                .font(.headline)
            Text("Generates a new chain against a target structure. The result is one "
                 + "object holding the target and the designed chain together, with the "
                 + "target exactly where it already is.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Target", text: $target)
                    .accessibilityIdentifier("designBackbone.target")
                TextField("Hotspots", text: $hotspots)
                    .accessibilityIdentifier("designBackbone.hotspots")
                Stepper("Length: \(length) residues", value: $length, in: lengthRange)
                    .accessibilityIdentifier("designBackbone.length")
                Stepper("Designs: \(count)", value: $count, in: 1 ... 10)
                    .accessibilityIdentifier("designBackbone.count")
                TextField("Seed (blank = random)", text: $seedText)
                    .accessibilityIdentifier("designBackbone.seed")
            }
            .formStyle(.grouped)

            // Said before the run, not after: on a real target this is minutes per design,
            // and a user who learns that from a progress bar has already committed.
            Label("Minutes per design on a full-length target, and \(count) "
                  + "\(count == 1 ? "design runs" : "designs run") one after another. "
                  + "Watch or cancel it in the progress tray.",
                  systemImage: "clock")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !issued.isEmpty {
                Text(issued)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.isEmpty || hotspots.isEmpty)
                    .accessibilityIdentifier("designBackbone.generate")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func generate() {
        let command = Self.command(target: target, hotspots: hotspots, length: length,
                                   count: count, seedText: seedText)
        issued = command
        // Through the command channel, so it lands in the console history like anything
        // typed there -- which is what lets a user adapt and re-run it. Every refusal
        // `pymol.designing` raises is then reported the way every other command's is,
        // rather than being duplicated into a second error surface here.
        engine.runCommand(command)
    }

    /// The `design_backbone` command line for these fields.
    ///
    /// Static and pure so the quoting is unit-testable without a view. Quoting matters:
    /// a selection contains spaces and PyMOL's parser splits arguments on COMMAS, so a
    /// selection like `chain A and resi 1-40` is one argument and needs no quotes, while a
    /// selection containing a comma cannot be passed at all. Commas are stripped rather
    /// than escaped, because there is no escape for them at this layer -- and silently
    /// sending half a selection would design against the wrong thing.
    static func command(target: String, hotspots: String, length: Int, count: Int,
                        seedText: String) -> String {
        var parts = ["design_backbone rfd3",
                     sanitise(target),
                     sanitise(hotspots),
                     "length=\(length)"]
        if count != 1 { parts.append("n_designs=\(count)") }
        if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) {
            parts.append("seed=\(seed)")
        }
        return parts.joined(separator: ", ")
    }

    /// A selection safe to put in one comma-separated argument slot.
    static func sanitise(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

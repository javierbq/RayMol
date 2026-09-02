#if os(macOS)
import SwiftUI

/// Docked Binder Design form (macOS), raised under the alignment when
/// `engine.binderDesignMode` is on — the peer of ``PredictBar``. Composes
/// `cmd.binder_design` via ``BinderDesignController``.
///
/// A BAR and a MODE, not a sheet, because that is what every other tool here is: Predict
/// takes a selection plus options and a Run button in exactly this shape, and a modal for
/// the one tool that generates rather than folds would read as a different kind of thing
/// when it is the same kind of thing.
///
/// **The TOOL is called "Binder Design"; its OUTPUT is never called a binder.** Naming the
/// task is a claim about what RFdiffusion3 is for, which is true. Naming the result would
/// be a claim that the chain binds, which generation alone does not license — so object
/// names, metric keys and every string describing what came back say "designed backbone".
///
/// The split runs through the SYMBOLS too, and that is the quickest way to read which
/// side of it a name is on: everything naming the tool carries the tool's name
/// (`binder_design`, ``BinderDesignController``, `engine.binderDesignMode`), and
/// everything naming a result does not (`rfd3_design_<key>`, `design_ca_ca_mean`,
/// "Designing <object>"). `RFD3RuntimeTests.testNoUserFacingStringCallsTheOutputABinder`
/// enforces exactly that split.
struct BinderDesignBar: View {
    @ObservedObject var controller: BinderDesignController
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            mainRow
            if showAdvanced { Divider().opacity(0.3); advancedRow }
        }
        .background(theme.active.panelBackground.color)
        .tint(theme.active.accent.color)
    }

    // Row 1: the resolved target, or what is wrong with it, or the hint.
    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            if let message = controller.runError ?? controller.resolveError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundColor(.orange).lineLimit(2)
            } else if let t = controller.target {
                // What the run will actually design against, in the engine's own terms --
                // `residues` is AFTER the unreadable ones were excluded, which is the
                // number that matters and the one a user cannot get from the selection.
                // "unguided" rather than "0 hotspots": zero is a legitimate mode with a
                // real consequence -- the sampler starts at the target's centre of mass
                // -- and naming it is the difference between a setting and an accident.
                Text("chain \(t.chain.isEmpty ? "·" : t.chain) · \(t.residues) res · "
                     + (t.hotspots == 0 ? "unguided"
                        : "\(t.hotspots) hotspot\(t.hotspots == 1 ? "" : "s")")
                     + " · state \(t.state)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            } else {
                Text("Pick a target selection. Interface residues are optional — without"
                     + " them the design is placed freely.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
            }
            Spacer(minLength: 0)
            Button { engine.setBinderDesignMode(false) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            }
            .buttonStyle(.plain).accessibilityLabel("Close Binder Design")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // Row 2: target + object picker + hotspots + length + count + advanced + Generate.
    private var mainRow: some View {
        HStack(spacing: 8) {
            // Both boxes are SelectionInputField, the form shared with Design (#371),
            // so the tools that ask "which structure / which residues" ask it once.
            // The widths stay DEFINITE, never `minWidth` — that lesson is now recorded
            // on the shared view: a TextField is greedy, and with `minWidth` these two
            // absorbed every spare point in the bar, growing the target box to about
            // half the row and pushing the controls that matter into a huddle on the
            // right. A definite width plus the Spacer below gives that space back.
            SelectionInputField(
                placeholder: "target selection",
                text: $controller.targetText,
                identifier: "binderDesign.target",
                objects: engine.objects.filter { !$0.isSelection }.map(\.name),
                width: 150,
                applyOnChange: true,          // the estimate re-prices as you type
                apply: { controller.inputChanged() })

            // Hotspots are a selection, not a residue list -- so they compose with
            // `sele` and with anything else that selects atoms.
            SelectionInputField(
                placeholder: "hotspots (optional)",
                text: $controller.hotspotsText,
                identifier: "binderDesign.hotspots",
                scope: { controller.hotspotsText = "sele" },
                width: 110,
                scopeHelp: "Use the current selection as hotspots",
                applyOnChange: true,
                apply: { controller.inputChanged() })

            if controller.availableGenerators.count > 1 {
                Picker("", selection: $controller.generator) {
                    ForEach(controller.availableGenerators) { Text($0.id).tag($0.id) }
                }
                .labelsHidden().frame(width: 90)
                .onChange(of: controller.generator) { controller.inputChanged() }
            }

            SteppedNumberField(value: $controller.length, range: 1...150, suffix: "res",
                               width: 46, identifier: "binderDesign.length",
                               help: "Residues in the generated chain")

            SteppedNumberField(value: $controller.nDesigns, range: 1...10, suffix: "×",
                               width: 34, identifier: "binderDesign.count",
                               help: "Independent designs; each is a full run")

            Toggle("Live", isOn: $controller.liveView)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("binderDesign.liveView")
                .help("Watch the chain diffuse: the result object animates through the "
                      + "rollout and ends on the finished design")

            // Only meaningful while Live is on, so it is disabled rather than hidden --
            // hiding it would reflow the bar every time Live is toggled, and a greyed
            // control says "not applicable right now" where a missing one says nothing.
            // Its value survives being greyed; see `BinderDesignController.keepFrames`.
            Toggle("Keep frames", isOn: $controller.keepFrames)
                .toggleStyle(.checkbox)
                .disabled(!controller.liveView)
                .accessibilityIdentifier("binderDesign.keepFrames")
                .help("Keep every captured frame as a state you can scrub afterwards. "
                      + "Off, the run animates the same way but leaves just the "
                      + "finished design.")

            Button { showAdvanced.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Advanced options")

            Spacer(minLength: 0)

            Button("Generate") { controller.run() }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canRun)
                .accessibilityIdentifier("binderDesign.generate")
                // Said on the control itself, because it is the last thing touched before
                // committing to minutes of GPU work.
                .help("Minutes per design on a full-length target; watch or cancel it in "
                      + "the progress tray")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // Row 3 (Advanced): schedule / seed / name.
    private var advancedRow: some View {
        HStack(spacing: 10) {
            labeled("diffuse") {
                SteppedNumberField(value: $controller.diffusionSteps, range: 10...500,
                                   step: 10, suffix: "", width: 46,
                                   identifier: "binderDesign.diffusionSteps",
                                   help: "Reverse-diffusion steps")
            }
            labeled("recycle") {
                SteppedNumberField(value: $controller.recyclingSteps, range: 1...10,
                                   suffix: "", width: 34,
                                   identifier: "binderDesign.recyclingSteps",
                                   help: "Recycling iterations")
            }
            // Outlined in red rather than silently corrected: Generate is disabled while
            // the seed does not parse (see `BinderDesignController.seedIsValid`), so
            // without a visible mark the button would just be dead with nothing saying why.
            labeled("seed") { TextField("auto", text: $controller.seedText)
                .frame(width: 60).textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.red, lineWidth: controller.seedIsValid ? 0 : 1))
                .help(controller.seedIsValid
                      ? "Whole number for a reproducible run; empty for a fresh one"
                      : "Not a whole number — clear it for a fresh random seed") }
            labeled("name") { TextField("auto", text: $controller.resultName)
                .frame(width: 110).textFieldStyle(.roundedBorder) }
            Spacer(minLength: 0)
            Text(controller.command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.active.panelText.color.opacity(0.45))
                .lineLimit(1).truncationMode(.head).textSelection(.enabled)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func labeled<V: View>(_ t: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 3) {
            Text(t).foregroundColor(theme.active.panelText.color.opacity(0.6)); v()
        }
    }
}

/// A whole number that can be TYPED or stepped.
///
/// The bar's numbers were steppers alone, so reaching 150 residues from 60 was ninety
/// clicks. A text box beside the arrows is the ordinary macOS answer, and the two stay in
/// step because they drive the same `value` binding — the box mirrors it, never leads it.
///
/// The typing rules live in ``BinderDesignController/committed(_:into:fallback:)`` so
/// they are unit-testable without a view. What is decided HERE is *when* they run:
///
/// * **On Return and on losing focus, identically.** One code path, deliberately — a field
///   that commits on Return but discards on click-away is the trap where a user types 120,
///   clicks Generate, and gets 60. Clicking Generate takes focus off the box, so the blur
///   commit lands before the button's action.
/// * **Never while typing.** Committing per keystroke would clamp "1" to the lower bound
///   on the way to "120", so the box would fight the user mid-number.
/// * **The committed value is written straight back into the box**, so what is displayed is
///   always what will run — a clamp is visible rather than silent.
private struct SteppedNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Trailing unit shown after the box ("res", "×"). Empty for a bare number.
    var suffix: String = ""
    let width: CGFloat
    let identifier: String
    let help: String

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .focused($focused)
                .accessibilityIdentifier(identifier + ".field")
                .onSubmit { commit() }
                .onChange(of: focused) { if !focused { commit() } }
            if !suffix.isEmpty { Text(suffix).font(.system(size: 11)) }
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .accessibilityIdentifier(identifier)
        }
        .help(help)
        .onAppear { text = String(value) }
        // The stepper (or anything else that sets the binding) writes through to the box.
        .onChange(of: value) { text = String(value) }
    }

    private func commit() {
        let settled = BinderDesignController.committed(text, into: range, fallback: value)
        value = settled
        // Explicit rather than left to `onChange(of: value)`: a rejected entry ("abc")
        // settles on the value the field already had, so the binding does not change and
        // that observer never fires — but the box is still showing "abc".
        text = String(settled)
    }
}
#endif

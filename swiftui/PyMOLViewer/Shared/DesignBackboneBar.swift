#if os(macOS)
import SwiftUI

/// Docked Design Backbone form (macOS), raised under the alignment when
/// `engine.designBackboneMode` is on — the peer of ``PredictBar``. Composes
/// `cmd.design_backbone` via ``DesignBackboneController``.
///
/// A BAR and a MODE, not a sheet, because that is what every other tool here is: Predict
/// takes a selection plus options and a Run button in exactly this shape, and a modal for
/// the one tool that generates rather than folds would read as a different kind of thing
/// when it is the same kind of thing.
///
/// **The word "binder" appears nowhere.** A generated chain is a designed backbone until it
/// has been refolded and passed an interface gate, and this bar is where a user first meets
/// it.
struct DesignBackboneBar: View {
    @ObservedObject var controller: DesignBackboneController
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
                Text("chain \(t.chain.isEmpty ? "·" : t.chain) · \(t.residues) res · "
                     + "\(t.hotspots) hotspot\(t.hotspots == 1 ? "" : "s")"
                     + " · state \(t.state)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            } else {
                Text("Pick a target selection and the interface residues to engage.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
            }
            Spacer(minLength: 0)
            Button { engine.setDesignBackboneMode(false) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            }
            .buttonStyle(.plain).accessibilityLabel("Close design backbone")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // Row 2: target + object picker + hotspots + length + count + advanced + Generate.
    private var mainRow: some View {
        HStack(spacing: 8) {
            TextField("target selection", text: $controller.targetText)
                .textFieldStyle(.roundedBorder).frame(minWidth: 140)
                .accessibilityIdentifier("designBackbone.target")
                .onSubmit { controller.inputChanged() }
                .onChange(of: controller.targetText) { controller.inputChanged() }

            Menu {
                ForEach(engine.objects.filter { !$0.isSelection }, id: \.name) { o in
                    Button(o.name) { controller.targetText = o.name }
                }
            } label: { Image(systemName: "cube") }
            .menuIndicator(.hidden).help("Use a loaded object")

            TextField("hotspots", text: $controller.hotspotsText)
                .textFieldStyle(.roundedBorder).frame(minWidth: 110)
                .accessibilityIdentifier("designBackbone.hotspots")
                .onSubmit { controller.inputChanged() }
                .onChange(of: controller.hotspotsText) { controller.inputChanged() }

            // A selection, not a residue list -- so it composes with `sele` and with
            // anything else that selects atoms.
            Button { controller.hotspotsText = "sele" } label: { Image(systemName: "scope") }
                .buttonStyle(.plain).help("Use the current selection as hotspots")

            if controller.availableGenerators.count > 1 {
                Picker("", selection: $controller.generator) {
                    ForEach(controller.availableGenerators) { Text($0.id).tag($0.id) }
                }
                .labelsHidden().frame(width: 90)
                .onChange(of: controller.generator) { controller.inputChanged() }
            }

            Stepper("\(controller.length) res", value: $controller.length, in: 1...150)
                .fixedSize().help("Residues in the generated chain")
                .accessibilityIdentifier("designBackbone.length")

            Stepper("×\(controller.nDesigns)", value: $controller.nDesigns, in: 1...10)
                .fixedSize().help("Independent designs; each is a full run")
                .accessibilityIdentifier("designBackbone.count")

            Button { showAdvanced.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Advanced options")

            Button("Generate") { controller.run() }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canRun)
                .accessibilityIdentifier("designBackbone.generate")
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
            labeled("diffuse") { Stepper("\(controller.diffusionSteps)",
                value: $controller.diffusionSteps, in: 10...500, step: 10).fixedSize() }
            labeled("recycle") { Stepper("\(controller.recyclingSteps)",
                value: $controller.recyclingSteps, in: 1...10).fixedSize() }
            labeled("seed") { TextField("auto", text: $controller.seedText)
                .frame(width: 60).textFieldStyle(.roundedBorder) }
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
#endif

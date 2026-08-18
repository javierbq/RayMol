#if os(macOS)
import SwiftUI

/// Docked Predict form (macOS), raised under the alignment when engine.predictMode is
/// on — the peer of DesignOverlayView. Composes cmd.predict via PredictController.
struct PredictBar: View {
    @ObservedObject var controller: PredictController
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            if let w = controller.pendingSizeWarning { sizeWarningRow(w) }
            mainRow
            if controller.useMSA && selectedSupportsMSA && !controller.chains.isEmpty {
                Divider().opacity(0.3)
                msaRow
            }
            if showAdvanced { Divider().opacity(0.3); advancedRow }
        }
        .background(theme.active.panelBackground.color)
        .tint(theme.active.accent.color)
        .onAppear { controller.refresh() }
        .onChange(of: controller.inputText) { _ in controller.inputChanged() }
    }

    private var selectedSupportsMSA: Bool {
        controller.availablePredictors.first { $0.id == controller.predictor }?.msa ?? false
    }

    // Row 1: resolved chains / errors / phase.
    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            switch controller.phase {
            case .idle:
                if let e = controller.resolveError {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundColor(.orange).lineLimit(1)
                } else if !controller.chains.isEmpty {
                    Text(controller.chains.map { "\($0.id)·\($0.length)" }
                            .joined(separator: "  "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.active.panelText.color.opacity(0.6))
                } else {
                    Text("Paste a sequence, a selection, or pick an object.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.5))
                }
            case .searching(let n):
                ProgressView().scaleEffect(0.6)
                Text("Building \(n) alignment\(n == 1 ? "" : "s")…").font(.system(size: 11))
            case .predicting:
                ProgressView().scaleEffect(0.6)
                Text("Prediction submitted — see the progress tray.").font(.system(size: 11))
            case .error(let m):
                Label(m, systemImage: "xmark.octagon").font(.system(size: 11))
                    .foregroundColor(.red).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { engine.setPredictMode(false) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            }
            .buttonStyle(.plain).accessibilityLabel("Close predict")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // Row 1b: size warning + confirm/cancel.
    @ViewBuilder
    private func sizeWarningRow(_ w: PredictSizeWarning) -> some View {
        let fmt: (Int) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
        VStack(alignment: .leading, spacing: 4) {
            Text("Needs about \(fmt(w.estimatedBytes)) — close to this device's limit of \(fmt(w.availableBytes)).")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Run anyway") { controller.confirmPendingWarning() }
                    .font(.system(size: 12, weight: .semibold)).buttonStyle(.plain)
                Button("Cancel") { controller.cancelPendingWarning() }
                    .font(.system(size: 12)).buttonStyle(.plain)
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // Row 2: input field + object picker + model + n_models + Use MSA + Advanced + Run.
    private var mainRow: some View {
        HStack(spacing: 8) {
            TextField("sequence / selection", text: $controller.inputText)
                .textFieldStyle(.roundedBorder).frame(minWidth: 160)

            Menu {
                ForEach(engine.objects.filter { !$0.isSelection }, id: \.name) { o in
                    Button(o.name) { controller.inputText = o.name }
                }
            } label: { Image(systemName: "cube") }
            .menuIndicator(.hidden).help("Use a loaded object")

            Picker("", selection: $controller.predictor) {
                ForEach(controller.availablePredictors) { Text($0.id).tag($0.id) }
            }
            .labelsHidden().frame(width: 110)

            Stepper("×\(controller.nModels)", value: $controller.nModels, in: 1...20)
                .fixedSize()

            Toggle("MSA", isOn: $controller.useMSA)
                .toggleStyle(.checkbox).disabled(!selectedSupportsMSA)
                .help(selectedSupportsMSA ? "Search alignments for the chosen chains"
                      : "This model folds single-sequence")

            Button { showAdvanced.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Advanced options")

            Button("Run") { controller.run() }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var canRun: Bool {
        !controller.predictor.isEmpty && !controller.chains.isEmpty
            && controller.resolveError == nil
            && { if case .searching = controller.phase { return false }; return true }()
    }

    // Row 3: which chains get an MSA + a privacy note.
    private var msaRow: some View {
        HStack(spacing: 8) {
            Text("MSA for:").font(.system(size: 11))
                .foregroundColor(theme.active.panelText.color.opacity(0.7))
            ForEach(controller.chains) { ch in
                Toggle(ch.id, isOn: Binding(
                    get: { controller.msaChains.contains(ch.id) },
                    set: { on in
                        if on { controller.msaChains.insert(ch.id) }
                        else { controller.msaChains.remove(ch.id) }
                    }))
                    .toggleStyle(.button).controlSize(.small)
            }
            Spacer(minLength: 0)
            Text("Sequences are sent to \(serverLabel).")
                .font(.system(size: 10)).foregroundColor(.orange.opacity(0.9))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var serverLabel: String {
        controller.server.isEmpty ? "the ColabFold MSA server" : controller.server
    }

    // Row 4 (Advanced): recycling / diffusion / seed / msa_depth / mode / name / server.
    private var advancedRow: some View {
        HStack(spacing: 10) {
            labeled("recycle") { Stepper("\(controller.recyclingSteps)",
                value: $controller.recyclingSteps, in: 1...10).fixedSize() }
            labeled("diffuse") { Stepper("\(controller.diffusionSteps)",
                value: $controller.diffusionSteps, in: 10...500, step: 10).fixedSize() }
            labeled("seed") { TextField("auto", text: $controller.seedText)
                .frame(width: 60).textFieldStyle(.roundedBorder) }
            labeled("depth") { TextField("auto", text: $controller.msaDepthText)
                .frame(width: 60).textFieldStyle(.roundedBorder) }
            labeled("name") { TextField("auto", text: $controller.resultName)
                .frame(width: 90).textFieldStyle(.roundedBorder) }
            Spacer(minLength: 0)
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

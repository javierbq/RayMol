#if os(iOS)
import SwiftUI

/// Compact Predict form for iPhone — the peer of ``DesignCompactPanel``, and the iOS
/// counterpart of ``PredictBar``.
///
/// ``PredictBar`` is not reused here. It is a docked macOS form of up to four
/// non-scrolling rows carrying two `Stepper`s, four `TextField`s, a `Picker`, and a
/// `.checkbox` Toggle across roughly 700 pt of width; an iPhone has ~390, and
/// `.toggleStyle(.checkbox)` does not exist on iOS at all. Shrinking it would produce a
/// row of 20 pt hit targets.
///
/// So this keeps **two docked rows** — status, then input + predictor + Run — and moves
/// every set-once control into a sheet, exactly the split `DesignCompactPanel` makes and
/// for the same reason. What stays docked is what is touched per run; what moves to the
/// sheet is what is set once per session.
///
/// The MSA chain row is docked but conditional, appearing only when the selected model
/// supports alignments AND the user asked for them — on a phone the common case is the
/// single-chain, no-MSA fold this port targets, and an always-present row would cost a
/// third of the panel to show one disabled toggle.
///
/// iPad and macOS keep ``PredictBar``; see ContentView.predictModeBar.
struct PredictCompactPanel: View {
    @ObservedObject var controller: PredictController
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            PredictBackgroundNotice(engine: engine, theme: theme)
            statusRow
            if let w = controller.pendingSizeWarning { sizeWarningRow(w) }
            inputRow
            if controller.useMSA && selectedSupportsMSA && !controller.chains.isEmpty {
                Divider().opacity(0.3)
                msaRow
            }
        }
        .background(theme.active.panelBackground.color)
        .tint(theme.active.accent.color)
        .onChange(of: controller.inputText) { _ in controller.inputChanged() }
        .sheet(isPresented: $showSettings) {
            PredictSettingsSheet(controller: controller)
        }
    }

    private var selectedSupportsMSA: Bool {
        controller.availablePredictors.first { $0.id == controller.predictor }?.msa ?? false
    }

    // MARK: - Row 1: resolved chains / phase / errors

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            statusContent
            Spacer(minLength: 0)
            Button { showSettings = true } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundColor(theme.active.panelText.color.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Predict settings")

            Button { engine.setPredictMode(false) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit predict mode")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var statusContent: some View {
        switch controller.phase {
        case .idle:
            if let e = controller.resolveError {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundColor(.orange).lineLimit(2)
            } else if !controller.chains.isEmpty {
                // Chains AND the total, because the total is what PredictSizeGuard and
                // the runtime's own token cap are both measured in — a user who has to
                // add "A·64 B·71" in their head to know why a run was refused has been
                // shown the wrong number.
                Text(controller.chains.map { "\($0.id)·\($0.length)" }
                        .joined(separator: "  ")
                     + "  ·  \(totalResidues) res")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
                    .lineLimit(1)
            } else {
                Text("Paste a sequence, or pick an object.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
            }
        case .searching(let n):
            ProgressView().scaleEffect(0.6)
            Text("Building \(n) alignment\(n == 1 ? "" : "s")…").font(.system(size: 11))
        case .predicting:
            // Unreachable: submitPredict() returns the controller to .idle the moment a
            // job is handed off, and the ProgressTray is the single source of truth for
            // a running fold. Kept for switch exhaustiveness, rendering nothing.
            EmptyView()
        case .error(let m):
            Label(m, systemImage: "xmark.octagon").font(.system(size: 11))
                .foregroundColor(.red).lineLimit(3)
        }
    }

    private var totalResidues: Int { controller.chains.reduce(0) { $0 + $1.length } }

    // MARK: - Row 1b: size warning

    @ViewBuilder
    private func sizeWarningRow(_ w: PredictSizeWarning) -> some View {
        let fmt: (Int) -> String = {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
        }
        VStack(alignment: .leading, spacing: 6) {
            // Deliberately says "before iOS stops the app" rather than macOS's "this
            // device's limit". On a Mac an over-large fold thrashes; on a phone it is a
            // SIGKILL that takes the unsaved session, and the copy should not be milder
            // than the consequence.
            Text("Needs about \(fmt(w.estimatedBytes)) — this app has about "
                 + "\(fmt(w.availableBytes)) left before iOS stops it. "
                 + "Save your session first.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Run anyway") { controller.confirmPendingWarning() }
                    .font(.system(size: 13, weight: .semibold)).buttonStyle(.plain)
                Button("Cancel") { controller.cancelPendingWarning() }
                    .font(.system(size: 13)).buttonStyle(.plain)
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }

    // MARK: - Row 2: input · object picker · model · Run

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("sequence", text: $controller.inputText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                // A pasted sequence must survive verbatim: autocapitalisation would
                // not hurt (parse_chains upper-cases anyway) but autocorrect and smart
                // quotes rewrite residue letters, and the failure is silent — a
                // corrected sequence still folds, into the wrong thing.
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .submitLabel(.done)

            Menu {
                ForEach(engine.objects.filter { !$0.isSelection }, id: \.name) { o in
                    Button(o.name) { controller.inputText = o.name }
                }
            } label: {
                Image(systemName: "cube").font(.system(size: 15))
                    .foregroundColor(theme.active.panelText.color.opacity(0.8))
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Use a loaded object")

            // One predictor is the norm on iOS (the host advertises "boltz" alone), so
            // this is a menu rather than a segmented picker: it collapses to a single
            // short label instead of reserving width for choices that are not there.
            Menu {
                ForEach(controller.availablePredictors) { p in
                    Button {
                        controller.predictor = p.id
                    } label: {
                        if p.id == controller.predictor {
                            Label(p.id, systemImage: "checkmark")
                        } else {
                            Text(p.id)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(controller.predictor.isEmpty ? "model" : controller.predictor)
                        .font(.system(size: 12)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundColor(theme.active.panelText.color)
                .frame(maxWidth: 96)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Prediction model")

            Button { controller.run() } label: {
                Text("Run")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(canRun ? theme.active.accent.color
                                       : theme.active.panelText.color.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(!canRun)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var canRun: Bool {
        !controller.predictor.isEmpty && !controller.chains.isEmpty
            && controller.resolveError == nil
            && controller.pendingSizeWarning == nil
            && { switch controller.phase {
                 case .searching, .predicting: return false
                 default: return true
                 } }()
    }

    // MARK: - Row 3: which chains get an MSA

    private var msaRow: some View {
        HStack(spacing: 8) {
            Text("MSA:").font(.system(size: 11))
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
            Text("Sent to \(serverLabel).")
                .font(.system(size: 10)).foregroundColor(.orange.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var serverLabel: String {
        controller.server.isEmpty ? "the ColabFold server" : controller.server
    }
}

// MARK: - Settings sheet

/// The set-once half of the iPhone Predict form: everything ``PredictBar`` keeps in its
/// Advanced row, plus the two controls (`MSA`, `×n models`) that are docked on macOS but
/// do not fit a phone's main row.
///
/// Sectioned by what the setting COSTS rather than by what it configures, because on a
/// phone that is the question actually being asked. "Sampling" trades time; "Alignment"
/// trades both time and memory and sends the sequence off-device; "Output" is free.
struct PredictSettingsSheet: View {
    @ObservedObject var controller: PredictController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                samplingSection
                alignmentSection
                outputSection
            }
            .navigationTitle("Predict settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var selectedSupportsMSA: Bool {
        controller.availablePredictors.first { $0.id == controller.predictor }?.msa ?? false
    }

    private var samplingSection: some View {
        Section("Sampling") {
            Stepper("Models  ×\(controller.nModels)",
                    value: $controller.nModels, in: 1...20)
            Stepper("Recycling  \(controller.recyclingSteps)",
                    value: $controller.recyclingSteps, in: 1...10)
            Stepper("Diffusion  \(controller.diffusionSteps)",
                    value: $controller.diffusionSteps, in: 10...500, step: 10)
            HStack {
                Text("Seed")
                Spacer()
                TextField("auto", text: $controller.seedText)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(width: 110)
            }
            Text("Each model is a separate fold. On a phone, one model with the "
                 + "default steps is the fast path — every extra model costs the "
                 + "same time again.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var alignmentSection: some View {
        Section("Alignment") {
            Toggle("Use MSA", isOn: $controller.useMSA)
                .disabled(!selectedSupportsMSA)
            if selectedSupportsMSA {
                Picker("Mode", selection: $controller.msaMode) {
                    ForEach(["env", "all", "env-nofilter", "nofilter"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                HStack {
                    Text("Depth")
                    Spacer()
                    TextField("auto", text: $controller.msaDepthText)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(width: 110)
                }
                HStack {
                    Text("Server")
                    Spacer()
                    TextField("default", text: $controller.server)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .frame(width: 170)
                }
                // Not decoration. Depth is the dimension PredictSizeGuard's own history
                // records it having failed to model — 3.6× optimistic at the ceiling —
                // and on a phone that headroom does not exist to be wrong with.
                Text("An alignment improves accuracy, but it is also the largest "
                     + "single memory cost here and your sequence leaves the device "
                     + "to build it. Single-sequence folding is the tested path on "
                     + "iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("This model folds single-sequence.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var outputSection: some View {
        Section("Output") {
            HStack {
                Text("Name")
                Spacer()
                TextField("auto", text: $controller.resultName)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .frame(width: 170)
            }
        }
    }
}
#endif

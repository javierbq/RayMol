#if RAYMOL_MPNN
import SwiftUI

// MARK: – Compact panel (iPhone)

/// Compact Design panel for iPhone (compact width, either orientation).
///
/// The macOS overlay is five non-scrolling rows wanting roughly 600-700 pt; an
/// iPhone has ~390. Rather than shrink everything, this keeps four docked rows
/// (header, sequence strip, propensity/palette pills, action row) and moves
/// set-once controls into a sheet. `Compare` stays docked on purpose — it is
/// toggled repeatedly while judging a design, unlike the preferences beside it.
///
/// iPad and macOS keep DesignOverlayView; see ContentView.designModeBar.
struct DesignCompactPanel: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Reuse the existing error banner (internal access in ContentView.swift).
            DesignErrorBanner(controller: controller, theme: theme)
            sizeWarningRow
            headerRow
            if !controller.focusResidues.isEmpty {
                // Row 2: 2-row sequence strip
                Divider().opacity(0.3)
                DesignSequenceStripView(controller: controller, theme: theme)
                // Row 3: propensity / palette pills (identical logic to macOS overlay)
                Divider().opacity(0.3)
                DesignPillRow(controller: controller, theme: theme)
                // Row 4: region hint · redesign · revert · edit-session actions
                Divider().opacity(0.3)
                actionRow
            }
        }
        .background(theme.active.panelBackground.color)
        .tint(theme.active.accent.color)
        .sheet(isPresented: $showSettings) {
            DesignSettingsSheet(controller: controller)
        }
    }

    // Row 1: target field + object dropdown · score readout · settings · exit.
    private var headerRow: some View {
        HStack(spacing: 8) {
            // Target field + object dropdown, the same pair as the macOS overlay
            // (#371): typing a selection expression has to be possible on iPhone
            // too, and this is where a 40-residue region is least fun to tap out.
            SelectionInputField(
                placeholder: "target",
                text: $controller.targetText,
                identifier: "design.target",
                objects: controller.allObjects,
                current: controller.focusObject,
                width: 110,
                apply: { controller.applyTarget() })

            if let s = controller.sequenceScore {
                Text(String(format: "%.2f", s))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.55))
            }
            if controller.isScoring || controller.isRescoring { ProgressView().scaleEffect(0.6) }

            Spacer(minLength: 0)

            Button { showSettings = true } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundColor(theme.active.panelText.color.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Design settings")

            Button { engine.setDesignMode(false) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit design mode")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // Row 4: region field · hint (until a region exists) · redesign (region only) ·
    // revert (if snapshot) · spacer · repack (editing) · compare (editing) ·
    // Keep / Discard (editing).
    //
    // Decomposed into leaf properties to keep each expression short for the Swift
    // type-checker, following the pattern in DesignSequenceStripView.seqCols.
    private var actionRow: some View {
        // Horizontally scrollable (#386). A plain HStack here reports a MINIMUM
        // width — the region field is a fixed 100pt and Cmp/Keep/Discard are
        // .fixedSize() — that exceeds an iPhone's ~390pt once an edit session is
        // live. An over-wide row does not merely clip itself: a VStack adopts the
        // width of its widest child, so the whole iPhone stack (title row, rail,
        // viewport, inspector) was displaced sideways and lost its trailing edge
        // off-screen. A ScrollView never reports an oversized ideal width, so the
        // row scrolls and its siblings keep the screen's geometry.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // The region field (#371); writes 'sele', so tapping residues still
                // means exactly what it meant. Scope button = read the live selection.
                SelectionInputField(
                    placeholder: "sele",
                    text: $controller.selectionText,
                    identifier: "design.selection",
                    scope: { controller.useCurrentSelection() },
                    width: 100,
                    apply: { controller.applySelection() })
                if !controller.regionModeActive {
                    Text("or tap 2+")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.5))
                        .lineLimit(1)
                }
                if controller.seleResiduesOffFocus > 0 {
                    Label("\(controller.seleResiduesOffFocus)", systemImage: "eye.slash")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.active.panelText.color.opacity(0.5))
                        .accessibilityLabel(
                            "\(controller.seleResiduesOffFocus) selected residues on other structures, ignored")
                }
                if controller.regionModeActive { redesignButton }
                if controller.redesignSnapshot != nil { revertButton }
                if controller.editing { editControls }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var redesignButton: some View {
        let disabled = controller.paletteAllowed.filter { $0 < 20 }.isEmpty
        return Button { controller.redesignSelection() } label: {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(controller.selectedResidueIndices.count)")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(disabled
                        ? theme.active.panelText.color.opacity(0.25)
                        : theme.active.accent.color,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(
            "Redesign \(controller.selectedResidueIndices.count) residues")
    }

    /// Revert the last region redesign. Shown only when a snapshot exists —
    /// matches the macOS condition (controller.redesignSnapshot != nil).
    private var revertButton: some View {
        Button { controller.revertRedesign() } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11))
                .foregroundColor(theme.active.panelText.color.opacity(0.6))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(theme.active.panelText.color.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Revert redesign")
    }

    // `Compare` stays docked because it is toggled repeatedly while judging a
    // design — unlike the set-once controls that live in the sheet.
    @ViewBuilder
    private var editControls: some View {
        // Manual repack — matches macOS enable/disable condition.
        Button { controller.repackNow() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .foregroundColor(controller.repackDirty
                                 ? theme.active.accent.color
                                 : theme.active.panelText.color.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!controller.repackDirty || controller.isRepacking)
        .accessibilityLabel("Repack sidechains")

        // Compare: give it a compact visible label so the switch is identifiable
        // on a four-control row.
        Toggle(isOn: Binding(get: { controller.compareEnabled },
                             set: { controller.setCompare($0) })) {
            Text("Cmp")
                .font(.system(size: 11))
                .foregroundColor(theme.active.panelText.color.opacity(0.8))
        }
        .fixedSize()
        .accessibilityLabel("Compare with original")

        // Keep/Discard: .fixedSize() so the scroll content sizes them to their
        // labels rather than squeezing the text.
        Button { Task { await controller.keepEditsAwait() } } label: {
            Text("Keep").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .fixedSize()
        Button { controller.discardEdits() } label: {
            Text("Discard")
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // Oversize confirmation rendered inline so it cannot be dismissed by accident
    // while the user is deciding. An alert would be easier to tap away.
    @ViewBuilder
    private var sizeWarningRow: some View {
        if let w = controller.pendingSizeWarning {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "\(w.residueCount) residues needs about "
                    + "\(DesignSizeGuard.formatted(bytes: w.estimatedBytes))"
                    + " — close to this device's limit of "
                    + "\(DesignSizeGuard.formatted(bytes: w.availableBytes))."
                )
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    // .buttonStyle(.plain) + explicit white prevents the panel's
                    // .tint(accent) from rendering accent-on-accent text on some themes.
                    Button("Run anyway") {
                        Task { await controller.confirmPendingWarning() }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    Button("Cancel") { controller.cancelPendingWarning() }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundColor(.white.opacity(0.8))
                    Spacer(minLength: 0)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.9))
        }
    }
}

// MARK: – Settings sheet

/// Set-once Design controls moved off the iPhone dock to keep the viewport large.
/// Presented as a half-sheet; the user can pull it full-screen.
/// Note: no ThemeManager parameter — the Form adapts to system appearance automatically,
/// and an unused @ObservedObject re-renders on every theme publish.
struct DesignSettingsSheet: View {
    @ObservedObject var controller: DesignController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                samplingSection
                structureSection
                colourSection
            }
            .navigationTitle("Design settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    // Extracted to keep the body expression short for the Swift type-checker.
    private var samplingSection: some View {
        Section("Sampling") {
            temperatureRow
            Text("0 picks the most likely residue every time; "
                 + "higher values vary each run.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var temperatureRow: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.2f", controller.designTemperature))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $controller.designTemperature, in: 0...1)
        }
    }

    private var structureSection: some View {
        Section("Structure") {
            Toggle("Auto-repack after each edit",
                   isOn: $controller.autoRepack)
            Toggle("Show all sidechains", isOn: Binding(
                get: { controller.showSidechains },
                set: { controller.setShowSidechains($0) }))
            if controller.compareEnabled {
                Toggle("Side-by-side", isOn: Binding(
                    get: { controller.sideBySide },
                    set: { controller.setSideBySide($0) }))
            }
        }
    }

    private var colourSection: some View {
        Section("Colouring") {
            // Bind via setMeaning so it also calls recolor(focusObject) —
            // the @Published property alone does NOT trigger a recolor.
            Picker("Meaning", selection: Binding(
                get: { controller.colorMeaning },
                set: { controller.setMeaning($0) }
            )) {
                ForEach(DesignColorMeaning.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
        }
    }
}
#endif

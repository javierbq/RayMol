// MorphSheet.swift — the Object panel's "Morph…" sheet (#morph, spec §5.3).
//
// Configures a morph of a multi-state object: frames per model, loop, method,
// sculpting clean-up and rate, with a live summary of what the job will build
// and how much memory it will take. Pure view: the card that presents it owns
// the engine calls (submit, delete) and passes them in as closures, so this
// file has no engine dependency. Laid out like the Timeline's "Play models"
// sheet (TimelinePanel.PlayModelsSheet).
#if os(macOS) || os(iOS)
import SwiftUI
#if os(iOS)
import os
#endif

struct MorphSheet: View {
    /// The object the morph is built FROM. Named in the title even when the
    /// sheet was opened on the morph itself.
    let source: String
    /// The object the job writes: `<source>_morph` for a new morph, the morph's
    /// own name when re-morphing it in place.
    let target: String
    /// Models (states) in `source`.
    let models: Int
    /// Atoms one morph frame holds, for the build-time hint (`buildAtoms(…)`),
    /// or nil when neither the poll nor the inspector has reported one — the
    /// summary then omits the hint rather than show 0.
    let atoms: Int?
    /// Python's bytes per morph frame of `source` (the panel payload's
    /// `morph_bytes_per_frame`), or nil when the poll has not published it — the
    /// summary then omits the memory estimate and the tier is `.ok`.
    let bytesPerFrame: Int?
    /// Movie fps: the rate auto-play uses, so the summary's seconds are real.
    let fps: Double
    /// The settings that built the morph, when the sheet is opened on one.
    let existingSettings: MorphSettings?
    let isMorphObject: Bool
    /// Whether `target` is already loaded, so the job replaces it: a source's
    /// morph restored from a session is rebuilt rather than created.
    var targetExists: Bool = false
    /// Whether the source is known to show a surface or mesh, which the morph
    /// does not carry over (spec §5.5).
    var sourceShowsSurfaceOrMesh: Bool = false
    let onMorph: (MorphSettings) -> Void
    /// "Delete morph": offered on a morph object only.
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var settings: MorphSettings

    init(source: String, target: String, models: Int, atoms: Int?, bytesPerFrame: Int?,
         fps: Double, existingSettings: MorphSettings?, isMorphObject: Bool,
         targetExists: Bool = false,
         sourceShowsSurfaceOrMesh: Bool = false,
         onMorph: @escaping (MorphSettings) -> Void,
         onDelete: (() -> Void)?,
         onCancel: @escaping () -> Void) {
        self.source = source; self.target = target
        self.models = models; self.atoms = atoms; self.bytesPerFrame = bytesPerFrame
        self.fps = fps
        self.existingSettings = existingSettings
        self.isMorphObject = isMorphObject
        self.targetExists = targetExists
        self.sourceShowsSurfaceOrMesh = sourceShowsSurfaceOrMesh
        self.onMorph = onMorph; self.onDelete = onDelete; self.onCancel = onCancel
        _settings = State(initialValue: Self.prefill(saved: MorphSettings.load(),
                                                     existing: existingSettings))
    }

    /// The Steppers' ranges.
    static let framesRange = 2...120
    static let refinementRange = 0...10

    /// What the sheet opens with: the saved defaults with a re-morphed object's
    /// own spec laid over the five sheet fields, clamped to the Steppers' ranges.
    /// The wire spec carries no `movieSmooth`, so taking the whole struct would
    /// reset the Movie tab's toggle on save. A morph made at the command line can
    /// carry e.g. `frames_per_model=200`: unclamped, the Stepper would show a value
    /// it cannot reach and pressing Morph would save it as the new default.
    static func prefill(saved: MorphSettings, existing: MorphSettings?) -> MorphSettings {
        var s = saved
        if let e = existing {
            s.framesPerModel = e.framesPerModel; s.loop = e.loop; s.method = e.method
            s.refinement = e.refinement; s.rate = e.rate
        }
        s.framesPerModel = min(max(s.framesPerModel, framesRange.lowerBound), framesRange.upperBound)
        s.refinement = min(max(s.refinement, refinementRange.lowerBound), refinementRange.upperBound)
        return s
    }

    static let rates: [(label: String, value: String)] = [
        ("Linear", "linear"), ("Sinusoidal", "sinusoidal"),
        ("Ramp up", "ramp up"), ("Ramp down", "ramp down"),
    ]

    var body: some View {
        #if os(macOS)
        content
            .padding(20)
            .frame(width: 380)
        #else
        // The iOS controls are taller than macOS's: title, five control rows, a
        // two- or three-line summary and the buttons come to about 420 pt, so
        // the first detent shows Cancel / Morph (PlayModelsSheet opens its
        // comparable stack at 480). Scrolls rather than clips if a longer
        // summary still overflows it.
        ScrollView { content.padding(20) }
            .presentationDetents([.height(440), .large])
        #endif
    }

    private var content: some View {
        let summary = settings.summary(models: models, atoms: atoms ?? 0,
                                       bytesPerFrame: bytesPerFrame, fps: fps)
        let tier = Self.memoryTier(bytes: summary.bytes, thresholds: Self.currentThresholds())
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Morph \(source)").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(models) models").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            MorphSettingsControls(settings: $settings, showsLoop: true, idPrefix: "morphSheet")

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.summaryLine(summary, models: models, fps: fps, source: source,
                                      target: target, isMorphObject: isMorphObject,
                                      targetExists: targetExists))
                    .foregroundStyle(tier == .ok ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("morphSheet.summary")
                if tier == .refuse {
                    Text("Reduce frames per model or morph fewer models")
                        .foregroundStyle(.orange)
                }
                if sourceShowsSurfaceOrMesh {
                    Text("Surface and mesh are not carried to the morph (too costly per frame)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 11))

            HStack(spacing: 10) {
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Text("Delete morph")
                            #if os(macOS)
                            // A bordered button in a macOS sheet draws the destructive
                            // role grey, and ignores .tint and .foregroundStyle on the
                            // button (checked on macOS 15); the label's own colour is
                            // honoured: red text, as in AppKit alerts.
                            .foregroundColor(.red)
                            #endif
                    }
                    .accessibilityIdentifier("morphSheet.delete")
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("morphSheet.cancel")
                Button("Morph") {
                    settings.save()
                    onMorph(settings)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(tier == .refuse)
                .accessibilityIdentifier("morphSheet.morph")
            }
        }
    }

    // MARK: - Summary (pure, unit-tested)

    enum MemoryTier { case ok, warn, refuse }

    /// The thresholds `morph_jobs.thresholds()` uses, in bytes (spec §5.6, its
    /// figures as floors): on iPhone and iPad 1/4 and 1/2 of what the app may
    /// still allocate (`available`, at least 100 MB and 400 MB; the floors when
    /// unknown), elsewhere 1/16 and 1/4 of the machine's memory (at least 200 MB
    /// and 1 GB). The two sides read their figures independently, so they agree
    /// up to what the app allocated in between.
    static func memoryThresholds(physical: UInt64, available: UInt64?,
                                 iOS: Bool) -> (warn: Double, refuse: Double) {
        if iOS {
            let left = Double(available ?? 0)
            return (max(100e6, left / 4), max(400e6, left / 2))
        }
        let total = Double(physical)
        return (max(200e6, total / 16), max(1e9, total / 4))
    }

    /// The thresholds now: `ProcessInfo.physicalMemory`, and on iOS
    /// `os_proc_available_memory()` (as DesignSizeGuard reads it), read at each
    /// call because the headroom changes as the session grows.
    static func currentThresholds() -> (warn: Double, refuse: Double) {
        #if os(iOS)
        let left = UInt64(os_proc_available_memory())
        return memoryThresholds(physical: ProcessInfo.processInfo.physicalMemory,
                                available: left > 0 ? left : nil, iOS: true)
        #else
        return memoryThresholds(physical: ProcessInfo.processInfo.physicalMemory,
                                available: nil, iOS: false)
        #endif
    }

    /// Where an estimate falls against the thresholds: above `warn` orange, above
    /// `refuse` refused, as `morph_estimate` compares (`>`). An unknown estimate
    /// (`nil`) is `.ok`: the sheet cannot judge it, and `morph_object` enforces
    /// the hard limit itself.
    static func memoryTier(bytes: Int?, thresholds: (warn: Double, refuse: Double)) -> MemoryTier {
        guard let b = bytes.map(Double.init) else { return .ok }
        if b > thresholds.refuse { return .refuse }
        if b > thresholds.warn { return .warn }
        return .ok
    }

    /// The atoms the build-time hint counts: Python's atoms per morph frame of
    /// the source (the panel payload's `morph_atoms_per_frame`, state 1, as
    /// `morph_estimate` counts) when published, else the object's own atom count
    /// (an older bundled Python). The latter is every state's atoms for a
    /// discrete object, 20 times too many for 2kpo made discrete.
    static func buildAtoms(perFrame: Int?, objectAtoms: Int?) -> Int? {
        perFrame ?? objectAtoms
    }

    /// The build-time hint (spec §5.2), shown only above 10 s: "≈ 75 s to build",
    /// "≈ 2 min to build" from 100 s.
    static func buildTime(_ seconds: Double) -> String? {
        guard seconds > 10 else { return nil }
        if seconds < 100 { return "≈ \(Int(seconds.rounded())) s to build" }
        return "≈ \(Int((seconds / 60).rounded())) min to build"
    }

    /// "20 models → 300 frames · 10 s at 30 fps · ≈ 867 MB · creates 2kpo_morph,
    /// hides 2kpo · ≈ 28 s to build". Without Python's bytes per frame the
    /// estimate is dropped; without an atom count, the build time.
    /// From a source whose morph is already loaded (`targetExists`) it reads
    /// "rebuilds 2kpo_morph, hides 2kpo"; on the morph itself, "rebuilds 2kpo_morph".
    static func summaryLine(_ s: MorphSettings.Summary, models: Int, fps: Double,
                            source: String, target: String,
                            isMorphObject: Bool, targetExists: Bool = false) -> String {
        var parts = ["\(models) models → \(s.frames) frames",
                     "\(MorphSettings.number(s.seconds)) s at "
                        + "\(MorphSettings.number(max(fps, 1))) fps"]
        if let bytes = s.bytes { parts.append(MorphSettings.megabytes(bytes)) }
        if isMorphObject {
            parts.append("rebuilds \(target)")
        } else {
            parts.append("\(targetExists ? "rebuilds" : "creates") \(target), hides \(source)")
        }
        if let build = buildTime(s.buildSeconds) { parts.append(build) }
        return parts.joined(separator: " · ")
    }
}

/// The morph controls the Object panel's Morph… sheet and the Movie tab's
/// Play-models sheet share (spec §5.3, §5.7): frames per model, loop, method,
/// clean-up and rate. The Movie path implies loop, so it hides that toggle
/// (`showsLoop` false). Accessibility ids are `<idPrefix>.frames`, `.loop`,
/// `.method`, `.refinement` and `.rate`.
struct MorphSettingsControls: View {
    @Binding var settings: MorphSettings
    var showsLoop: Bool = true
    let idPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Frames per model")
                Spacer()
                Text("\(settings.framesPerModel)").monospacedDigit()
                Stepper("Frames per model", value: $settings.framesPerModel,
                        in: MorphSheet.framesRange)
                    .labelsHidden()
                    .accessibilityIdentifier("\(idPrefix).frames")
            }

            if showsLoop {
                Toggle("Loop back to model 1", isOn: $settings.loop)
                    .tint(TimelineTheme.accent)
                    .accessibilityIdentifier("\(idPrefix).loop")
            }

            Picker("Method", selection: $settings.method) {
                Text("Rigid segments").tag("rigimol")
                Text("Linear").tag("linear")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("\(idPrefix).method")

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Clean-up cycles")
                    Spacer()
                    Text("\(settings.refinement)").monospacedDigit()
                    Stepper("Clean-up cycles", value: $settings.refinement,
                            in: MorphSheet.refinementRange)
                        .labelsHidden()
                        .accessibilityIdentifier("\(idPrefix).refinement")
                }
                Text("sculpting, backbone fixed")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Text("Rate")
                Spacer()
                Picker("Rate", selection: $settings.rate) {
                    ForEach(MorphSheet.rates, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("\(idPrefix).rate")
            }
        }
    }
}
#endif

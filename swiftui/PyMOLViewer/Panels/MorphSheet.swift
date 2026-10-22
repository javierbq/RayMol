// MorphSheet.swift — the Object panel's "Morph…" sheet (#morph, spec §5.3).
//
// Configures a morph of a multi-state object: frames per model, loop, method,
// sculpting clean-up and rate, with a live summary of what the job will build
// and how much memory it will take. Pure view: the card that presents it owns
// the engine calls (submit, delete) and passes them in as closures, so this
// file has no engine dependency. Laid out like the Timeline's "Play models"
// sheet (TimelinePanel.statesConfigSheet).
#if os(macOS) || os(iOS)
import SwiftUI

struct MorphSheet: View {
    /// The object the morph is built FROM. Named in the title even when the
    /// sheet was opened on the morph itself.
    let source: String
    /// The object the job writes: `<source>_morph` for a new morph, the morph's
    /// own name when re-morphing it in place.
    let target: String
    /// Models (states) in `source`.
    let models: Int
    /// Atom count for the memory estimate, or nil when the inspector has not
    /// reported one — the summary then omits the estimate rather than show 0.
    let atoms: Int?
    /// Movie fps: the rate auto-play uses, so the summary's seconds are real.
    let fps: Double
    /// The settings that built the morph, when the sheet is opened on one.
    let existingSettings: MorphSettings?
    let isMorphObject: Bool
    /// Whether the source is known to show a surface or mesh, which the morph
    /// does not carry over (spec §5.5).
    var sourceShowsSurfaceOrMesh: Bool = false
    let onMorph: (MorphSettings) -> Void
    /// "Delete morph": offered on a morph object only.
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var settings: MorphSettings

    init(source: String, target: String, models: Int, atoms: Int?, fps: Double,
         existingSettings: MorphSettings?, isMorphObject: Bool,
         sourceShowsSurfaceOrMesh: Bool = false,
         onMorph: @escaping (MorphSettings) -> Void,
         onDelete: (() -> Void)?,
         onCancel: @escaping () -> Void) {
        self.source = source; self.target = target
        self.models = models; self.atoms = atoms; self.fps = fps
        self.existingSettings = existingSettings
        self.isMorphObject = isMorphObject
        self.sourceShowsSurfaceOrMesh = sourceShowsSurfaceOrMesh
        self.onMorph = onMorph; self.onDelete = onDelete; self.onCancel = onCancel
        // Start from the saved defaults and lay a re-morphed object's own spec over
        // the five sheet fields. The wire spec carries no `movieSmooth`, so taking
        // the whole struct would reset the Movie tab's toggle on save.
        var s = MorphSettings.load()
        if let e = existingSettings {
            s.framesPerModel = e.framesPerModel; s.loop = e.loop; s.method = e.method
            s.refinement = e.refinement; s.rate = e.rate
        }
        _settings = State(initialValue: s)
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
        // Scrolls rather than clips if the iOS controls (taller than macOS's)
        // overflow the detent, so Cancel / Morph always stay reachable.
        ScrollView { content.padding(20) }
            .presentationDetents([.height(360)])
        #endif
    }

    private var content: some View {
        let summary = settings.summary(models: models, atoms: atoms ?? 0, fps: fps)
        let tier = Self.memoryTier(bytes: atoms == nil ? nil : summary.bytes)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Morph \(source)").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(models) models").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Text("Frames per model")
                Spacer()
                Text("\(settings.framesPerModel)").monospacedDigit()
                Stepper("Frames per model", value: $settings.framesPerModel, in: 2...120)
                    .labelsHidden()
                    .accessibilityIdentifier("morphSheet.frames")
            }

            Toggle("Loop back to model 1", isOn: $settings.loop)
                .tint(TimelineTheme.accent)
                .accessibilityIdentifier("morphSheet.loop")

            Picker("Method", selection: $settings.method) {
                Text("Rigid segments").tag("rigimol")
                Text("Linear").tag("linear")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("morphSheet.method")

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Clean-up cycles")
                    Spacer()
                    Text("\(settings.refinement)").monospacedDigit()
                    Stepper("Clean-up cycles", value: $settings.refinement, in: 0...10)
                        .labelsHidden()
                        .accessibilityIdentifier("morphSheet.refinement")
                }
                Text("sculpting, backbone fixed")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Text("Rate")
                Spacer()
                Picker("Rate", selection: $settings.rate) {
                    ForEach(Self.rates, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("morphSheet.rate")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.summaryLine(summary, models: models, fps: fps,
                                      showBytes: atoms != nil, source: source,
                                      target: target, isMorphObject: isMorphObject))
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
                    Button("Delete morph", role: .destructive) { onDelete() }
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

    #if os(iOS)
    static let warnBytes = 100e6, refuseBytes = 400e6
    #else
    static let warnBytes = 200e6, refuseBytes = 1e9
    #endif

    /// Where an estimate falls against the platform thresholds (spec §5.6).
    /// An unknown estimate (`nil`) is `.ok`: the sheet cannot judge it, and
    /// `morph_object` enforces the hard limit itself.
    static func memoryTier(bytes: Int?, warnAbove: Double = warnBytes,
                           refuseAbove: Double = refuseBytes) -> MemoryTier {
        guard let b = bytes.map(Double.init) else { return .ok }
        if b > refuseAbove { return .refuse }
        if b > warnAbove { return .warn }
        return .ok
    }

    /// "20 models → 300 frames · 10 s at 30 fps · ≈ 29 MB · creates 2kpo_morph,
    /// hides 2kpo". `showBytes` false drops the estimate (atom count unknown).
    static func summaryLine(_ s: MorphSettings.Summary, models: Int, fps: Double,
                            showBytes: Bool, source: String, target: String,
                            isMorphObject: Bool) -> String {
        var parts = ["\(models) models → \(s.frames) frames",
                     "\(number(s.seconds)) s at \(number(max(fps, 1))) fps"]
        if showBytes { parts.append(megabytes(s.bytes)) }
        parts.append(isMorphObject ? "rebuilds \(target)"
                                   : "creates \(target), hides \(source)")
        return parts.joined(separator: " · ")
    }

    /// Whole numbers without a decimal ("10"), anything else to one place ("6.7").
    private static func number(_ x: Double) -> String {
        abs(x - x.rounded()) < 0.05 ? String(Int(x.rounded())) : String(format: "%.1f", x)
    }

    private static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1e6
        if mb < 1 { return "< 1 MB" }
        if mb < 1000 { return "≈ \(Int(mb.rounded())) MB" }
        return String(format: "≈ %.1f GB", mb / 1000)
    }
}
#endif

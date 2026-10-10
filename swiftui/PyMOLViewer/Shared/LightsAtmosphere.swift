// LightsAtmosphere.swift — the model of the Atmosphere card (#726): the rig's
// haze and dust in Lights mode.
//
// The air twin of LightsEditing.swift. The card (LightsAtmosphereCard.swift)
// is a view over LightsController (the ONE Lights model, which already mirrors
// the whole rig, air included) plus the typed air API at the end of this file:
// - slider ticks and typed values write the rig's air through the bridge
//   setter at index -1 (`setAir` -> `LightsController.writeRigNumbers` ->
//   `seams.setNumber(-1, field, value)`), so a drag runs no Python per tick
//   (#610);
// - the On/Off switch is a button press: `LightsController.setAtmosphere(on:)`
//   runs one echoed `atmosphere` command (Off is exactly `atmosphere off`; On
//   puts back the air the card remembered, or the start look);
// - the slider ranges and defaults are the core's field table
//   (`LightsController.airFields`, read at run time through
//   appkit_lights.write_air_fields), never a copy: testing/tests/raymol/
//   lighting_atmosphere.py TestAtmosphereSource checks that `AirParameter`
//   and `AirField` hold no range or default literal.
//
// Like LightsController.swift, this file names no Python, console or bridge
// entry point (lighting_mode.py NO_PYTHON_SOURCES). It registers no undo:
// light edits have none either, and the bar's Revert is the way back.

import Foundation

// MARK: - The field table

/// One air row of the core's field table (layer1/LightRig.cpp), as
/// appkit_lights.write_air_fields writes it:
/// {"name", "kind", "default", "min", "max"}. The card's ranges and defaults.
struct AirField: Decodable, Equatable {
    let name: String
    /// "float" or "int" (seed).
    let kind: String
    let defaultValue: Double
    let min: Double
    let max: Double

    enum CodingKeys: String, CodingKey {
        case name, kind, min, max
        case defaultValue = "default"
    }

    struct Invalid: Error {}

    /// The core's range: the setter clamps into it.
    var range: ClosedRange<Double> { min...max }

    /// Decode the helper's JSON list. Throws on a row whose numbers are not
    /// finite or whose min is above its max (a range could not be built).
    static func decodeList(_ data: Data) throws -> [AirField] {
        let fields = try JSONDecoder().decode([AirField].self, from: data)
        for field in fields {
            guard field.min.isFinite, field.max.isFinite, field.defaultValue.isFinite,
                  field.min <= field.max else { throw Invalid() }
        }
        return fields
    }
}

// MARK: - Parameters

/// The 0...1 track a mapped slider runs over (outside `AirParameter`, whose
/// body holds no number range: lighting_atmosphere.py checks it).
private let unitTrack: ClosedRange<Double> = 0...1

/// One slider of the card: an air field of kind float. Seed has its own
/// whole-number field, not a slider.
enum AirParameter: String, CaseIterable {
    case haze
    case dust
    case dustSize = "dust_size"
    case dustSpeed = "dust_speed"
    case scatter

    /// The core field name.
    var field: String { rawValue }

    /// The row's label.
    var label: String {
        switch self {
        case .haze: return "Haze"
        case .dust: return "Dust"
        case .dustSize: return "Dust size"
        case .dustSpeed: return "Dust speed"
        case .scatter: return "Scatter (g)"
        }
    }

    /// The value of this parameter in `air`.
    func value(in air: LightRigSnapshot.Air) -> Double {
        switch self {
        case .haze: return air.haze
        case .dust: return air.dust
        case .dustSize: return air.dustSize
        case .dustSpeed: return air.dustSpeed
        case .scatter: return air.scatter
        }
    }

    /// Slider steps per unit (a slider resolution, not a range): 0.01, or
    /// 0.05 for dust speed.
    var stepsPerUnit: Double {
        switch self {
        case .dustSpeed: return 20
        default: return 100
        }
    }

    /// `value` on the slider's grid: (v × steps).rounded() / steps, the
    /// nearest double to k / steps, so the switch's command prints `0.35`,
    /// never `0.35000000000000003`. Typed values are written unrounded.
    func rounded(_ value: Double) -> Double {
        // `+ 0` turns -0 (a small negative scatter rounded) into 0.
        (value * stepsPerUnit).rounded() / stepsPerUnit + 0
    }

    /// Dust speed's slider runs over a square-root track, so real time (1.0)
    /// sits at about 32% of it rather than 10%.
    var usesSquareRootTrack: Bool { self == .dustSpeed }

    /// The slider's range: the table's, or the unit track.
    func sliderRange(_ field: AirField) -> ClosedRange<Double> {
        usesSquareRootTrack ? unitTrack : field.range
    }

    /// The slider position of `value` (clamped into the table's range).
    func sliderPosition(_ value: Double, _ field: AirField) -> Double {
        let v = Swift.min(Swift.max(value, field.min), field.max)
        guard usesSquareRootTrack else { return v }
        let span = field.max - field.min
        guard span > 0 else { return unitTrack.lowerBound }
        return ((v - field.min) / span).squareRoot()
    }

    /// The value at slider position `position`, on the slider's grid and
    /// inside the table's range: what a slider tick writes.
    func sliderValue(_ position: Double, _ field: AirField) -> Double {
        let raw: Double
        if usesSquareRootTrack {
            let p = Swift.min(Swift.max(position, unitTrack.lowerBound), unitTrack.upperBound)
            raw = field.min + (field.max - field.min) * p * p
        } else {
            raw = position
        }
        return Swift.min(Swift.max(rounded(raw), field.min), field.max)
    }
}

extension LightRigSnapshot.Air {
    /// The air field called `name` as a number (seed too); nil for a name
    /// that is not an air field.
    func value(of name: String) -> Double? {
        if let parameter = AirParameter(rawValue: name) { return parameter.value(in: self) }
        return name == "seed" ? Double(seed) : nil
    }
}

// MARK: - The switch's command values

/// One field of the switch's `atmosphere` command.
struct AirValue: Equatable {
    var field: String
    var value: Double

    init(_ field: String, _ value: Double) {
        self.field = field
        self.value = value
    }

    /// The fields the `atmosphere` command takes (the core's air field
    /// names; lighting_atmosphere.py checks them).
    static let commandFields = ["haze", "dust", "dust_size", "dust_speed", "scatter", "seed"]

    /// The value can go into the command: a known field, a finite number,
    /// and for seed a whole number >= 0.
    var isValid: Bool {
        guard Self.commandFields.contains(field), value.isFinite else { return false }
        if field == "seed" { return value >= 0 && value == value.rounded() && value < 1e15 }
        return true
    }

    /// The value as the command gets it: seed as a whole number, every other
    /// field in Swift's shortest round-trip form (`0.35`, `1.0`, `-0.25`,
    /// `1e-05`), which Python's float() reads back exactly.
    var text: String {
        if field == "seed", isValid { return String(Int64(value)) }
        return String(describing: value)
    }
}

// MARK: - Formatting

/// How the card writes and reads its numbers, for the eye and for VoiceOver.
enum AtmosphereFormat {
    /// Two decimals; a negative value (scatter) with the typographic minus:
    /// `0.25`, `−0.30`. A value that rounds to 0 is `0.00`.
    static func text(_ parameter: AirParameter, _ value: Double) -> String {
        let (negative, magnitude) = parts(value)
        return (negative ? LightInspectorFormat.minus : "") + magnitude
    }

    /// What VoiceOver says: `0.25`, `-0.30`.
    static func spoken(_ parameter: AirParameter, _ value: Double) -> String {
        let (negative, magnitude) = parts(value)
        return (negative ? "-" : "") + magnitude
    }

    /// A typed value: blanks, a `+`, a `-` or `−`, and a trailing `×` are
    /// accepted; nil unless it is a finite number. Out-of-range values come
    /// back as typed (the core clamps).
    static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: LightInspectorFormat.minus, with: "-")
        if s.hasSuffix("×") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.allSatisfy({ "+-.0123456789eE".contains($0) }),
              let value = Double(s), value.isFinite else { return nil }
        return value
    }

    /// A typed whole-number seed: whitespace is trimmed, an optional leading
    /// `+` is accepted, followed by non-empty ASCII digits 0-9. Out-of-range
    /// large values come back as typed (the core clamps).
    static func parseSeed(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("+") { s.removeFirst() }
        guard !s.isEmpty, s.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(s)
    }

    /// (negative, two-decimal magnitude); a value that rounds to 0 is never
    /// negative (no `−0.00`).
    private static func parts(_ value: Double) -> (Bool, String) {
        guard value.isFinite else { return (false, "-") }
        let r = (value * 100).rounded() / 100
        return (r < 0, String(format: "%.2f", abs(r)))
    }
}

// MARK: - The typed field

/// The text of one typed field while the model keeps changing under it (a
/// slider, a poll, a console edit): LightFieldEditor without the light
/// owner, because the air belongs to the rig.
/// - The model's value replaces the text unless the user has typed (`show`).
/// - The row's slider moving drops the typed text and ends editing
///   (`sliderMoved`), so a later Return or keyboard dismissal never writes
///   stale text over the drag.
struct AirFieldEditor: Equatable {
    let parameter: AirParameter
    /// What the field shows.
    private(set) var text = ""
    /// The field has focus.
    private(set) var isEditing = false
    /// The user typed since editing began.
    private(set) var typed = false
    /// The model's text, put back when typing is dropped or does not parse.
    private var modelText = ""

    init(parameter: AirParameter) {
        self.parameter = parameter
    }

    /// The model's value changed: it replaces the text unless the user typed.
    mutating func show(_ value: Double?) {
        modelText = value.map { AtmosphereFormat.text(parameter, $0) } ?? ""
        if typed { return }
        text = modelText
    }

    /// The field gained focus.
    mutating func begin() {
        if isEditing { return }
        isEditing = true
        typed = false
    }

    /// The user typed (the TextField binding's setter).
    mutating func type(_ new: String) {
        text = new
        if isEditing { typed = true }
    }

    /// Return or focus loss: the value to write, or nil (nothing typed, or
    /// the text does not parse; the model's text comes back then). Always
    /// ends editing.
    mutating func commit() -> Double? {
        defer { endEditing() }
        guard typed, let value = AtmosphereFormat.parse(text) else {
            text = modelText
            return nil
        }
        text = AtmosphereFormat.text(parameter, value)
        return value
    }

    /// The row's slider moved: typed text is dropped and editing ends, and
    /// the field shows `value`.
    mutating func sliderMoved(value: Double?) {
        endEditing()
        show(value)
    }

    private mutating func endEditing() {
        isEditing = false
        typed = false
    }
}

/// The typed field for the dust pattern's whole-number seed: AirFieldEditor
/// without the slider.
struct AirSeedEditor: Equatable {
    /// What the field shows.
    private(set) var text = ""
    /// The field has focus.
    private(set) var isEditing = false
    /// The user typed since editing began.
    private(set) var typed = false
    /// The model's text, put back when typing is dropped or does not parse.
    private var modelText = ""

    /// The model's value changed: it replaces the text unless the user typed.
    mutating func show(_ value: Int?) {
        modelText = value.map(String.init) ?? ""
        if typed { return }
        text = modelText
    }

    /// The field gained focus.
    mutating func begin() {
        if isEditing { return }
        isEditing = true
        typed = false
    }

    /// The user typed (the TextField binding's setter).
    mutating func type(_ new: String) {
        text = new
        if isEditing { typed = true }
    }

    /// Return or focus loss: the value to write, or nil (nothing typed, or
    /// the text does not parse; the model's text comes back then). Always
    /// ends editing.
    mutating func commit() -> Int? {
        defer { endEditing() }
        guard typed, let value = AtmosphereFormat.parseSeed(text) else {
            text = modelText
            return nil
        }
        text = String(value)
        return value
    }

    private mutating func endEditing() {
        isEditing = false
        typed = false
    }
}

// MARK: - The switch

/// What the card's On/Off switch runs.
enum AtmosphereSwitch {
    /// The look On gives when nothing is remembered and the air has neither
    /// haze nor dust (the orchestrator's Q1; below #683's clip threshold). A
    /// UI default, not a field default: lighting_atmosphere.py checks it lies
    /// inside the table ranges.
    static let startLook: [AirValue] = [AirValue("haze", 0.2), AirValue("dust", 0.5)]

    /// The fields of the On command, in table order (seed included): only
    /// those that differ from the air now.
    /// - The base is `current`, or the table defaults with no rig.
    /// - With a `memory` (the air the card's Off put away), each field still
    ///   at its table default takes the remembered value; a field changed
    ///   since Off keeps its own.
    /// - If haze and dust are then both 0, the start look sets them.
    static func onValues(current: LightRigSnapshot.Air?, memory: LightRigSnapshot.Air?,
                         fields: [AirField]) -> [AirValue] {
        var base: [String: Double] = [:]
        for field in fields {
            base[field.name] = current?.value(of: field.name) ?? field.defaultValue
        }
        var target = base
        if let memory {
            for field in fields where base[field.name] == field.defaultValue {
                if let remembered = memory.value(of: field.name) { target[field.name] = remembered }
            }
        }
        if (target["haze"] ?? 0) == 0, (target["dust"] ?? 0) == 0 {
            for look in startLook where target[look.field] != nil {
                target[look.field] = look.value
            }
        }
        return fields.compactMap { field in
            guard let value = target[field.name], value != base[field.name] else { return nil }
            return AirValue(field.name, value)
        }
    }
}

// MARK: - Hints

/// The one hint the card shows (in this priority order).
enum AtmosphereHint: String, Equatable {
    /// No rig, or a rig with no light: the air shows only in a beam.
    case noLights = "no_lights"
    /// The rig has lights and is off while the air is on.
    case lightsOff = "lights_off"
    /// The rig is on, haze is above about 0.3, and a light that shines is
    /// behind the molecule: the picture can wash out (#683; this hint stays
    /// until that is fixed).
    case backlitHaze = "backlit"

    /// Haze above this with a backlight shows the hint (#683's "above about
    /// 0.3"): a hint threshold, not a field range.
    static let backlitHazeThreshold = 0.3

    /// The log and accessibility identifier.
    var identifier: String { rawValue }

    var text: String {
        switch self {
        case .noLights:
            return "Haze and dust show only inside a light's beam. Add a light to see them."
        case .lightsOff:
            return "The air shows only while the lights are on."
        case .backlitHaze:
            return "Haze above about 0.3 with a light behind the molecule can wash the picture out. "
                + "Lower the haze or move the light."
        }
    }

    /// The SF Symbol of a collapsed header.
    var glyph: String {
        switch self {
        case .noLights: return "info.circle"
        case .lightsOff, .backlitHaze: return "exclamationmark.triangle"
        }
    }

    /// The hint for `rig`, given the lowercased names of the lights behind
    /// the molecule (`LightsFacingState.behind`); nil when none applies.
    static func current(rig: LightRigSnapshot?, behind: Set<String>) -> AtmosphereHint? {
        guard let rig, !rig.lights.isEmpty else { return .noLights }
        let airOn = rig.air.haze > 0 || rig.air.dust > 0
        if !rig.enabled { return airOn ? .lightsOff : nil }
        if rig.air.haze > backlitHazeThreshold,
           rig.lights.contains(where: { $0.intensity > 0 && behind.contains($0.name.lowercased()) }) {
            return .backlitHaze
        }
        return nil
    }
}

// MARK: - Start state

/// How the card starts when Lights mode is entered (the orchestrator's Q4).
enum LightsAtmosphereStart: Equatable {
    case collapsed
    case expanded
    /// Expanded only when the air is on at entry (macOS).
    case expandedIfOn

    func startsExpanded(airIsOn: Bool) -> Bool {
        switch self {
        case .collapsed: return false
        case .expanded: return true
        case .expandedIfOn: return airIsOn
        }
    }
}

// MARK: - What the card shows

/// Everything the card shows, worked out from the controller in one place so
/// the unit tests can check values, labels and enablement without drawing.
/// nil unless Lights mode is active. Unlike the inspector it exists with no
/// lights and with no rig.
struct AtmosphereCardState: Equatable {
    /// One slider row.
    struct Row: Equatable {
        var parameter: AirParameter
        /// The rig's value (the table default with no rig).
        var value: Double
        /// The table's range.
        var range: ClosedRange<Double>
        /// The value label and field text (`0.25`, `−0.30`).
        var text: String
        /// What VoiceOver says for the value.
        var spoken: String
    }

    /// The dust pattern's whole-number seed row.
    struct SeedRow: Equatable {
        var value: Int
        var range: ClosedRange<Double>
        var text: String
    }

    /// The glyph a collapsed header shows for the hint.
    struct Glyph: Equatable {
        var systemImage: String
        var label: String
    }

    // Names and fixed texts.
    static let title = "Atmosphere"
    static let systemImage = "cloud.fog"
    /// Shown while the field table could not be read (the next entry
    /// retries).
    static let unavailableText = "Atmosphere settings are unavailable"
    /// One line about scatter, from the `atmosphere` command's help.
    static let scatterNote = "Above 0, the air glows more where a beam points towards the camera."
    static let seedLabel = "Seed"
    static let seedNote = "The dust pattern: each whole number gives a different one."

    /// The air draws: haze > 0 or dust > 0.
    var isOn: Bool
    var hasRig: Bool
    var hint: AtmosphereHint?
    /// The rows can be edited (a rig, the table read, not busy).
    var canEdit: Bool
    /// The switch can be pressed (the table read, not busy).
    var canToggle: Bool
    /// The card's Off remembered an air for On.
    var hasMemory: Bool
    /// One per AirParameter in declaration order; empty until the table has
    /// loaded.
    var rows: [Row]
    /// The dust pattern seed row (nil until the table has loaded or when inactive).
    var seed: SeedRow?

    /// `behind`: the lowercased names of the lights behind the molecule;
    /// nil reads the controller's `facing`.
    @MainActor
    init?(_ controller: LightsController, behind: Set<String>? = nil) {
        guard controller.isActive else { return nil }
        isOn = controller.airIsOn
        hasRig = controller.rig != nil
        hint = AtmosphereHint.current(rig: controller.rig, behind: behind ?? controller.facing.behind)
        canEdit = controller.canEditAir
        canToggle = controller.canToggleAir
        hasMemory = controller.airMemory != nil
        rows = AirParameter.allCases.compactMap { parameter in
            guard let field = controller.airField(parameter),
                  let value = controller.airValue(parameter) else { return nil }
            return Row(parameter: parameter, value: value, range: field.range,
                       text: AtmosphereFormat.text(parameter, value),
                       spoken: AtmosphereFormat.spoken(parameter, value))
        }
        if let field = controller.airSeedField, let value = controller.airSeed {
            seed = SeedRow(value: value, range: field.range, text: String(value))
        } else {
            seed = nil
        }
    }

    func row(_ parameter: AirParameter) -> Row? {
        rows.first { $0.parameter == parameter }
    }

    /// VoiceOver's name for the card.
    var containerLabel: String { Self.title }
    /// The switch's value.
    var switchValue: String { isOn ? "On" : "Off" }
    /// The rows are missing because the table could not be read.
    var isUnavailable: Bool { rows.isEmpty }

    /// What a collapsed header shows for the hint (nil: no hint).
    var collapsedGlyph: Glyph? {
        hint.map { Glyph(systemImage: $0.glyph, label: $0.text) }
    }

    /// One line for logs and the simulator evidence; stable field order and
    /// number formats.
    var summary: String {
        func v(_ p: AirParameter) -> String {
            row(p).map { String(format: "%.2f", $0.value) } ?? "-"
        }
        return "on=\(isOn ? 1 : 0) haze=\(v(.haze)) dust=\(v(.dust)) dust_size=\(v(.dustSize))"
            + " dust_speed=\(v(.dustSpeed)) scatter=\(v(.scatter)) rig=\(hasRig ? 1 : 0)"
            + " hint=\(hint?.identifier ?? "none") edit=\(canEdit ? 1 : 0) memory=\(hasMemory ? 1 : 0)"
    }
}

// MARK: - The typed air API

extension LightsController {
    /// The rig's air (nil with no rig).
    var air: LightRigSnapshot.Air? { rig?.air }

    /// The air draws: haze > 0 or dust > 0.
    var airIsOn: Bool {
        guard let air else { return false }
        return air.haze > 0 || air.dust > 0
    }

    /// The table row of `parameter` (nil until the table has loaded).
    func airField(_ parameter: AirParameter) -> AirField? {
        airFields.first { $0.name == parameter.field }
    }

    /// The rig's value of `parameter`, or the table default with no rig (nil
    /// with neither).
    func airValue(_ parameter: AirParameter) -> Double? {
        if let air { return parameter.value(in: air) }
        return airField(parameter)?.defaultValue
    }

    /// Set `parameter` of the rig's air (the core clamps into the table's
    /// range). What a slider tick and a typed value call: the bridge setter
    /// at index -1, no Python. `.noRig` with no rig, `.badIndex` when
    /// inactive or busy.
    @discardableResult
    func setAir(_ parameter: AirParameter, _ value: Double) -> LightSetResult {
        writeRigNumbers([(parameter.field, value)])
    }

    /// The table row of the dust pattern seed (nil until the table has loaded).
    var airSeedField: AirField? {
        airFields.first { $0.name == "seed" }
    }

    /// The rig's seed, or the table default with no rig (nil with neither).
    var airSeed: Int? {
        air?.seed ?? airSeedField.map { Int($0.defaultValue) }
    }

    /// Set the seed of the rig's air (the core clamps into the table's
    /// range). What the typed seed field calls: the bridge setter at index -1,
    /// no Python. `.noRig` with no rig, `.badIndex` when inactive or busy.
    @discardableResult
    func setAirSeed(_ value: Int) -> LightSetResult {
        writeRigNumbers([("seed", Double(value))])
    }

    /// `setAir` unless the rig already holds `value` (a slider echoing its
    /// position writes nothing). A stale mirror is re-read first. `.badIndex`
    /// unless the switch could be pressed (`canToggleAir`), `.noRig` with no
    /// rig.
    @discardableResult
    func setAirIfChanged(_ parameter: AirParameter, _ value: Double) -> LightSetResult {
        guard canToggleAir else { return .badIndex }
        refreshIfStale()
        guard let air else { return .noRig }
        if parameter.value(in: air) == value { return .ok }
        return setAir(parameter, value)
    }
}

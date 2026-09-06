import SwiftUI

/// Identity of whatever the pointer is currently over, as reported by
/// `metal_pick.hover_preview_at(..., info=1)` (issue #359).
///
/// The hover pick already resolves all of this to build the `_preselect`
/// highlight; the readout keeps it instead of discarding it.
struct HoverIdentity: Equatable {
    var object: String
    var chain: String
    var resi: String
    var resn: String
    var segi: String
    var name: String
    /// `mouse_selection_mode` AT PICK TIME — 0 atom, 1 residue, 2 chain,
    /// 3 segment, 4 object, 5 molecule, 6 C-α. Carried in the payload rather
    /// than read from the Swift-side scene mirror, which only refreshes on the
    /// ~500 ms poll: right after a Tab (cycle level) the mirror is a level
    /// behind, and the chip would name a scope the click no longer commits.
    var mode: Int
    /// Displayed state (the one `_pick_atom` projected against) and how many
    /// states the object has — the readout names the state only when there is
    /// more than one to be confused about.
    var state: Int
    var stateCount: Int
}

/// Turns a hover pick into the one-line chip text. A pure function of
/// (pick result, selection level), so the whole formatting contract is
/// testable headlessly — no engine, no gesture layer (see HoverReadoutTests).
enum HoverReadout {

    private static let separator = " / "

    /// Decode a `pymol_hover_info_<pid>.json` payload.
    ///
    /// Returns nil for BOTH "unreadable" and "the pick missed": either way there
    /// is nothing to name, and unlike the design-pick payload (where a miss must
    /// clear the selection) neither outcome has a side effect beyond hiding the
    /// chip.
    static func decode(payload: [String: Any]?) -> HoverIdentity? {
        guard let root = payload, (root["hit"] as? Bool) == true else { return nil }
        return HoverIdentity(
            object: root["obj"] as? String ?? "",
            chain: root["chain"] as? String ?? "",
            resi: root["resi"] as? String ?? "",
            resn: root["resn"] as? String ?? "",
            segi: root["segi"] as? String ?? "",
            name: root["name"] as? String ?? "",
            mode: root["mode"] as? Int ?? 1,
            state: root["state"] as? Int ?? 1,
            stateCount: root["nstates"] as? Int ?? 1)
    }

    /// The chip text, or nil when there is nothing nameable (no object).
    ///
    /// The readout stops exactly where the selection would: at Object level it
    /// names the object and no more, and at Chain/Segment level with a blank
    /// chain/segi it falls back to the object — mirroring `_mode_expr`, which
    /// expands those to the whole object. Naming a residue there would advertise
    /// a scope a click does not commit.
    static func text(for id: HoverIdentity) -> String? {
        let object = id.object.trimmingCharacters(in: .whitespaces)
        guard !object.isEmpty else { return nil }

        var parts = [object]
        if id.stateCount > 1 { parts.append("state \(id.state)") }

        let chain = id.chain.trimmingCharacters(in: .whitespaces)
        let segi = id.segi.trimmingCharacters(in: .whitespaces)

        switch id.mode {
        case 4:                                             // object
            return parts.joined(separator: separator)
        case 2:                                             // chain
            if !chain.isEmpty { parts.append("chain \(chain)") }
            return parts.joined(separator: separator)
        case 3:                                             // segment
            guard !segi.isEmpty else { return parts.joined(separator: separator) }
            if !chain.isEmpty { parts.append("chain \(chain)") }
            parts.append("seg \(segi)")
            return parts.joined(separator: separator)
        default:
            break
        }

        if !chain.isEmpty { parts.append("chain \(chain)") }
        let residue = [id.resn.trimmingCharacters(in: .whitespaces),
                       id.resi.trimmingCharacters(in: .whitespaces)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        switch id.mode {
        case 0:                                             // atom
            if !residue.isEmpty { parts.append(residue) }
            let atom = id.name.trimmingCharacters(in: .whitespaces)
            if !atom.isEmpty { parts.append(atom) }
        case 5:
            // Molecule level commits the whole connected component (`bymol`).
            // Name it by the residue the pick anchored on — for the het groups
            // and ligands this level exists to grab, that residue IS the
            // molecule's name (HEM 501). The "mol" tag keeps it from reading as
            // a residue-level pick.
            if !residue.isEmpty { parts.append("mol \(residue)") }
        default:                                            // 1 residue, 6 C-α
            if !residue.isEmpty { parts.append(residue) }
        }
        return parts.joined(separator: separator)
    }

    /// Payload → chip text in one step (what the engine calls).
    static func text(payload: [String: Any]?) -> String? {
        guard let id = decode(payload: payload) else { return nil }
        return text(for: id)
    }
}

/// The chip itself: a small, non-interactive text pill pinned to the viewport's
/// top-trailing corner. Never hit-testable — it floats over the Metal view and
/// must not swallow a click meant for the structure under it.
struct HoverReadoutChip: View {
    let text: String
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(themeManager.active.panelText.color)
            .lineLimit(1)
            .truncationMode(.head)          // keep the finest scope (the atom) visible
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityIdentifier("hoverReadout")
    }
}

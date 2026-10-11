// LightsSideColumn.swift — the trailing Lights column (#620, spec §9, sketch 1).
//
// The container for the light tools that sit beside the scene in Lights mode
// on macOS: #621's orbit view on top (sketch 1), the selected-light inspector
// (#620) under it and #726's Atmosphere card under that, hanging under the
// Lights bar at the viewport's trailing edge (ContentView's macLightsOverlay).
// The layout contract: the orbit card and the Atmosphere card keep their
// heights (layoutPriority 1); in a short window the inspector's content
// scrolls first, and collapsing either card gives the inspector its room
// back. A column too short even for the orbit card and the expanded
// Atmosphere card scrolls the air rows (the card's rows are capped at their
// content). With no light the orbit card and the inspector draw nothing and
// the Atmosphere card stands alone at the top. The column reports its cards'
// frames (LightsColumnFramesKey) for the layout tests. iOS places the same
// cards by size class instead (#623): the phone sheet and side panel
// (LightsSheet.swift) and the iPad float (LightsFloatingTools.swift).
//
// It holds the controller as a plain `let` (it does not observe it, so it
// never re-renders on its own); each tool observes what it shows. Like the
// bar, it names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py checks that).

import SwiftUI

struct LightsSideColumn: View {
    let controller: LightsController
    var style: LightsBarStyle
    /// The inspector starts collapsed to its header.
    var inspectorStartsCollapsed: Bool
    /// The orbit view starts collapsed to its header (ContentView passes
    /// nothing: expanded on macOS; the snapshots show it collapsed).
    var orbitStartsCollapsed: Bool = false
    /// The scene's Shadows switch as last read (nil: unknown), for the
    /// inspector's Shadows hint, and what its Turn On button does.
    var sceneShadowsOn: Bool? = nil
    var onEnableSceneShadows: () -> Void = {}
    /// How the Atmosphere card starts (ContentView passes `.expandedIfOn`:
    /// expanded only when the air is on at entry, so a short window does not
    /// lose inspector room to an unused card).
    var atmosphereStart: LightsAtmosphereStart = .expandedIfOn

    static let width: CGFloat = LightsInspectorMetrics.width
    /// The coordinate space the reported frames are in.
    static let space = "lights.column"

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            LightsOrbitView(controller: controller, style: style,
                            initiallyCollapsed: orbitStartsCollapsed)
                .background(framesReader("orbit"))
                .layoutPriority(1)
            LightsInspector(controller: controller, style: style,
                            initiallyCollapsed: inspectorStartsCollapsed,
                            sceneShadowsOn: sceneShadowsOn,
                            onEnableSceneShadows: onEnableSceneShadows)
                .background(framesReader("inspector"))
            LightsAtmosphereCard(controller: controller, style: style, presentation: .card,
                                 start: atmosphereStart)
                .background(framesReader("atmosphere"))
                .layoutPriority(1)
        }
        .frame(width: Self.width, alignment: .trailing)
        .coordinateSpace(name: Self.space)
    }

    private func framesReader(_ key: String) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: LightsColumnFramesKey.self, value: [key: g.frame(in: .named(Self.space))])
        }
    }
}

/// The side column's cards' frames in its own coordinates (`orbit`,
/// `inspector`, `atmosphere`; a card that draws nothing reports nothing),
/// read by the layout tests.
struct LightsColumnFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

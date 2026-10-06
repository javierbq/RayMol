// LightsSideColumn.swift — the trailing Lights column (#620, spec §9, sketch 1).
//
// The container for the light tools that sit beside the scene in Lights mode:
// #621's orbit view on top (sketch 1), the selected-light inspector (#620)
// under it. On macOS it hangs under the Lights bar at the viewport's trailing
// edge; on iOS it sits at the viewport's top-trailing corner (ContentView
// places it, one property per site). The orbit card keeps its height; in a
// short window the inspector's content scrolls, and collapsing the orbit card
// gives the inspector its room back.
//
// It holds the controller as a plain `let` (it does not observe it, so it
// never re-renders on its own); each tool observes what it shows. Like the
// bar, it names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py checks that).

import SwiftUI

struct LightsSideColumn: View {
    let controller: LightsController
    var style: LightsBarStyle
    /// The inspector starts collapsed to its header (compact width, iPhone).
    var inspectorStartsCollapsed: Bool
    /// The orbit view starts collapsed to its header (any iPhone, until
    /// #623's sheet).
    var orbitStartsCollapsed: Bool = false
    /// The scene's Shadows switch as last read (nil: unknown), for the
    /// inspector's Shadows hint, and what its Turn On button does.
    var sceneShadowsOn: Bool? = nil
    var onEnableSceneShadows: () -> Void = {}

    static let width: CGFloat = LightsInspector.width

    /// The room the column leaves under it on iPad, beyond its 8 pt inset, for
    /// the viewport's bottom-trailing Gesture help button (a 26 pt glyph with
    /// 12 pt padding, about 50 pt tall). With the orbit card above the
    /// inspector the column reaches the viewport's bottom on iPad, and the
    /// column overlay is drawn over that button. ContentView applies it.
    static let helpButtonClearance: CGFloat = 44

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            LightsOrbitView(controller: controller, style: style,
                            initiallyCollapsed: orbitStartsCollapsed)
                .layoutPriority(1)
            LightsInspector(controller: controller, style: style,
                            initiallyCollapsed: inspectorStartsCollapsed,
                            sceneShadowsOn: sceneShadowsOn,
                            onEnableSceneShadows: onEnableSceneShadows)
        }
        .frame(width: Self.width, alignment: .trailing)
    }
}

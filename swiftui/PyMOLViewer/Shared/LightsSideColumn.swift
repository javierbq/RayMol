// LightsSideColumn.swift — the trailing Lights column (#620, spec §9, sketch 1).
//
// The container for the light tools that sit beside the scene in Lights mode:
// #621's orbit view on top (sketch 1), the selected-light inspector (#620)
// under it. On macOS it hangs under the Lights bar at the viewport's trailing
// edge; on iOS it sits at the viewport's top-trailing corner (ContentView
// places it, one property per site). #621 adds its view in the slot below and
// changes nothing else in ContentView or the CI placement checks.
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
    /// The scene's Shadows switch as last read (nil: unknown), for the
    /// inspector's Shadows hint, and what its Turn On button does.
    var sceneShadowsOn: Bool? = nil
    var onEnableSceneShadows: () -> Void = {}

    static let width: CGFloat = LightsInspector.width

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // #621: the orbit view goes here, above the inspector.
            LightsInspector(controller: controller, style: style,
                            initiallyCollapsed: inspectorStartsCollapsed,
                            sceneShadowsOn: sceneShadowsOn,
                            onEnableSceneShadows: onEnableSceneShadows)
        }
        .frame(width: Self.width, alignment: .trailing)
    }
}

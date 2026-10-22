// MCPDrivingBanner.swift — non-blocking "AI is driving" banner (macOS).
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import SwiftUI

// A floating capsule, NOT a layout band (#908): it is attached as an overlay
// on the viewport (ContentView.macViewportStack), so showing/hiding it changes
// no other view's frame and the Metal drawable is never reshaped mid-burst.
// Only the capsule itself is hit-testable (the Stop button); the overlay area
// around it stays pass-through because nothing else is drawn there.
struct MCPDrivingBanner: View {
    @EnvironmentObject var mcp: MCPServerManager

    var body: some View {
        Group {
            if mcp.activeTool {
                HStack(spacing: 10) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Claude is controlling RayMol")
                        .font(.caption).fontWeight(.semibold)
                        .fixedSize()
                    if !mcp.lastAction.isEmpty {
                        Text("· \(mcp.lastAction)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Button("Stop") { mcp.stop() }
                        .controlSize(.small).tint(.red)
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
                // Own material so it reads over light and dark scenes alike,
                // with the green tint layered on top of it.
                .background(.regularMaterial, in: Capsule())
                .background(Color.green.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.45))
                    .allowsHitTesting(false))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .frame(maxWidth: 480)
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("mcp-driving-banner")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: mcp.activeTool)
    }
}
#endif

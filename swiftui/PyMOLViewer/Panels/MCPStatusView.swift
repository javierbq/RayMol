// MCPStatusView.swift — toolbar status pill + popover for the MCP server (macOS).
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import SwiftUI

struct MCPStatusView: View {
    @EnvironmentObject var mcp: MCPServerManager
    @State private var showPopover = false

    private var dotColor: Color {
        if !mcp.isRunning { return .secondary }
        return mcp.clientCount > 0 ? .green : .yellow
    }
    private var label: String { mcp.isRunning ? "RayMol MCP" : "MCP off" }

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .opacity(mcp.activeTool ? 0.35 : 1.0)
                    .animation(mcp.activeTool
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default, value: mcp.activeTool)
                Text(label).font(.caption)
                if mcp.clientCount > 0 {
                    Text("· \(mcp.clientCount)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .help("RayMol MCP server status")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            MCPStatusPopover().environmentObject(mcp)
        }
    }
}

private struct MCPStatusPopover: View {
    @EnvironmentObject var mcp: MCPServerManager
    @State private var quickResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable MCP server", isOn: Binding(
                get: { mcp.isRunning }, set: { _ in mcp.toggle() }))
            .toggleStyle(.switch)
            Divider()
            if mcp.isRunning, let port = mcp.port {
                Text("Listening on 127.0.0.1:\(port)").font(.caption)
                Text("Clients connected: \(mcp.clientCount)").font(.caption)
                if !mcp.lastAction.isEmpty {
                    Text("Last action: \(mcp.lastAction)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Server is off.").font(.caption).foregroundStyle(.secondary)
            }
            if !mcp.activityLog.isEmpty {
                Divider()
                Text("Recent activity")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(mcp.activityLog.suffix(12).enumerated()),
                                id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            Divider()
            // One-click connect for the two common clients (skips the sheet).
            // Both auto-trust the session (noteUserInitiatedConnect / pushTrusted).
            Text("Quick connect").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button {
                    mcp.connectClaudeCode { msg in quickResult = msg }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "terminal")
                        Text("Claude Code")
                        if mcp.claudeCLIPath != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.caption2)
                        }
                    }
                }
                Button {
                    mcp.noteUserInitiatedConnect()
                    quickResult = MCPDesktopInstaller.installViaConfig().message
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "menubar.dock.rectangle")
                        Text("Claude App")
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!mcp.isRunning)
            if let quickResult {
                Text(quickResult).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            Divider()
            Button("Connect an AI app…") {
                NotificationCenter.default.post(name: .mcpOpenConnectSheet, object: nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
#endif

// MCPConnectSheet.swift — guided "Connect an AI app" sheet (macOS).
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import AppKit
import SwiftUI

struct MCPConnectSheet: View {
    @EnvironmentObject var mcp: MCPServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?
    @State private var macResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an AI app").font(.title3).bold()
            Text("Apps on this Mac can drive RayMol over a local, token-protected link.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()

            HStack(spacing: 8) {
                Circle().fill(mcp.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("RayMol MCP server").fontWeight(.medium)
                Spacer()
                Toggle("", isOn: Binding(get: { mcp.isRunning }, set: { _ in mcp.toggle() }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if mcp.isRunning, let port = mcp.port {
                Text("Listening on 127.0.0.1:\(port)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            HStack(spacing: 8) {
                Text("Claude Code").fontWeight(.medium)
                if mcp.claudeCLIPath != nil {
                    Text("✓ detected").font(.caption).foregroundStyle(.green)
                } else {
                    Text("not found").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect") { mcp.connectClaudeCode { msg in result = msg } }
                    .disabled(!mcp.isRunning)
            }
            if let port = mcp.port {
                HStack {
                    Text("Manual command:").font(.caption)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(manualCommand(port), forType: .string)
                        result = "Connection details copied to clipboard."
                    } label: {
                        Label("Copy connection details", systemImage: "doc.on.doc")
                    }
                    .font(.caption).controlSize(.small)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(manualCommand(port))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled).padding(8)
                }
                .background(Color.black.opacity(0.25)).cornerRadius(6)
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Claude for Mac").fontWeight(.medium)
                HStack {
                    Button("Install for Claude (.mcpb)") {
                        mcp.noteUserInitiatedConnect()
                        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                            ?? FileManager.default.temporaryDirectory
                        if let url = MCPDesktopInstaller.writeMcpb(to: dir) {
                            NSWorkspace.shared.open(url)   // Claude shows its install prompt
                            macResult = "Opened \(url.lastPathComponent) — confirm the install in Claude, then restart it."
                        } else {
                            macResult = "Couldn't build the .mcpb. Try 'Set it up for me'."
                        }
                    }.disabled(!mcp.isRunning)
                    Button("Set it up for me") {
                        mcp.noteUserInitiatedConnect()
                        macResult = MCPDesktopInstaller.installViaConfig().message
                    }.disabled(!mcp.isRunning)
                }
                if let macResult {
                    Text(macResult).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(20).frame(width: 470)
    }

    private func manualCommand(_ port: Int) -> String {
        "claude mcp add --transport http raymol "
            + "http://127.0.0.1:\(port)/mcp "
            + "--header \"Authorization: Bearer \(mcp.token)\" --scope user"
    }
}
#endif

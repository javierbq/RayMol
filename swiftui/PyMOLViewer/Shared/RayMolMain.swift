// RayMolMain.swift — process entry point. Routes `--mcp-bridge` to the headless
// stdio bridge (macOS, MCP builds only); otherwise launches the SwiftUI app.
import SwiftUI

@main
enum RayMolMain {
    static func main() {
        #if os(macOS) && !RAYMOL_MAS_RESTRICTED
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--mcp-emit-config") {
            let data = MCPDesktopInstaller.mergedDesktopConfig(
                existing: nil, command: MCPDesktopInstaller.bridgeCommand())
            FileHandle.standardOutput.write(data)
            return
        }
        if let i = args.firstIndex(of: "--mcp-emit-mcpb"),
           args.index(after: i) < args.endIndex {
            let dir = URL(fileURLWithPath: String(args[args.index(after: i)]))
            _ = MCPDesktopInstaller.writeMcpb(to: dir)
            return
        }
        if args.contains("--mcp-bridge") {
            MCPBridge.run()   // headless; loops on stdin, exits on EOF
            return
        }
        #endif
        // Diagnostic instrumentation (trace build only — see RMTrace.swift).
        // Started before the SwiftUI app so engine init and the launch-time
        // file open are inside the trace.
        RMTrace.shared.start()
        PyMOLApp.main()
    }
}

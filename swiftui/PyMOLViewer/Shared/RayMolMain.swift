// RayMolMain.swift — process entry point. Routes `--mcp-bridge` to the headless
// stdio bridge (macOS, MCP builds only); otherwise launches the SwiftUI app.
import SwiftUI

@main
enum RayMolMain {
    static func main() {
        #if os(macOS) && !RAYMOL_MAS_RESTRICTED
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--mcp-bridge") {
            MCPBridge.run()   // headless; loops on stdin, exits on EOF
            return
        }
        #endif
        PyMOLApp.main()
    }
}

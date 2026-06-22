// MCPServerManager.swift — lifecycle + state for the built-in MCP server (macOS).
#if os(macOS)
import Foundation
import Combine

final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()

    @Published private(set) var isRunning = false
    @Published private(set) var port: Int? = nil
    @Published private(set) var clientCount = 0
    @Published private(set) var lastAction = ""
    @Published private(set) var activeTool = false
    @Published private(set) var activityLog: [String] = []
    @Published var pendingApproval = false

    let token: String
    private let preferredPort = 51737
    private weak var engine: PyMOLEngine?
    private var pulseWork: DispatchWorkItem?
    private var trustedThisSession = false
    private var userInitiatedConnectAt: Date?

    private init() {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "raymol.mcp.token"), t.count == 32 {
            token = t
        } else {
            let t = Self.randomHex(16)
            d.set(t, forKey: "raymol.mcp.token")
            token = t
        }
    }

    func bind(engine: PyMOLEngine) {
        self.engine = engine
        autoStartIfEnabled(attempt: 0)
    }

    // Auto-start on launch if the user had it on. The engine inits asynchronously,
    // so retry on the main queue until it's ready (capped, like loadOpenedFile).
    private func autoStartIfEnabled(attempt: Int) {
        guard UserDefaults.standard.bool(forKey: "raymol.mcp.enabled") else { return }
        guard let engine else { return }
        if engine.isReady {
            start()
        } else if attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.autoStartIfEnabled(attempt: attempt + 1)
            }
        }
    }

    // MARK: Lifecycle

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard let engine, engine.isReady, !isRunning else { return }
        UserDefaults.standard.set(true, forKey: "raymol.mcp.enabled")
        // start() returns the live port; the manager learns it from the MCP:started line.
        let b64 = Data(token.utf8).base64EncodedString()
        engine.runPython(
            "import base64\n"
            + "import raymol_mcp.server as _m\n"
            + "_m.start(\(preferredPort), base64.b64decode('\(b64)').decode('utf-8'))"
        )
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: "raymol.mcp.enabled")
        engine?.runPython("import raymol_mcp.server as _m\n_m.stop()")
    }

    // Set by the Connect flow (Task 9) right before it triggers a client connection,
    // so the resulting connect is auto-trusted (no approval prompt for a connect you started).
    func noteUserInitiatedConnect() { userInitiatedConnectAt = Date() }
    func approveSession() { trustedThisSession = true; pendingApproval = false }
    func denyAndStop() { pendingApproval = false; stop() }

    // MARK: Feedback (main thread, from PyMOLEngine.pollFeedback)

    func handleFeedbackEvent(_ kind: String, _ detail: String) {
        switch kind {
        case "started":
            isRunning = true
            port = Int(detail)
            writeHandoff(port: port)
            logLine("server started on \(detail)")
        case "stopped":
            isRunning = false; port = nil; clientCount = 0; activeTool = false
            trustedThisSession = false
            removeHandoff()
            logLine("server stopped")
        case "connect":
            clientCount += 1
            logLine("client connected")
            let recent = userInitiatedConnectAt.map { Date().timeIntervalSince($0) < 60 } ?? false
            if recent { trustedThisSession = true }
            if !trustedThisSession { pendingApproval = true }
        case "disconnect":
            clientCount = max(0, clientCount - 1)
            logLine("client disconnected")
        case "action":
            lastAction = detail
            logLine(detail)
            activeTool = true
            pulse()
        case "actionend":
            activeTool = false
        default:
            break
        }
    }

    private func logLine(_ s: String) {
        activityLog.append(s)
        if activityLog.count > 200 { activityLog.removeFirst(activityLog.count - 200) }
    }

    // Hold activeTool true briefly so the pulse is visible; a backstop in case an
    // actionend line is ever missed.
    private func pulse() {
        pulseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.activeTool = false }
        pulseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    // MARK: Handoff file (for the Phase 2 Claude Mac app bridge)

    private func handoffURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("RayMol", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp.json")
    }

    private func writeHandoff(port: Int?) {
        guard let url = handoffURL(), let port else { return }
        let obj: [String: Any] = ["port": port, "token": token]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func removeHandoff() {
        if let url = handoffURL() { try? FileManager.default.removeItem(at: url) }
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }
}
#endif

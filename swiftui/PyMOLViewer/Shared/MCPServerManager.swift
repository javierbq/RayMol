// MCPServerManager.swift — lifecycle + state for the built-in MCP server (macOS).
#if os(macOS) && !RAYMOL_MAS_RESTRICTED
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
    // When the "Claude is controlling RayMol" banner first appeared in the current
    // burst of tool activity — used to keep it on screen long enough to read even
    // when a tool call finishes almost instantly (see scheduleClearBanner).
    private var activeToolShownAt: Date?
    // Minimum on-screen time from first appearance, plus a short trailing linger
    // after the last tool call ends, so quick actions don't flash past.
    private let bannerMinVisible: TimeInterval = 2.5
    private let bannerTrailingLinger: TimeInterval = 1.0
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
    private func pushTrusted() {
        engine?.runPython("import raymol_mcp.server as _m\n_m.set_trusted(True)")
    }

    func approveSession() { trustedThisSession = true; pendingApproval = false; pushTrusted() }
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
            if trustedThisSession {
                pushTrusted()
            } else {
                pendingApproval = true
            }
        case "disconnect":
            clientCount = max(0, clientCount - 1)
            logLine("client disconnected")
        case "action":
            lastAction = detail
            logLine(detail)
            if !activeTool { activeToolShownAt = Date() }
            activeTool = true
            // A tool call is in progress — keep the banner up and re-arm the
            // backstop in case the matching "actionend" never arrives.
            scheduleBannerBackstop()
        case "actionend":
            scheduleClearBanner()
        default:
            break
        }
    }

    private func logLine(_ s: String) {
        activityLog.append(s)
        if activityLog.count > 200 { activityLog.removeFirst(activityLog.count - 200) }
    }

    // Backstop: if an "actionend" is ever missed, clear the banner a few seconds
    // after the last "action". Re-armed on every "action".
    private func scheduleBannerBackstop() {
        pulseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.clearActiveTool() }
        pulseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    // On "actionend", keep the banner visible until it's been shown at least
    // bannerMinVisible (so an instant tool call doesn't just flash) and at least
    // bannerTrailingLinger past the last action (so it doesn't vanish mid-glance).
    private func scheduleClearBanner() {
        pulseWork?.cancel()
        let shown = activeToolShownAt.map { Date().timeIntervalSince($0) } ?? bannerMinVisible
        let remaining = max(bannerMinVisible - shown, bannerTrailingLinger)
        let w = DispatchWorkItem { [weak self] in self?.clearActiveTool() }
        pulseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: w)
    }

    private func clearActiveTool() {
        activeTool = false
        activeToolShownAt = nil
    }

    // MARK: Connect (Claude Code)

    var claudeCLIPath: String? { Self.findClaude() }

    func connectClaudeCode(completion: @escaping (String) -> Void) {
        guard isRunning, let port = port else {
            completion("Turn on the MCP server first.")
            return
        }
        // noteUserInitiatedConnect sets UI state — keep it synchronous on the main thread.
        noteUserInitiatedConnect()
        // pushTrusted calls runPython which must run on the main thread (PyMOLBridge PAutoBlock).
        pushTrusted()
        // Capture values before leaving the main thread.
        let capturedPort = port
        let capturedToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.installSkillFile()
            let url = "http://127.0.0.1:\(capturedPort)/mcp"
            let header = "Authorization: Bearer \(capturedToken)"
            let manual = "claude mcp add --transport http raymol \(url) "
                + "--header \"\(header)\" --scope user"
            guard let claude = Self.findClaude() else {
                DispatchQueue.main.async {
                    completion("Claude Code CLI not found. Run this in a terminal:\n\n\(manual)")
                }
                return
            }
            _ = Self.runClaude(claude, ["mcp", "remove", "raymol", "--scope", "user"])  // idempotent
            let (code, out) = Self.runClaude(claude, [
                "mcp", "add", "--transport", "http", "raymol", url,
                "--header", header, "--scope", "user",
            ])
            let msg: String
            if code == 0 {
                msg = "Connected. In Claude Code, run /mcp (or restart it) to pick up RayMol, "
                    + "then ask it to load and view a structure."
            } else {
                msg = "claude exited \(code): \(out)\n\nManual command:\n\(manual)"
            }
            DispatchQueue.main.async { completion(msg) }
        }
    }

    private func installSkillFile() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/skills/raymol", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.skillMarkdown.write(to: dir.appendingPathComponent("SKILL.md"),
                                      atomically: true, encoding: .utf8)
    }

    private static func findClaude() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home + "/.claude/local/claude", home + "/.local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runClaude(_ claude: String, _ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (-1, "\(error)") }
        // Drain the pipe to EOF BEFORE waiting. stdout+stderr share one pipe, so a
        // chatty child can fill the ~64KB buffer and block on write while we block
        // in waitUntilExit() — a classic deadlock. readDataToEndOfFile() returns
        // when the child closes the pipe (i.e. exits), so read first, then wait.
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        proc.waitUntilExit()
        return (proc.terminationStatus, out)
    }

    private static let skillMarkdown = """
    ---
    name: raymol
    description: Drive the running RayMol molecular viewer (a PyMOL fork) over its built-in MCP server. Use when the user asks to load, view, color, select, measure, render, or analyze molecular structures in RayMol.
    ---

    # Driving RayMol

    RayMol is a desktop molecular visualization app. Its MCP server exposes these tools:

    - `run_pymol_command` — one PyMOL command-language statement (`fetch 1ubq, async=0`, `show cartoon`, `color red, chain A`, `bg_color white`). Use `async=0` on `fetch`/`load`.
    - `run_python` — arbitrary Python with `cmd` (the PyMOL API), plus `np` and `Bio` when available. State persists across calls. Prefer this for multi-step logic, measurements, and data access.
    - `get_session_state` — JSON of loaded objects, selections, camera view, and frame info. Call this first to see what's loaded.
    - `capture_viewport` — ray-traced PNG of the current view. Call after changes so you can SEE the result before describing it.
    - `search_pdb` — full-text RCSB search returning PDB IDs.

    ## Working style

    1. Call `get_session_state` to orient yourself.
    2. Make ONE change at a time with `run_pymol_command` or `run_python`.
    3. Call `capture_viewport` to verify visually before reporting success.
    4. Keep selections explicit (`chain A`, `resi 1-50`, `polymer`); don't clobber the user's view without saying so.

    ## Examples

    - "Show 1UBQ as cartoon colored by chain": `run_pymol_command "fetch 1ubq, async=0"` → `"hide everything"` → `"show cartoon"` → `"util.cbc"` → `capture_viewport`.
    - "How far apart are two residues?": use `run_python` with `cmd.get_distance(...)`.
    """

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
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
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

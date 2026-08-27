// RMTrace.swift — runtime instrumentation for diagnosing UI / render stalls.
//
// This is a DIAGNOSTIC build facility, not a product feature. It writes a JSONL
// event stream to ~/Library/Logs/RayMol/raymol-trace-<pid>.jsonl that a host-side
// monitor tails live while a human drives the app.
//
// What it measures, and why each one is here:
//   • main-thread stalls — a run-loop observer times every callout; a watchdog
//     thread notices when one runs long and SUSPENDS the main thread just long
//     enough to walk its frame pointers, so every hitch arrives with the stack
//     that caused it. This is the instrument that answers "what froze it".
//   • frame timing — per-frame total / idle() / currentDrawable wait, plus how
//     many frames the on-demand gate skipped. A GPU-bound viewport shows up as
//     drawable-wait; a CPU-bound one as idle/render time.
//   • input latency — NSEvent.timestamp vs the moment we handle it. This is the
//     number that corresponds to "feels sluggish": events queuing up behind a
//     busy main thread.
//   • span costs — every runCommand / runPython / panel poll, aggregated per
//     second and individually reported past a threshold.
//
// Everything is off unless RAYMOL_TRACE=1 (the trace build's Info.plist sets a
// default of on; RAYMOL_TRACE=0 forces it off). When off, every entry point is a
// single boolean test.
//
// Cost when on: one timestamp pair per instrumented call, a 1 Hz snapshot from a
// background thread, and file writes on a utility queue. The main thread never
// formats JSON and never touches the file.

import Foundation
import Darwin

final class RMTrace {

    static let shared = RMTrace()

    /// Master switch. RAYMOL_TRACE=1 enables; =0 disables. Default comes from the
    /// bundle (RMTraceDefaultOn in Info.plist) so the trace build traces a plain
    /// Finder double-click, with no environment to set.
    let enabled: Bool
    /// Stack capture on stalls can be disabled independently (RAYMOL_TRACE_STACKS=0)
    /// if suspending the main thread ever proves unwelcome.
    private let stacksEnabled: Bool
    /// A callout that runs longer than this is reported as a stall, with a stack.
    private let stallMs: Double
    /// Individual spans slower than this get their own event (all spans are
    /// aggregated regardless).
    private let spanMs: Double

    private(set) var path: String = ""
    private var fh: FileHandle?
    private let wq = DispatchQueue(label: "io.raymol.trace.write", qos: .utility)
    private let lock = NSLock()
    private let t0 = ProcessInfo.processInfo.systemUptime

    // MARK: State shared with the watchdog (guarded by `lock` unless noted)

    private var mainPort: mach_port_t = 0
    /// Uptime at which the current main-run-loop callout began; 0 when idle.
    private var calloutStart: Double = 0
    private var calloutLabel: String = ""
    /// True once the current callout has been reported, so one stall reports once.
    private var stallOpen = false
    private var stallSeq = 0
    /// Total main-thread callout time in the current snapshot window.
    private var busyAccum: Double = 0

    private struct Agg {
        var n = 0
        var total = 0.0
        var maxV = 0.0
        mutating func add(_ ms: Double) {
            n += 1; total += ms; if ms > maxV { maxV = ms }
        }
        var isEmpty: Bool { n == 0 }
        mutating func reset() { n = 0; total = 0; maxV = 0 }
    }

    private var spans: [String: Agg] = [:]
    private var counters: [String: Int] = [:]
    /// Set by MetalViewport.Coordinator: reports the live MTKView/coordinator state
    /// once a second, so a viewport that stops drawing can be told apart from one
    /// that is drawing and bailing out early. Called on the main thread.
    var viewportProbe: (() -> [String: Any])?
    private var probeTimer: Timer?
    private var framesRendered = 0
    private var framesSkipped = 0
    private var frameAgg = Agg()
    private var drawableAgg = Agg()
    private var idleAgg = Agg()
    private var renderAgg = Agg()
    private var inputAgg = Agg()
    private var inputCount = 0
    private var lastCPU: Double = 0
    private var lastSnapshot: Double = 0

    // MARK: - Lifecycle

    private init() {
        let env = ProcessInfo.processInfo.environment
        // ON by default: this file only ships in the dedicated trace build, whose
        // whole purpose is to trace a plain Finder double-click (no environment to
        // set). RAYMOL_TRACE=0 is the kill switch.
        if let v = env["RAYMOL_TRACE"] {
            enabled = !(v == "0" || v.lowercased() == "false" || v.lowercased() == "no")
        } else {
            enabled = true
        }
        stacksEnabled = (env["RAYMOL_TRACE_STACKS"] ?? "1") != "0"
        stallMs = Double(env["RAYMOL_TRACE_STALL_MS"] ?? "") ?? 120.0
        spanMs = Double(env["RAYMOL_TRACE_SPAN_MS"] ?? "") ?? 20.0
    }

    /// Call once, from the main thread, as early as possible.
    func start() {
        guard enabled else { return }
        openFile()
        mainPort = mach_thread_self()
        installRunLoopObserver()
        startWatchdog()
        // Viewport health, once a second on the main run loop. Lives here rather
        // than in the Coordinator so it keeps reporting even if the Coordinator
        // is deallocated — its absence is itself the diagnosis.
        probeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.emit("viewport", self.viewportProbe?() ?? ["probe": "unregistered"])
        }
        var fields: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "exe": (Bundle.main.executablePath as NSString?)?.lastPathComponent ?? "?",
            "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?",
            "build": (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?",
            "stall_ms": stallMs,
            "span_ms": spanMs,
            "stacks": stacksEnabled,
        ]
        let args = ProcessInfo.processInfo.arguments
        if args.count > 1 { fields["args"] = args.dropFirst().joined(separator: " ") }
        emit("trace.start", fields)
        NSLog("[RMTrace] writing %@", path)
    }

    private func openFile() {
        let dir = NSHomeDirectory() + "/Library/Logs/RayMol"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        path = "\(dir)/raymol-trace-\(pid).jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        fh = FileHandle(forWritingAtPath: path)
        // A stable symlink the monitor can follow without knowing the pid.
        let link = "\(dir)/raymol-trace-latest.jsonl"
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
    }

    // MARK: - Emitting

    private func now() -> Double { ProcessInfo.processInfo.systemUptime - t0 }

    /// Queue one event. The caller pays only for capturing the values.
    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        let t = now()
        wq.async { [weak self] in
            guard let self = self, let fh = self.fh else { return }
            var s = "{\"t\":\(String(format: "%.3f", t)),\"ev\":\"\(event)\""
            for (k, v) in fields {
                s += ",\"\(k)\":\(RMTrace.jsonValue(v))"
            }
            s += "}\n"
            if let d = s.data(using: .utf8) { fh.write(d) }
        }
    }

    private static func jsonValue(_ v: Any) -> String {
        switch v {
        case let b as Bool:   return b ? "true" : "false"
        case let i as Int:    return String(i)
        case let i as Int32:  return String(i)
        case let d as Double: return d.isFinite ? String(format: "%.3f", d) : "null"
        case let f as Float:  return f.isFinite ? String(format: "%.3f", f) : "null"
        case let a as [String]: return "[" + a.map { "\"\(escape($0))\"" }.joined(separator: ",") + "]"
        case let s as String: return "\"\(escape(s))\""
        default:              return "\"\(escape(String(describing: v)))\""
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out
    }

    // MARK: - Spans

    /// Time `body`, aggregate it under `name`, and emit an event if it ran long.
    @inline(__always)
    func span<T>(_ name: String, _ detail: String? = nil, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let s = ProcessInfo.processInfo.systemUptime
        let r = body()
        let ms = (ProcessInfo.processInfo.systemUptime - s) * 1000.0
        record(name, ms, detail)
        return r
    }

    func record(_ name: String, _ ms: Double, _ detail: String? = nil) {
        guard enabled else { return }
        lock.lock()
        spans[name, default: Agg()].add(ms)
        lock.unlock()
        if ms >= spanMs {
            var f: [String: Any] = ["span": name, "ms": ms]
            if let d = detail { f["detail"] = String(d.prefix(160)) }
            emit("slow", f)
        }
    }

    /// Free-standing marker for one-off milestones (open, load, theme, …).
    func mark(_ name: String, _ fields: [String: Any] = [:]) {
        emit(name, fields)
    }

    /// Cheap event counter, reported (and reset) in each 1 Hz snapshot. Used for
    /// things that happen too often to log individually — notably how many times
    /// MTKView actually entered draw(in:) and where it bailed out.
    func bump(_ name: String) {
        guard enabled else { return }
        lock.lock(); counters[name, default: 0] += 1; lock.unlock()
    }

    // MARK: - Frames

    /// Per-frame accounting. All times in ms; `rendered == false` means the
    /// on-demand gate skipped the GPU work.
    func frame(total: Double, idle: Double, drawableWait: Double, render: Double, rendered: Bool) {
        guard enabled else { return }
        lock.lock()
        if rendered {
            framesRendered += 1
            frameAgg.add(total)
            drawableAgg.add(drawableWait)
            renderAgg.add(render)
        } else {
            framesSkipped += 1
        }
        idleAgg.add(idle)
        lock.unlock()
        if rendered && total >= 33.0 {
            emit("slowframe", ["ms": total, "idle": idle, "drawable": drawableWait, "render": render])
        }
    }

    /// One input event handled. `latency` is how long it sat between the window
    /// server stamping it and us processing it — the "feels laggy" number.
    func input(_ kind: String, latency: Double) {
        guard enabled else { return }
        lock.lock()
        inputCount += 1
        inputAgg.add(latency)
        lock.unlock()
        if latency >= 100.0 {
            emit("laggy_input", ["kind": kind, "latency_ms": latency])
        }
    }

    // MARK: - Main run loop observation

    private func installRunLoopObserver() {
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeSources, .beforeWaiting, .exit]
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities.rawValue, true, 0
        ) { [weak self] _, activity in
            guard let self = self else { return }
            let t = ProcessInfo.processInfo.systemUptime
            switch activity {
            case .afterWaiting, .beforeSources:
                self.lock.lock()
                if self.calloutStart == 0 { self.calloutStart = t }
                self.lock.unlock()
            case .beforeWaiting, .exit:
                self.lock.lock()
                let s = self.calloutStart
                self.calloutStart = 0
                let wasOpen = self.stallOpen
                self.stallOpen = false
                let seq = self.stallSeq
                if s > 0 { self.busyAccum += (t - s) }
                self.lock.unlock()
                if wasOpen, s > 0 {
                    self.emit("stall_end", ["seq": seq, "ms": (t - s) * 1000.0])
                }
            default:
                break
            }
        }
        // commonModes covers the default mode AND the event-tracking mode AppKit
        // adds to the common set, so a mouse-drag loop is observed too. Adding it
        // to defaultMode as well would register it twice there and double-count
        // every callout.
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        let th = Thread { [weak self] in
            guard let self = self else { return }
            self.lastCPU = RMTrace.processCPUSeconds()
            self.lastSnapshot = ProcessInfo.processInfo.systemUptime
            while true {
                Thread.sleep(forTimeInterval: 0.02)
                self.watchdogTick()
            }
        }
        th.name = "io.raymol.trace.watchdog"
        th.qualityOfService = .userInitiated
        th.start()
    }

    private func watchdogTick() {
        let t = ProcessInfo.processInfo.systemUptime

        // 1. Stall detection.
        lock.lock()
        let start = calloutStart
        let alreadyOpen = stallOpen
        lock.unlock()
        if start > 0, !alreadyOpen, (t - start) * 1000.0 >= stallMs {
            lock.lock()
            stallOpen = true
            stallSeq += 1
            let seq = stallSeq
            lock.unlock()
            let stack = stacksEnabled ? captureMainStack() : []
            emit("stall", ["seq": seq, "ms_so_far": (t - start) * 1000.0, "stack": stack])
        }

        // 2. 1 Hz snapshot.
        if t - lastSnapshot >= 1.0 {
            let window = t - lastSnapshot
            lastSnapshot = t
            let cpu = RMTrace.processCPUSeconds()
            let cpuPct = (cpu - lastCPU) / window * 100.0
            lastCPU = cpu

            lock.lock()
            let busy = busyAccum; busyAccum = 0
            let fr = framesRendered; framesRendered = 0
            let fs = framesSkipped; framesSkipped = 0
            let fa = frameAgg;    frameAgg.reset()
            let da = drawableAgg; drawableAgg.reset()
            let ia = idleAgg;     idleAgg.reset()
            let ra = renderAgg;   renderAgg.reset()
            let inA = inputAgg;   inputAgg.reset()
            let inN = inputCount; inputCount = 0
            let sp = spans; spans.removeAll(keepingCapacity: true)
            let ct = counters; counters.removeAll(keepingCapacity: true)
            let stillStalled = calloutStart > 0 ? (t - calloutStart) * 1000.0 : 0
            lock.unlock()

            var f: [String: Any] = [
                "cpu_pct": cpuPct,
                "main_busy_pct": busy / window * 100.0,
                "rss_mb": Double(RMTrace.residentBytes()) / 1_048_576.0,
                "fps": Double(fr) / window,
                "frames_skipped": fs,
            ]
            if stillStalled > 0 { f["blocked_ms"] = stillStalled }
            if !fa.isEmpty { f["frame_ms_avg"] = fa.total / Double(fa.n); f["frame_ms_max"] = fa.maxV }
            if !da.isEmpty { f["drawable_ms_avg"] = da.total / Double(da.n); f["drawable_ms_max"] = da.maxV }
            if !ra.isEmpty { f["render_ms_avg"] = ra.total / Double(ra.n); f["render_ms_max"] = ra.maxV }
            if !ia.isEmpty { f["idle_ms_avg"] = ia.total / Double(ia.n); f["idle_ms_max"] = ia.maxV }
            if inN > 0 {
                f["input_n"] = inN
                f["input_lat_avg"] = inA.total / Double(inA.n)
                f["input_lat_max"] = inA.maxV
            }
            // The three costliest spans of the window, "name:total_ms/n/max".
            if !ct.isEmpty {
                f["counts"] = ct.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
            }
            let top = sp.sorted { $0.value.total > $1.value.total }.prefix(4)
            if !top.isEmpty {
                f["spans"] = top.map {
                    "\($0.key):\(String(format: "%.1f", $0.value.total * 1))/\($0.value.n)/\(String(format: "%.1f", $0.value.maxV))"
                }
            }
            emit("snap", f)
        }
    }

    // MARK: - Main-thread stack capture
    //
    // Suspend the main thread, read its register state, walk the frame-pointer
    // chain with vm_read_overwrite (which returns an error instead of faulting on
    // a bad pointer), resume, and only THEN symbolicate. Nothing between suspend
    // and resume allocates or takes a lock, so a main thread stopped inside malloc
    // cannot deadlock the watchdog.
    //
    // Names come out mangled; the host monitor pipes them through swift-demangle.

    private func captureMainStack(maxFrames: Int = 48) -> [String] {
        guard mainPort != 0 else { return [] }
        var addrs = [UInt64](repeating: 0, count: maxFrames)
        var count = 0

        guard thread_suspend(mainPort) == KERN_SUCCESS else { return [] }

        var state = arm_thread_state64_t()
        var scount = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &state) { sp in
            sp.withMemoryRebound(to: natural_t.self, capacity: Int(scount)) { raw in
                thread_get_state(mainPort, thread_state_flavor_t(ARM_THREAD_STATE64), raw, &scount)
            }
        }

        if kr == KERN_SUCCESS {
            let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF   // strip any pointer-auth bits
            let pc = UInt64(state.__pc) & mask
            let lr = UInt64(state.__lr) & mask
            var fp = UInt64(state.__fp)
            if pc != 0 { addrs[count] = pc; count += 1 }
            if lr != 0, count < maxFrames { addrs[count] = lr; count += 1 }
            var guard_ = 0
            while fp != 0, count < maxFrames, guard_ < maxFrames {
                var frame: (UInt64, UInt64) = (0, 0)
                var outSize: vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &frame) { p -> Bool in
                    vm_read_overwrite(mach_task_self_,
                                      vm_address_t(fp), vm_size_t(16),
                                      vm_address_t(UInt(bitPattern: p)), &outSize) == KERN_SUCCESS
                }
                if !ok || outSize != 16 { break }
                let next = frame.0
                let ret = frame.1 & mask
                if ret == 0 { break }
                addrs[count] = ret; count += 1
                if next <= fp { break }          // the chain must grow upward
                fp = next
                guard_ += 1
            }
        }

        thread_resume(mainPort)

        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let a = addrs[i]
            var info = Dl_info()
            if let ptr = UnsafeRawPointer(bitPattern: UInt(a)), dladdr(ptr, &info) != 0,
               let sname = info.dli_sname {
                let image = info.dli_fname.map {
                    (String(cString: $0) as NSString).lastPathComponent
                } ?? "?"
                let base = UInt64(UInt(bitPattern: info.dli_saddr))
                out.append("\(image)`\(String(cString: sname))+\(a &- base)")
            } else {
                out.append(String(format: "0x%llx", a))
            }
        }
        return out
    }

    // MARK: - Process metrics

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return u + s
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}

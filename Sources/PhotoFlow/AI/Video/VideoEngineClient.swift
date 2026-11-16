import Foundation

/// Talks to the local video engine (`python -m photoflow_video.worker`, see Resources/VideoEngine) over
/// JSON lines. The worker is a separate process: if it crashes or runs out of memory the app keeps running,
/// and terminating it is the most reliable way to give all GPU / unified memory back to macOS.
final class VideoEngineClient: @unchecked Sendable {
    static let shared = VideoEngineClient()

    struct Event: @unchecked Sendable {
        let json: [String: Any]
        var kind: String { json["event"] as? String ?? "" }
        subscript(key: String) -> Any? { json[key] }
        func double(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        func int(_ k: String) -> Int? { (json[k] as? NSNumber)?.intValue }
        func string(_ k: String) -> String? { json[k] as? String }
    }

    enum EngineError: LocalizedError {
        case runtimeMissing
        case launchFailed(String)
        case crashed(String)
        case failed(String)
        case outOfMemory(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                return String(localized: "The video engine is not installed. Install it in Model Management (KI ▸ Models).")
            case .launchFailed(let detail): return String(localized: "The video engine could not be started: \(detail)")
            case .crashed(let detail): return String(localized: "The video engine stopped unexpectedly. \(detail)")
            case .failed(let s): return s
            case .outOfMemory:
                return String(localized: "Not enough memory for this video. Choose a shorter clip, a lower resolution or a smaller model, and close other apps.")
            case .cancelled: return String(localized: "Cancelled.")
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiters: [Int: (Event) -> Bool] = [:]   // returns true when the request is finished
    private var stderrTail: [String] = []
    private(set) var loadedModelID: String?
    private var idleTimer: DispatchSourceTimer?
    /// Process is ended after this idle time to release all memory.
    var idleTimeout: TimeInterval = 120

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    // MARK: Process

    private func ensureStarted() throws {
        lock.lock()
        if let p = process, p.isRunning { lock.unlock(); return }
        lock.unlock()
        guard let python = VideoRuntime.pythonURL, FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineError.runtimeMissing
        }
        guard let engineDir = VideoRuntime.engineSourceURL else { throw EngineError.launchFailed("engine files missing in app bundle") }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-u", "-m", "photoflow_video.worker"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = engineDir.path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        // Let MPS use up to the system's recommended working set, but fail cleanly instead of swapping forever.
        env["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] = "1.0"
        env["HOME"] = VideoRuntime.homeURL.path   // keeps caches inside PhotoFlow's folder
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.consume(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self.lock.lock()
            self.stderrTail.append(contentsOf: s.split(separator: "\n").map(String.init))
            if self.stderrTail.count > 60 { self.stderrTail.removeFirst(self.stderrTail.count - 60) }
            self.lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in self?.processEnded(proc) }
        do { try p.run() } catch { throw EngineError.launchFailed(error.localizedDescription) }
        lock.lock()
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        buffer = Data()
        loadedModelID = nil
        lock.unlock()
    }

    private func processEnded(_ proc: Process) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        process = nil
        stdinHandle = nil
        loadedModelID = nil
        let tail = stderrTail.suffix(6).joined(separator: "\n")
        lock.unlock()
        let reason = proc.terminationReason == .uncaughtSignal ? "signal \(proc.terminationStatus)" : "exit \(proc.terminationStatus)"
        let memory = tail.lowercased().contains("out of memory") || proc.terminationStatus == 9
        for (_, w) in pending {
            _ = w(Event(json: ["event": "error", "kind": memory ? "memory" : "crash", "message": "\(reason)\n\(tail)"]))
        }
    }

    private func consume(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let ev = Event(json: obj)
            let id = ev.int("id") ?? 0
            lock.lock()
            let w = waiters[id]
            lock.unlock()
            if let w, w(ev) {
                lock.lock(); waiters[id] = nil; lock.unlock()
            }
        }
    }

    private func send(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj) + Data([0x0A])
        lock.lock(); let h = stdinHandle; lock.unlock()
        guard let h else { throw EngineError.crashed("") }
        try h.write(contentsOf: data)
    }

    /// Sends a request and waits for its final event (result / error / cancelled). Progress events go to `onEvent`.
    func request(_ cmd: String, _ args: [String: Any] = [:], onEvent: ((Event) -> Void)? = nil) async throws -> Event {
        try ensureStarted()
        cancelIdleTimer()
        defer { scheduleIdleShutdown() }
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        let ev: Event = await withCheckedContinuation { cont in
            lock.lock()
            waiters[id] = { ev in
                switch ev.kind {
                case "result", "ready", "error", "cancelled", "bye":
                    cont.resume(returning: ev)
                    return true
                default:
                    onEvent?(ev)
                    return false
                }
            }
            lock.unlock()
            do {
                var obj = args
                obj["id"] = id
                obj["cmd"] = cmd
                try send(obj)
            } catch {
                lock.lock(); let w = waiters.removeValue(forKey: id); lock.unlock()
                if w != nil { cont.resume(returning: Event(json: ["event": "error", "kind": "crash", "message": error.localizedDescription])) }
            }
        }
        switch ev.kind {
        case "error":
            let msg = ev.string("message") ?? ""
            switch ev.string("kind") {
            case "memory": stop(); throw EngineError.outOfMemory(msg)
            case "crash": throw EngineError.crashed(msg)
            default: throw EngineError.failed(msg)
            }
        case "cancelled": throw EngineError.cancelled
        default: return ev
        }
    }

    func cancelCurrent() {
        try? send(["id": 0, "cmd": "cancel"])
    }

    /// Ends the worker process (all model memory is returned to macOS).
    func stop() {
        lock.lock(); let p = process; lock.unlock()
        guard let p, p.isRunning else { return }
        try? send(["id": 0, "cmd": "quit"])
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
    }

    // MARK: High level

    func hello() async throws -> Event { try await request("hello") }

    func load(_ model: AIModelDescriptor) async throws {
        if loadedModelID == model.id, isRunning { return }
        let args: [String: Any] = ["model_id": model.id, "path": ModelStore.directory(for: model.id).path,
                                   "kind": model.videoKind ?? "", "text_encoder_path": ModelStore.directory(for: "wan-umt5").path]
        _ = try await request("load", args)
        lock.lock(); loadedModelID = model.id; lock.unlock()
    }

    private func cancelIdleTimer() {
        lock.lock(); idleTimer?.cancel(); idleTimer = nil; lock.unlock()
    }

    private func scheduleIdleShutdown() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + idleTimeout)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let busy = !self.waiters.isEmpty; self.lock.unlock()
            if !busy { self.stop() }
        }
        lock.lock(); idleTimer?.cancel(); idleTimer = t; lock.unlock()
        t.resume()
    }

    var recentLog: String { lock.lock(); defer { lock.unlock() }; return stderrTail.suffix(20).joined(separator: "\n") }
}

import Foundation
import CoreML
import CryptoKit

/// Installation state of one model.
enum ModelInstallState: Equatable {
    case notInstalled
    case queued
    case downloading(DownloadProgress)
    case paused(DownloadProgress)
    case verifying(String)
    case installing
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .queued, .downloading, .verifying, .installing: return true
        default: return false
        }
    }
}

struct DownloadProgress: Equatable {
    var received: Int64
    var total: Int64
    var bytesPerSecond: Double?
    var fileIndex: Int
    var fileCount: Int
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    /// Only reported once the speed has been measured for a few seconds.
    var remainingSeconds: Double? {
        guard let s = bytesPerSecond, s > 1 else { return nil }
        return Double(total - received) / s
    }
}

/// Record written next to an installed model.
struct InstalledModelRecord: Codable {
    var id: String
    var revision: String
    var version: String
    var installedAt: Date
    var bytes: Int64
}

enum ModelStoreError: LocalizedError {
    case untrustedSource(String)
    case notEnoughDisk(needed: Int64, free: Int64)
    case httpStatus(Int, String)
    case checksumMismatch(String)
    case sizeMismatch(String)
    case archiveInvalid(String)
    case incompatible(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .untrustedSource(let h):
            return String(localized: "Blocked a download from an unexpected server (\(h)). Only the official model sources are allowed.")
        case .notEnoughDisk(let n, let f):
            return String(localized: "Not enough free disk space: \(n.formattedBytes) needed, \(f.formattedBytes) available. Free up space and try again.")
        case .httpStatus(let c, let f):
            return String(localized: "The server answered with error \(c) for \(f). Try again later.")
        case .checksumMismatch(let f):
            return String(localized: "\(f) failed the checksum test and was deleted. The download may have been damaged – try again.")
        case .sizeMismatch(let f):
            return String(localized: "\(f) has an unexpected size and was deleted. Try again.")
        case .archiveInvalid(let m):
            return String(localized: "The model package could not be installed: \(m)")
        case .incompatible(let m):
            return m
        case .network(let m):
            return m
        }
    }
}

/// Downloads, verifies, installs and removes AI models.
/// Models live in ~/Library/Application Support/PhotoFlow/Models/<id>/ and are never part of the app bundle.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var states: [String: ModelInstallState] = [:]
    @Published private(set) var installed: [String: InstalledModelRecord] = [:]
    @Published var defaultDiffusionModelID: String { didSet { UserDefaults.standard.set(defaultDiffusionModelID, forKey: "aiDefaultDiffusionModel") } }
    @Published var defaultUpscalerID: String { didSet { UserDefaults.standard.set(defaultUpscalerID, forKey: "aiDefaultUpscaler") } }

    nonisolated static let trustedHostSuffixes = ["huggingface.co", "hf.co", "github.com", "githubusercontent.com"]

    nonisolated static var rootURL: URL {
        if let override = ProcessInfo.processInfo.environment["PHOTOFLOW_MODELS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoFlow/Models", isDirectory: true)
    }

    nonisolated static func directory(for id: String) -> URL { rootURL.appendingPathComponent(id, isDirectory: true) }
    nonisolated static func partialDirectory(for id: String) -> URL { rootURL.appendingPathComponent(id + ".partial", isDirectory: true) }
    /// Compiled Core ML model of an archive-based model (upscalers, LaMa).
    nonisolated static func compiledModelURL(for id: String) -> URL { directory(for: id).appendingPathComponent("model.mlmodelc", isDirectory: true) }

    private var queue: [String] = []
    private var running: String?
    private var controls: [String: DownloadControl] = [:]

    private init() {
        let hw = AIHardware.current
        defaultDiffusionModelID = UserDefaults.standard.string(forKey: "aiDefaultDiffusionModel") ?? hw.recommendedDiffusionModelID
        defaultUpscalerID = UserDefaults.standard.string(forKey: "aiDefaultUpscaler") ?? "realesrgan-x4plus"
        reload()
        validationObserver = NotificationCenter.default.addObserver(forName: .aiModelValidationChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in ModelStore.shared.objectWillChange.send() }
        }
    }

    private var validationObserver: NSObjectProtocol?

    // MARK: State

    func reload() {
        var inst: [String: InstalledModelRecord] = [:]
        for m in AIModelCatalog.all {
            let rec = Self.directory(for: m.id).appendingPathComponent("install.json")
            if let d = try? Data(contentsOf: rec), let r = try? JSONDecoder.iso.decode(InstalledModelRecord.self, from: d) {
                inst[m.id] = r
            }
        }
        installed = inst
        for m in AIModelCatalog.all where !(states[m.id]?.isBusy ?? false) {
            if inst[m.id] != nil { states[m.id] = .installed; continue }
            if case .failed = states[m.id] ?? .notInstalled { continue }
            if FileManager.default.fileExists(atPath: Self.partialDirectory(for: m.id).path) {
                states[m.id] = .paused(DownloadProgress(received: partialBytes(m), total: m.downloadSize, bytesPerSecond: nil,
                                                        fileIndex: 0, fileCount: m.files.count))
            } else {
                states[m.id] = .notInstalled
            }
        }
    }

    func state(_ id: String) -> ModelInstallState { states[id] ?? .notInstalled }
    func isInstalled(_ id: String) -> Bool { installed[id] != nil }
    func updateAvailable(_ m: AIModelDescriptor) -> Bool {
        guard let r = installed[m.id] else { return false }
        return r.revision != m.revision
    }

    var installedDiffusionModels: [AIModelDescriptor] {
        AIModelCatalog.diffusionModels.filter { isInstalled($0.id) && AIHardware.current.incompatibility(of: $0) == nil }
    }

    /// The diffusion model to use: the default if installed, otherwise any installed compatible one.
    var activeDiffusionModel: AIModelDescriptor? {
        // Models that failed the on-device check come last; the default wins among the rest.
        let list = installedDiffusionModels.sorted { (ModelValidation.record($0.id)?.passed == false ? 1 : 0) < (ModelValidation.record($1.id)?.passed == false ? 1 : 0) }
        if let d = list.first(where: { $0.id == defaultDiffusionModelID }), ModelValidation.record(d.id)?.passed != false { return d }
        return list.first
    }

    func installedUpscaler(scale: Int? = nil, denoise: Bool = false) -> AIModelDescriptor? {
        let list = AIModelCatalog.upscalers.filter { isInstalled($0.id) }
        if denoise { return list.first { $0.capabilities.contains(.denoise) } }
        if let scale {
            if let d = list.first(where: { $0.id == defaultUpscalerID && $0.scale == scale }) { return d }
            return list.first { $0.scale == scale && !$0.capabilities.contains(.denoise) } ?? list.first { $0.scale == scale }
        }
        return list.first { $0.id == defaultUpscalerID } ?? list.first
    }

    var lamaInstalled: Bool { isInstalled("lama") }

    var totalInstalledBytes: Int64 { installed.values.reduce(0) { $0 + $1.bytes } }

    // MARK: Actions

    func download(_ m: AIModelDescriptor) {
        if let reason = AIHardware.current.incompatibility(of: m) {
            states[m.id] = .failed(reason)
            return
        }
        guard !state(m.id).isBusy else { return }
        if !queue.contains(m.id) { queue.append(m.id) }
        states[m.id] = .queued
        pump()
    }

    func pause(_ id: String) {
        if let i = queue.firstIndex(of: id), running != id {
            queue.remove(at: i)
            states[id] = .paused(lastProgress(id))
            return
        }
        controls[id]?.requestPause()
    }

    func resume(_ id: String) {
        guard let m = AIModelCatalog.model(id) else { return }
        download(m)
    }

    func cancel(_ id: String) {
        if let i = queue.firstIndex(of: id), running != id { queue.remove(at: i) }
        if running == id {
            controls[id]?.requestCancel()
        } else {
            try? FileManager.default.removeItem(at: Self.partialDirectory(for: id))
            states[id] = isInstalled(id) ? .installed : .notInstalled
        }
    }

    func uninstall(_ id: String) {
        DiffusionEngine.shared.unloadIfUsing(modelID: id)
        Upscaler.shared.unload()
        LaMaRemover.shared.unload()
        try? FileManager.default.removeItem(at: Self.directory(for: id))
        try? FileManager.default.removeItem(at: Self.partialDirectory(for: id))
        ModelValidation.clear(id)
        installed[id] = nil
        states[id] = .notInstalled
    }

    func setDefault(_ m: AIModelDescriptor) {
        switch m.kind {
        case .diffusion: defaultDiffusionModelID = m.id
        case .upscaler: defaultUpscalerID = m.id
        case .inpainter, .vae: break
        }
    }

    // MARK: Download loop

    private func lastProgress(_ id: String) -> DownloadProgress {
        switch state(id) {
        case .downloading(let p), .paused(let p): return p
        default:
            let m = AIModelCatalog.model(id)
            return DownloadProgress(received: m.map(partialBytes) ?? 0, total: m?.downloadSize ?? 0, bytesPerSecond: nil, fileIndex: 0, fileCount: m?.files.count ?? 0)
        }
    }

    private func partialBytes(_ m: AIModelDescriptor) -> Int64 {
        let dir = Self.partialDirectory(for: m.id)
        return m.files.reduce(0) { acc, f in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.path).path)[.size] as? NSNumber)?.int64Value ?? 0
            return acc + (size == f.size ? size : 0)
        }
    }

    private func pump() {
        guard running == nil, let next = queue.first else { return }
        queue.removeFirst()
        guard let m = AIModelCatalog.model(next) else { pump(); return }
        running = next
        let control = DownloadControl()
        controls[next] = control
        Task.detached(priority: .utility) {
            let result: Result<InstalledModelRecord, Error>
            do {
                let rec = try await ModelInstaller(model: m, control: control) { state in
                    Task { @MainActor in ModelStore.shared.states[m.id] = state }
                }.run()
                result = .success(rec)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                let store = ModelStore.shared
                store.running = nil
                store.controls[m.id] = nil
                switch result {
                case .success(let rec):
                    store.installed[m.id] = rec
                    store.states[m.id] = .installed
                    if m.kind == .diffusion, !store.isInstalled(store.defaultDiffusionModelID) { store.defaultDiffusionModelID = m.id }
                    // SD 1.x / 2.x: also fetch the float32 VAE (small) – it decodes correctly on every compute unit.
                    if m.family == .sd15 || m.family == .sd21, let vae = AIModelCatalog.model("sd-vae-fp32"), !store.isInstalled(vae.id) {
                        store.download(vae)
                    }
                case .failure(let error):
                    if control.cancelRequested {
                        try? FileManager.default.removeItem(at: Self.partialDirectory(for: m.id))
                        store.states[m.id] = store.isInstalled(m.id) ? .installed : .notInstalled
                    } else if control.pauseRequested {
                        store.states[m.id] = .paused(store.lastProgress(m.id))
                    } else {
                        store.states[m.id] = .failed(ModelInstaller.describe(error))
                    }
                }
                store.pump()
            }
        }
    }
}

/// Pause / cancel flags shared between the UI and a running download.
final class DownloadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _pause = false
    private var _cancel = false
    private var onStop: (() -> Void)?

    var pauseRequested: Bool { lock.lock(); defer { lock.unlock() }; return _pause }
    var cancelRequested: Bool { lock.lock(); defer { lock.unlock() }; return _cancel }
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return _pause || _cancel }

    func setStopHandler(_ h: (() -> Void)?) { lock.lock(); onStop = h; lock.unlock() }
    func requestPause() { lock.lock(); _pause = true; let h = onStop; lock.unlock(); h?() }
    func requestCancel() { lock.lock(); _cancel = true; let h = onStop; lock.unlock(); h?() }
}

/// Performs one model installation off the main thread.
struct ModelInstaller {
    let model: AIModelDescriptor
    let control: DownloadControl
    let report: (ModelInstallState) -> Void

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "No internet connection. Models need the internet once for the download; afterwards everything works offline.")
            case .timedOut: return String(localized: "The download timed out. Check your connection and resume the download.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "The model server could not be reached. Try again later.")
            default: return e.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func run() async throws -> InstalledModelRecord {
        let fm = FileManager.default
        let partial = ModelStore.partialDirectory(for: model.id)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        let verifiedList = partial.appendingPathComponent(".verified")
        var verified = Set((try? String(contentsOf: verifiedList, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [])

        // Disk space: what is still missing plus room for extraction / compilation.
        let alreadyThere = model.files.filter { verified.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
        let needed = (model.downloadSize - alreadyThere) + (model.isArchive ? model.downloadSize * 2 : 0) + 500_000_000
        let free = AIHardware.freeDisk()
        if free > 0, free < needed { throw ModelStoreError.notEnoughDisk(needed: needed, free: free) }

        for f in model.files {
            guard f.url.scheme == "https", let host = f.url.host, ModelStore.trustedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                throw ModelStoreError.untrustedSource(f.url.host ?? f.url.absoluteString)
            }
        }

        let total = model.downloadSize
        var completed: Int64 = alreadyThere
        let downloader = FileDownloader()
        control.setStopHandler { downloader.stop() }
        defer { control.setStopHandler(nil) }
        var meter = SpeedMeter()

        for (i, f) in model.files.enumerated() {
            if verified.contains(f.path) { continue }
            if control.shouldStop { throw CancellationError() }
            let dest = partial.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let resumeURL = partial.appendingPathComponent(".resume-\(i)")
            let resumeData = try? Data(contentsOf: resumeURL)
            let base = completed
            report(.downloading(DownloadProgress(received: base, total: total, bytesPerSecond: meter.rate, fileIndex: i + 1, fileCount: model.files.count)))
            do {
                try await downloader.download(f.url, resumeData: resumeData, to: dest) { written in
                    meter.add(total: base + written)
                    report(.downloading(DownloadProgress(received: base + written, total: total, bytesPerSecond: meter.rate,
                                                         fileIndex: i + 1, fileCount: model.files.count)))
                }
                try? fm.removeItem(at: resumeURL)
            } catch {
                if let data = downloader.takeResumeData() { try? data.write(to: resumeURL) }
                if control.shouldStop { throw CancellationError() }
                if resumeData != nil {
                    // Stale resume data (signed CDN links expire) – restart this file once.
                    try? fm.removeItem(at: resumeURL)
                    try await downloader.download(f.url, resumeData: nil, to: dest) { written in
                        meter.add(total: base + written)
                        report(.downloading(DownloadProgress(received: base + written, total: total, bytesPerSecond: meter.rate,
                                                             fileIndex: i + 1, fileCount: model.files.count)))
                    }
                } else {
                    throw error
                }
            }
            // Verify size and SHA-256 of every file.
            let size = (try fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == f.size else { try? fm.removeItem(at: dest); throw ModelStoreError.sizeMismatch(f.path) }
            report(.verifying((f.path as NSString).lastPathComponent))
            guard try Self.sha256(of: dest) == f.sha256.lowercased() else {
                try? fm.removeItem(at: dest)
                throw ModelStoreError.checksumMismatch(f.path)
            }
            verified.insert(f.path)
            try? verified.sorted().joined(separator: "\n").write(to: verifiedList, atomically: true, encoding: .utf8)
            completed += f.size
        }

        report(.installing)
        let staging = partial.appendingPathComponent(".staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if model.isArchive {
            guard let archive = model.files.first else { throw ModelStoreError.archiveInvalid("empty") }
            let zip = partial.appendingPathComponent(archive.path)
            let extract = partial.appendingPathComponent(".extract", isDirectory: true)
            try? fm.removeItem(at: extract)
            try fm.createDirectory(at: extract, withIntermediateDirectories: true)
            try Self.unzip(zip, to: extract)
            let packages = try fm.contentsOfDirectory(at: extract, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "mlpackage" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !packages.isEmpty else {
                throw ModelStoreError.archiveInvalid(String(localized: "no Core ML package inside"))
            }
            try Self.rejectSymlinks(in: extract)
            for pkg in packages {
                let compiled = try await Self.compile(pkg)
                // One package → model.mlmodelc; several (e.g. VAE decoder + encoder) → <name>.mlmodelc
                let name = packages.count == 1 ? "model.mlmodelc" : pkg.deletingPathExtension().lastPathComponent + ".mlmodelc"
                try fm.moveItem(at: compiled, to: staging.appendingPathComponent(name))
            }
            try? fm.removeItem(at: extract)
        } else {
            for f in model.files {
                let src = partial.appendingPathComponent(f.path)
                let dst = staging.appendingPathComponent(f.path)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: dst)
            }
        }
        let record = InstalledModelRecord(id: model.id, revision: model.revision, version: model.version, installedAt: Date(),
                                          bytes: Self.directorySize(staging))
        try JSONEncoder.iso.encode(record).write(to: staging.appendingPathComponent("install.json"))
        let final = ModelStore.directory(for: model.id)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: staging, to: final)
        try? fm.removeItem(at: partial)
        return record
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unzip(_ zip: URL, to dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ModelStoreError.archiveInvalid(String(localized: "the archive could not be extracted")) }
    }

    static func rejectSymlinks(in dir: URL) throws {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let u = e?.nextObject() as? URL {
            if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ModelStoreError.archiveInvalid(String(localized: "unexpected link inside the archive"))
            }
        }
    }

    static func compile(_ pkg: URL) async throws -> URL {
        try await MLModel.compileModel(at: pkg)
    }

    static func directorySize(_ dir: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let u = e?.nextObject() as? URL {
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}

/// Smoothed download speed; reports nothing until it has a few seconds of data.
struct SpeedMeter {
    private var samples: [(Date, Int64)] = []
    private var start: Date?
    mutating func add(total: Int64) {
        let now = Date()
        if start == nil { start = now }
        samples.append((now, total))
        samples.removeAll { now.timeIntervalSince($0.0) > 8 }
    }
    var rate: Double? {
        guard let start, Date().timeIntervalSince(start) > 3, let a = samples.first, let b = samples.last else { return nil }
        let dt = b.0.timeIntervalSince(a.0)
        guard dt > 1 else { return nil }
        return Double(b.1 - a.1) / dt
    }
}

/// One URLSession download at a time with progress, resume data and redirect checking.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var progress: ((Int64) -> Void)?
    private var resumeData: Data?
    private var moveError: Error?
    private var lastReport = Date.distantPast

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "PhotoFlow"]
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: q)
    }

    deinit { session.invalidateAndCancel() }

    func download(_ url: URL, resumeData: Data?, to dest: URL, progress: @escaping (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = c
            destination = dest
            self.progress = progress
            self.resumeData = nil
            moveError = nil
            let t = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
            task = t
            lock.unlock()
            t.resume()
        }
    }

    /// Stops the current transfer; resume data (if the server supports it) is kept for `takeResumeData`.
    func stop() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel { [weak self] data in
            guard let self else { return }
            self.lock.lock(); if let data { self.resumeData = data }; self.lock.unlock()
        }
    }

    func takeResumeData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        let d = resumeData
        resumeData = nil
        return d
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url, u.scheme == "https", let host = u.host,
           ModelStore.trustedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            completionHandler(request)
        } else {
            lock.lock(); moveError = ModelStoreError.untrustedSource(request.url?.host ?? "?"); lock.unlock()
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastReport) > 0.25
        if due { lastReport = now }
        let p = progress
        lock.unlock()
        if due { p?(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let dest = destination; lock.unlock()
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.lock(); moveError = ModelStoreError.httpStatus(http.statusCode, dest?.lastPathComponent ?? ""); lock.unlock()
            return
        }
        guard let dest else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            lock.lock(); moveError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        self.task = nil
        if let error, let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData = data }
        let failure = moveError ?? error
        lock.unlock()
        if let failure { c?.resume(throwing: failure) } else { c?.resume() }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
}

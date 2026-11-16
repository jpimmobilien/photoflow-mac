import Foundation

/// The video engine's Python runtime: a relocatable CPython 3.12 (python-build-standalone) plus the pinned
/// wheels (PyTorch, diffusers, transformers, …). It is an optional download like a model ("video-runtime"
/// in the catalog): every file is fetched by PhotoFlow's verified downloader (pinned URL, size, SHA-256) and
/// the wheels are then installed **offline** (`pip --no-index`), so no package manager contacts the network.
enum VideoRuntime {
    static let id = "video-runtime"

    static var directory: URL { ModelStore.directory(for: id) }
    static var pythonURL: URL? {
        let u = directory.appendingPathComponent("python/bin/python3.12")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var homeURL: URL {
        let u = directory.deletingLastPathComponent().appendingPathComponent(".video-engine-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// The engine's own Python sources ship inside the app bundle (Contents/Resources/VideoEngine).
    static var engineSourceURL: URL? {
        if let env = ProcessInfo.processInfo.environment["PHOTOFLOW_VIDEO_ENGINE_DIR"] { return URL(fileURLWithPath: env) }
        let u = Bundle.main.resourceURL?.appendingPathComponent("VideoEngine", isDirectory: true)
        return u.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("photoflow_video").path) ? $0 : nil }
    }
    static var isInstalled: Bool { pythonURL != nil }

    enum SetupError: LocalizedError {
        case missing(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .missing(let detail): return String(localized: "Video engine files are incomplete: \(detail)")
            case .failed(let detail): return String(localized: "Installing the video engine failed: \(detail)")
            }
        }
    }

    /// Called by the model installer with the verified downloads in `staging` (python/<tar.gz>, wheels/*.whl).
    static func setup(in staging: URL, report: (String) -> Void) throws {
        let fm = FileManager.default
        let pyDir = staging.appendingPathComponent("python", isDirectory: true)
        guard let tarball = try fm.contentsOfDirectory(at: pyDir, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasSuffix(".tar.gz") }) else { throw SetupError.missing("python") }
        report(String(localized: "Unpacking Python…"))
        let unpack = staging.appendingPathComponent(".unpack", isDirectory: true)
        try? fm.removeItem(at: unpack)
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", unpack.path])
        // the archive contains a top-level "python/" folder
        let extracted = unpack.appendingPathComponent("python", isDirectory: true)
        guard fm.fileExists(atPath: extracted.appendingPathComponent("bin/python3.12").path) else { throw SetupError.missing("python/bin/python3.12") }
        try ModelInstaller.rejectSymlinksOutside(extracted)
        try fm.removeItem(at: pyDir)
        try fm.moveItem(at: extracted, to: pyDir)
        try? fm.removeItem(at: unpack)

        report(String(localized: "Installing packages (offline)…"))
        let wheelsDir = staging.appendingPathComponent("wheels", isDirectory: true)
        let wheels = try fm.contentsOfDirectory(at: wheelsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "whl" }.map(\.path).sorted()
        guard !wheels.isEmpty else { throw SetupError.missing("wheels") }
        let python = pyDir.appendingPathComponent("bin/python3.12").path
        try run(python, ["-m", "pip", "install", "--no-index", "--no-deps", "--no-cache-dir", "--disable-pip-version-check",
                         "--no-warn-script-location", "--only-binary=:all:"] + wheels,
                env: ["PYTHONNOUSERSITE": "1", "PIP_CONFIG_FILE": "/dev/null"])
        try? fm.removeItem(at: wheelsDir)

        report(String(localized: "Checking the video engine…"))
        // Smoke test: the engine imports and reports its versions (no model needed).
        guard let engine = engineSourceURL else { throw SetupError.missing("VideoEngine (app bundle)") }
        let out = try run(python, ["-c", "import torch, diffusers, transformers, photoflow_video; print(torch.__version__, diffusers.__version__, torch.backends.mps.is_available())"],
                          env: ["PYTHONPATH": engine.path, "PYTHONNOUSERSITE": "1", "HF_HUB_OFFLINE": "1"])
        report(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], env: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        e["HOME"] = homeURL.path
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw SetupError.failed(String(text.suffix(600)))
        }
        return text
    }
}

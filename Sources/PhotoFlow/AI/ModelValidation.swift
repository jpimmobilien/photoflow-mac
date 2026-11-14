import Foundation

/// Per-Mac record of whether a diffusion model produced valid images here (written by the model check, the
/// hardware acceptance test and by normal generations). PhotoFlow never claims a model works on a Mac unless a
/// valid image was actually produced on it.
struct ModelValidation: Codable, Equatable {
    var passed: Bool
    var date: Date
    var secondsPerStep: Double?
    var images: Int
    var detail: String
    var appVersion: String

    private static let key = "aiModelValidation"
    private static let lock = NSLock()

    static func all() -> [String: ModelValidation] {
        lock.lock(); defer { lock.unlock() }
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder.iso.decode([String: ModelValidation].self, from: d) else { return [:] }
        return v
    }

    static func record(_ id: String) -> ModelValidation? { all()[id] }

    static func store(_ id: String, passed: Bool, secondsPerStep: Double?, detail: String, addImages: Int = 1) {
        var map = all()
        var r = map[id] ?? ModelValidation(passed: passed, date: Date(), secondsPerStep: nil, images: 0, detail: "", appVersion: "")
        // A later success after a failure counts; a failure only overrides when it is the newest evidence.
        r.passed = passed
        r.date = Date()
        if let secondsPerStep { r.secondsPerStep = secondsPerStep }
        r.images = passed ? r.images + addImages : 0
        r.detail = detail
        r.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        map[id] = r
        lock.lock()
        if let d = try? JSONEncoder.iso.encode(map) { UserDefaults.standard.set(d, forKey: key) }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .aiModelValidationChanged, object: id) }
    }

    static func clear(_ id: String) {
        var map = all(); map[id] = nil
        lock.lock()
        if let d = try? JSONEncoder.iso.encode(map) { UserDefaults.standard.set(d, forKey: key) }
        lock.unlock()
    }
}

extension Notification.Name {
    static let aiModelValidationChanged = Notification.Name("PhotoFlowAIModelValidationChanged")
}

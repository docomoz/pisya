import Foundation
import CryptoKit

// Usage events contain only fixed names, bounded durations and predefined values.
@MainActor
enum Analytics {
    private static let appID = "AE7E544F-BD61-47AA-AD9C-631D875CC692"
    private static let defaults = UserDefaults.standard
    // Keep opt-outs saved by versions that offered the setting.
    private static let previouslyDisabled = (defaults.object(forKey: "usageAnalyticsEnabled") as? Bool) == false
    private static let identityKey = "usageAnalyticsIdentity"
    private static let queueKey = "usageAnalyticsQueue"
    private static let activeDayKey = "usageAnalyticsActiveDay"
    private static var queue = defaults.data(forKey: queueKey).flatMap { try? JSONDecoder().decode(UsageEventQueue.self, from: $0) } ?? UsageEventQueue()
    private static var task: URLSessionDataTask?
    private static var retryTask: Task<Void, Never>?
    private static var retryDelay: UInt64 = 60
    private static let session = URLSession(configuration: .ephemeral)

    private static var isPreview: Bool {
        ProcessInfo.processInfo.environment["PISA_DISABLE_ANALYTICS"] == "1"
            || CommandLine.arguments.contains(where: { $0.hasPrefix("--") })
            || Bundle.main.object(forInfoDictionaryKey: "PisaInterfacePreview") as? Bool == true
            || Bundle.main.object(forInfoDictionaryKey: "PisaSourceLinkPreview") as? Bool == true
    }
    private static var allowed: Bool { !isPreview && !previouslyDisabled }
    static func appLaunched() { send(.appLaunched) }
    static func appActivated() {
        guard allowed else { return }
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard defaults.double(forKey: activeDayKey) != day else { flush(); return }
        defaults.set(day, forKey: activeDayKey)
        send(.appActivated)
    }
    static func recordingStarted(automatic: Bool) { send(.recordingStarted(automatic: automatic)) }
    static func recordingSaved(duration: Double, automatic: Bool) { send(.recordingSaved(duration: duration, automatic: automatic)) }
    static func recordingIssue(_ issue: UsageEvent.RecordingIssue) { send(.recordingIssue(issue)) }
    static func modelInstallStarted() { send(.modelInstallStarted) }
    static func modelInstallCompleted() { send(.modelInstallCompleted) }
    static func modelInstallFailed() { send(.modelInstallFailed) }
    static func modelInstallCancelled() { send(.modelInstallCancelled) }
    static func audioImported(duration: Double) { send(.audioImported(duration: duration)) }
    static func transcriptionStarted(mode: String, reprocess: Bool) { send(.transcriptionStarted(mode: mode, reprocess: reprocess)) }
    static func transcriptionCompleted(mode: String, reprocess: Bool, duration: Double) { send(.transcriptionCompleted(mode: mode, reprocess: reprocess, duration: duration)) }
    static func transcriptionFailed(mode: String, cancelled: Bool, reprocess: Bool) { send(.transcriptionFailed(mode: mode, cancelled: cancelled, reprocess: reprocess)) }

    static func feature(_ feature: TrackedFeature) { send(.feature(feature)) }
    static func setting(_ setting: TrackedSetting, enabled: Bool) { send(.setting(setting, enabled: enabled)) }
    static func voiceAssigned(remembered: Bool, allMatching: Bool) { send(.voiceAssigned(remembered: remembered, allMatching: allMatching)) }

    private static func send(_ event: UsageEvent) {
        guard allowed else { return }
        queue.append(event); persist(); flush()
    }
    private static func persist() { defaults.set(try? JSONEncoder().encode(queue), forKey: queueKey) }
    private static var clientUser: String {
        let id: String
        if let saved = defaults.string(forKey: identityKey) { id = saved }
        else { id = UUID().uuidString; defaults.set(id, forKey: identityKey) }
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func scheduleRetry() {
        guard retryTask == nil, allowed else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 900)
        retryTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            retryTask = nil
            flush()
        }
    }
    private static func flush() {
        guard allowed, task == nil, !queue.pending.isEmpty else { return }
        queue.discardOlder(than: Date().addingTimeInterval(-86_400)); persist()
        let batch = queue.pending
        guard !batch.isEmpty else { return }
        let dateFormatter = ISO8601DateFormatter()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let user = clientUser
        let body: [[String: Any]] = batch.map { item in
            var payload = item.event.parameters
            payload["TelemetryDeck.AppInfo.version"] = version
            payload["TelemetryDeck.AppInfo.buildNumber"] = build
            payload["TelemetryDeck.Device.systemVersion"] = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            var signal: [String: Any] = ["appID": appID, "clientUser": user, "type": item.event.type,
                                         "receivedAt": dateFormatter.string(from: item.date), "payload": payload]
            if let minutes = item.event.minutes { signal["floatValue"] = minutes }
            return signal
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "https://nom.telemetrydeck.com/v2/namespace/com.docomoz/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let upload = session.dataTask(with: request) { _, response, error in
            Task { @MainActor in
                task = nil
                guard allowed else { return }
                guard error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { scheduleRetry(); return }
                retryDelay = 60
                queue.acknowledge(batch); persist(); flush()
            }
        }
        task = upload; upload.resume()
    }
}

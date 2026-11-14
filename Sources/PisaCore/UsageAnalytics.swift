import Foundation

enum TrackedFeature: String, CaseIterable {
    case meetingMoved = "Library.meetingMoved"
    case folderCreated = "Library.folderCreated"
    case termsReplaced = "Transcript.termsReplaced"
    case dictionaryTermAdded = "Dictionary.termAdded"
    case audioCleanedUp = "Audio.cleanedUp"
    case audioDeleted = "Audio.deleted"
    case transcriptExported = "Export.transcript"
    case audioExported = "Export.audio"
    case librarySearched = "Library.searched"
    case segmentPlayed = "Playback.segmentStarted"
    case recordingPlayed = "Playback.recordingStarted"
    case transcriptEdited = "Transcript.edited"
}

enum TrackedSetting: String, CaseIterable {
    case automaticRecording = "automatic_recording"
    case backgroundTranscription = "background_transcription"
    case automaticExport = "automatic_export"
    case mcp = "mcp"
}

struct UsageEvent: Codable, Equatable {
    let type: String
    let parameters: [String: String]
    let minutes: Double?

    static func feature(_ feature: TrackedFeature) -> Self {
        .init(type: feature.rawValue, parameters: [:], minutes: nil)
    }
    static func setting(_ setting: TrackedSetting, enabled: Bool) -> Self {
        .init(type: "Setting.changed", parameters: ["setting": setting.rawValue, "enabled": flag(enabled)], minutes: nil)
    }
    static func voiceAssigned(remembered: Bool, allMatching: Bool) -> Self {
        .init(type: "Voice.assigned", parameters: ["remembered": flag(remembered), "all_matching": flag(allMatching)], minutes: nil)
    }

    static func mcpToolCall(_ call: MCPToolCall) -> Self {
        .init(type: "MCP.toolCalled", parameters: ["tool": call.tool.rawValue, "outcome": call.succeeded ? "success" : "failure"], minutes: nil)
    }

    private static func duration(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return (min(seconds, 86_400) / 6).rounded() / 10
    }
    private static func mode(_ value: String) -> String {
        ["live", "resume", "batch"].contains(value) ? value : "other"
    }
    private static func flag(_ value: Bool) -> String { value ? "yes" : "no" }
    static let appLaunched = UsageEvent(type: "App.launched", parameters: [:], minutes: nil)
    static let appActivated = UsageEvent(type: "App.activated", parameters: [:], minutes: nil)
    static func recordingStarted(automatic: Bool) -> Self {
        .init(type: "Recording.started", parameters: ["start": automatic ? "automatic" : "manual"], minutes: nil)
    }
    static func recordingSaved(duration: Double, automatic: Bool) -> Self {
        .init(type: "Recording.saved", parameters: ["start": automatic ? "automatic" : "manual"], minutes: self.duration(duration))
    }
    enum RecordingIssue: String { case start, interrupted, stop, partial }
    static func recordingIssue(_ issue: RecordingIssue) -> Self {
        .init(type: "Recording.issue", parameters: ["stage": issue.rawValue], minutes: nil)
    }
    static let modelInstallStarted = UsageEvent(type: "ModelInstall.started", parameters: [:], minutes: nil)
    static let modelInstallCompleted = UsageEvent(type: "ModelInstall.completed", parameters: [:], minutes: nil)
    static let modelInstallFailed = UsageEvent(type: "ModelInstall.failed", parameters: [:], minutes: nil)
    static let modelInstallCancelled = UsageEvent(type: "ModelInstall.cancelled", parameters: [:], minutes: nil)
    static func audioImported(duration: Double) -> Self {
        .init(type: "Audio.imported", parameters: [:], minutes: self.duration(duration))
    }
    static func transcriptionStarted(mode: String, reprocess: Bool) -> Self {
        .init(type: "Transcription.started", parameters: ["mode": self.mode(mode), "reprocess": flag(reprocess)], minutes: nil)
    }
    static func transcriptionCompleted(mode: String, reprocess: Bool, duration: Double) -> Self {
        .init(type: "Transcription.completed", parameters: ["mode": self.mode(mode), "reprocess": flag(reprocess)], minutes: self.duration(duration))
    }
    static func transcriptionFailed(mode: String, cancelled: Bool, reprocess: Bool) -> Self {
        .init(type: cancelled ? "Transcription.cancelled" : "Transcription.failed", parameters: ["mode": self.mode(mode), "reprocess": flag(reprocess)], minutes: nil)
    }
}

struct UsageEventQueue: Codable {
    struct Item: Codable, Equatable {
        let id: UUID
        let date: Date
        let event: UsageEvent
    }
    private(set) var pending: [Item] = []
    private let limit: Int
    init(limit: Int = 200) { self.limit = max(1, limit) }
    mutating func append(_ event: UsageEvent, id: UUID = UUID(), date: Date = Date()) {
        guard !pending.contains(where: { $0.id == id }) else { return }
        pending.append(Item(id: id, date: date, event: event))
        if pending.count > limit { pending.removeFirst(pending.count - limit) }
    }
    mutating func acknowledge(_ sent: [Item]) {
        let ids = Set(sent.map(\.id))
        pending.removeAll { ids.contains($0.id) }
    }
    mutating func discardOlder(than cutoff: Date) { pending.removeAll { $0.date < cutoff } }
}

import Foundation
import Darwin

public enum MCPTrackedTool: String, Codable, CaseIterable, Sendable {
    case listMeetings = "list_meetings"
    case searchMeetings = "search_meetings"
    case readTranscript = "read_transcript"
    case listFolders = "list_folders"
    case searchTranscripts = "search_transcripts"
}

public struct MCPToolCall: Codable, Equatable, Sendable {
    public let tool: MCPTrackedTool
    public let succeeded: Bool
    public init(tool: MCPTrackedTool, succeeded: Bool) { self.tool = tool; self.succeeded = succeeded }
}

public struct MCPAnalyticsItem: Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let call: MCPToolCall
    public var tool: MCPTrackedTool { call.tool }
}

// A bounded, per-event spool shared by the app and any number of MCP processes.
// No arguments, results, paths or error text are written to it.
public struct MCPAnalyticsSpool {
    private let directory: URL
    private let preferences: URL
    private let limit = 200
    public init(root: URL) {
        directory = root.appendingPathComponent("MCPAnalytics", isDirectory: true)
        preferences = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Preferences/com.docomoz.pisa.plist")
    }
    private var enabledURL: URL { directory.appendingPathComponent("enabled") }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    }
    public func setEnabled(_ enabled: Bool) throws {
        try locked {
            if enabled { try Data().write(to: enabledURL, options: .atomic) }
            else {
                try? FileManager.default.removeItem(at: enabledURL)
                for file in try files() { try? FileManager.default.removeItem(at: file) }
            }
        }
    }
    public func record(_ tool: MCPTrackedTool, succeeded: Bool = true) throws {
        guard ProcessInfo.processInfo.environment["PISA_DISABLE_ANALYTICS"] != "1" else { return }
        try locked {
            guard FileManager.default.fileExists(atPath: enabledURL.path) else { return }
            // Respect a previously saved opt-out even when the app is not running.
            if FileManager.default.fileExists(atPath: preferences.path) {
                guard let data = try? Data(contentsOf: preferences),
                      let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
                if let saved = values["usageAnalyticsEnabled"] {
                    guard let enabled = saved as? Bool, enabled else { return }
                }
            }
            let item = MCPAnalyticsItem(id: UUID(), date: Date(), call: .init(tool: tool, succeeded: succeeded))
            try JSONEncoder().encode(item).write(to: directory.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)
            let all = try files()
            for file in all.prefix(max(0, all.count - limit)) { try? FileManager.default.removeItem(at: file) }
        }
    }
    public func acknowledge(_ ids: Set<UUID>) throws {
        try locked {
            for id in ids { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json")) }
        }
    }
    public func drain(accept: ([MCPAnalyticsItem]) -> Bool = { _ in true }) throws -> [MCPAnalyticsItem] {
        try locked {
            let all = try files()
            let now = Date()
            var items: [MCPAnalyticsItem] = []
            var consumed: [URL] = []
            for file in all {
                guard let data = try? Data(contentsOf: file), data.count <= 1024,
                      let item = try? JSONDecoder().decode(MCPAnalyticsItem.self, from: data),
                      item.id.uuidString == file.deletingPathExtension().lastPathComponent,
                      item.date <= now.addingTimeInterval(60), item.date >= now.addingTimeInterval(-86_400) else {
                    try? FileManager.default.removeItem(at: file); continue
                }
                items.append(item); consumed.append(file)
            }
            if accept(items) { for file in consumed { try? FileManager.default.removeItem(at: file) } }
            return items
        }
    }
}

import XCTest
@testable import PisaCore

final class MCPAnalyticsTests: XCTestCase {
    func testOnlySuccessfulKnownToolCallsAreReportedWithoutArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var calls: [MCPToolCall] = []
        let handler = MCPHandler(library: library, onToolSuccess: { calls.append($0) })
        _ = handler.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        _ = handler.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        _ = handler.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_folders", "arguments": [:]]])
        _ = handler.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "private text", "arguments": [:]]])
        _ = handler.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "search_transcripts", "arguments": ["query": ""]]])
        var prefs = try library.preferences(); prefs.mcpEnabled = false; try library.savePreferences(prefs)
        _ = handler.handle(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "list_folders", "arguments": [:]]])
        XCTAssertEqual(calls, [.init(tool: .listFolders, succeeded: true), .init(tool: .searchTranscripts, succeeded: false)])
    }

    func testSpoolRequiresEnabledMarkerAndDrainsEachEventOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = MCPAnalyticsSpool(root: root)
        try spool.record(.listFolders)
        XCTAssertTrue(try spool.drain().isEmpty)
        try spool.setEnabled(true)
        try spool.record(.listFolders)
        try spool.record(.searchTranscripts)
        let items = try spool.drain()
        XCTAssertEqual(Set(items.map(\.tool)), Set([.listFolders, .searchTranscripts]))
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
        XCTAssertTrue(try spool.drain().isEmpty)
        try spool.setEnabled(false)
        try spool.record(.readTranscript)
        XCTAssertTrue(try spool.drain().isEmpty)
    }

    func testConcurrentProducersDoNotLoseEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = MCPAnalyticsSpool(root: root)
        try spool.setEnabled(true)
        DispatchQueue.concurrentPerform(iterations: 80) { _ in try? spool.record(.listMeetings) }
        XCTAssertEqual(try spool.drain().count, 80)
    }
    func testUnacknowledgedEventsSurviveRestartsUntilServerAcknowledges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let producer = MCPAnalyticsSpool(root: root)
        try producer.setEnabled(true)
        try producer.record(.readTranscript, succeeded: false)
        let first = try MCPAnalyticsSpool(root: root).drain(accept: { _ in false })
        XCTAssertEqual(first.first?.call, .init(tool: .readTranscript, succeeded: false))
        let restarted = MCPAnalyticsSpool(root: root)
        XCTAssertEqual(try restarted.drain(accept: { _ in false }).map(\.id), first.map(\.id))
        try restarted.acknowledge(Set(first.map(\.id)))
        XCTAssertTrue(try restarted.drain().isEmpty)
    }

    func testOldOptOutPreventsRecordingWhenMarkerExists() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let library = container.appendingPathComponent("Library")
        let root = library.appendingPathComponent("Application Support/Pisa")
        let preferences = library.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        let spool = MCPAnalyticsSpool(root: root)
        try spool.setEnabled(true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["usageAnalyticsEnabled": false], format: .xml, options: 0)
        try data.write(to: preferences.appendingPathComponent("com.docomoz.pisa.plist"))
        try spool.record(.listFolders)
        XCTAssertTrue(try spool.drain().isEmpty)
    }

    func testEventContainsOnlyKnownToolAndOutcome() {
        let event = UsageEvent.mcpToolCall(.init(tool: .searchTranscripts, succeeded: false))
        XCTAssertEqual(event.type, "MCP.toolCalled")
        XCTAssertEqual(event.parameters, ["tool": "search_transcripts", "outcome": "failure"])
        XCTAssertNil(event.minutes)
    }

    func testSpoolIsBoundedAndQueueDeduplicatesRepeatedCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = MCPAnalyticsSpool(root: root)
        try spool.setEnabled(true)
        for _ in 0..<205 { try spool.record(.listMeetings) }
        let first = try spool.drain(accept: { _ in false })
        XCTAssertEqual(first.count, 200)
        var queue = UsageEventQueue(limit: 250)
        for _ in 0..<2 {
            for item in try spool.drain(accept: { _ in false }) {
                queue.append(.mcpToolCall(item.call), id: item.id, date: item.date)
            }
        }
        XCTAssertEqual(queue.pending.count, 200)
        try spool.setEnabled(false)
        XCTAssertTrue(try spool.drain().isEmpty)
    }

    func testCorruptOptOutPreferencesFailClosed() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let library = container.appendingPathComponent("Library")
        let preferences = library.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        let spool = MCPAnalyticsSpool(root: library.appendingPathComponent("Application Support/Pisa"))
        try spool.setEnabled(true)
        try Data("broken".utf8).write(to: preferences.appendingPathComponent("com.docomoz.pisa.plist"))
        try spool.record(.listFolders)
        XCTAssertTrue(try spool.drain().isEmpty)
    }

}

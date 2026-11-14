import XCTest
@testable import PisaCore

final class UsageAnalyticsTests: XCTestCase {
    func testQueueRoundTripPreservesPendingEventsAndAcknowledgesOnlySentItems() throws {
        var queue = UsageEventQueue(limit: 3)
        queue.append(.appLaunched)
        queue.append(.recordingSaved(duration: 120, automatic: true))
        let sent = queue.pending
        let data = try JSONEncoder().encode(queue)
        var restored = try JSONDecoder().decode(UsageEventQueue.self, from: data)
        XCTAssertEqual(restored.pending, sent)

        restored.append(.appActivated)
        restored.acknowledge(sent)
        XCTAssertEqual(restored.pending.map(\.event), [.appActivated])
    }

    func testQueueIsBoundedAndDiscardsOldestItems() throws {
        var queue = UsageEventQueue(limit: 2)
        queue.append(.appLaunched)
        queue.append(.appActivated)
        queue.append(.audioImported(duration: 60))
        let restored = try JSONDecoder().decode(UsageEventQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(restored.pending.map(\.event), [.appActivated, .audioImported(duration: 60)])
    }

    func testDiscardOlderRetainsEventAtCutoff() throws {
        struct StoredQueue: Encodable {
            let pending: [UsageEventQueue.Item]
            let limit: Int
        }
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [-1.0, 0.0, 1.0].map {
            UsageEventQueue.Item(id: UUID(), date: cutoff.addingTimeInterval($0), event: .appLaunched)
        }
        let data = try JSONEncoder().encode(StoredQueue(pending: items, limit: 10))
        var restored = try JSONDecoder().decode(UsageEventQueue.self, from: data)
        restored.discardOlder(than: cutoff)
        XCTAssertEqual(restored.pending, Array(items.dropFirst()))
    }

    func testEventNamesAndParametersAreRestrictedToDefinedValues() {
        let events: [UsageEvent] = [
            .appLaunched, .appActivated,
            .recordingStarted(automatic: false), .recordingStarted(automatic: true),
            .recordingSaved(duration: 60, automatic: true), .audioImported(duration: 60),
            .transcriptionStarted(mode: "live", reprocess: false),
            .transcriptionStarted(mode: "resume", reprocess: true),
            .transcriptionCompleted(mode: "batch", reprocess: false, duration: 60),
            .transcriptionFailed(mode: "Meeting name or private text", cancelled: false, reprocess: true),
            .transcriptionFailed(mode: "live", cancelled: true, reprocess: false)
        ]
        XCTAssertEqual(Set(events.map(\.type)), Set([
            "App.launched", "App.activated", "Recording.started", "Recording.saved", "Audio.imported",
            "Transcription.started", "Transcription.completed", "Transcription.failed", "Transcription.cancelled"
        ]))
        for event in events {
            XCTAssertTrue(Set(event.parameters.keys).isSubset(of: ["start", "mode", "reprocess"]))
            if let value = event.parameters["start"] { XCTAssertTrue(["automatic", "manual"].contains(value)) }
            if let value = event.parameters["mode"] { XCTAssertTrue(["live", "resume", "batch", "other"].contains(value)) }
            if let value = event.parameters["reprocess"] { XCTAssertTrue(["yes", "no"].contains(value)) }
        }
        XCTAssertEqual(events[9].parameters["mode"], "other")
    }

    func testFeatureEventsUseOnlyFixedNamesAndValues() {
        let features = TrackedFeature.allCases.map(UsageEvent.feature)
        XCTAssertEqual(Set(features.map(\.type)), Set([
            "Library.meetingMoved", "Library.folderCreated", "Transcript.termsReplaced",
            "Dictionary.termAdded", "Audio.cleanedUp", "Audio.deleted", "Export.transcript", "Export.audio",
            "Library.searched", "Playback.segmentStarted", "Playback.recordingStarted", "Transcript.edited"
        ]))
        XCTAssertTrue(features.allSatisfy { $0.parameters.isEmpty && $0.minutes == nil })
        XCTAssertEqual(Set(TrackedSetting.allCases.map(\.rawValue)),
                       Set(["automatic_recording", "background_transcription", "automatic_export", "mcp"]))
        for setting in TrackedSetting.allCases {
            XCTAssertEqual(UsageEvent.setting(setting, enabled: true).type, "Setting.changed")
            XCTAssertEqual(UsageEvent.setting(setting, enabled: true).parameters,
                           ["setting": setting.rawValue, "enabled": "yes"])
            XCTAssertEqual(UsageEvent.setting(setting, enabled: false).parameters,
                           ["setting": setting.rawValue, "enabled": "no"])
        }
        XCTAssertEqual(UsageEvent.voiceAssigned(remembered: true, allMatching: false).type, "Voice.assigned")
        XCTAssertEqual(UsageEvent.voiceAssigned(remembered: true, allMatching: false).parameters,
                       ["remembered": "yes", "all_matching": "no"])
    }

    func testDurationsAreFiniteNonnegativeRoundedMinutesAndCapped() {
        let event = { (seconds: Double) in UsageEvent.audioImported(duration: seconds).minutes }
        XCTAssertNil(event(.nan))
        XCTAssertNil(event(.infinity))
        XCTAssertNil(event(-1))
        XCTAssertEqual(event(0), 0)
        XCTAssertEqual(event(3), 0.1)
        XCTAssertEqual(event(60), 1)
        XCTAssertEqual(event(86_400), 1_440)
        XCTAssertEqual(event(100_000), 1_440)
        XCTAssertNil(UsageEvent.transcriptionCompleted(mode: "batch", reprocess: false, duration: -.infinity).minutes)
        XCTAssertEqual(UsageEvent.recordingSaved(duration: 120, automatic: false).minutes, 2)
    }
}

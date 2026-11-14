import XCTest
@testable import PisaCore

final class RecordingModelAnalyticsTests: XCTestCase {
    func testRecordingIssuesContainOnlyFixedStages() {
        let stages: [UsageEvent.RecordingIssue] = [.start, .interrupted, .stop, .partial]
        XCTAssertEqual(stages.map { UsageEvent.recordingIssue($0).parameters }, [
            ["stage": "start"], ["stage": "interrupted"], ["stage": "stop"], ["stage": "partial"]
        ])
        for stage in stages {
            let event = UsageEvent.recordingIssue(stage)
            XCTAssertEqual(event.type, "Recording.issue")
            XCTAssertNil(event.minutes)
        }
    }

    func testModelInstallEventsHaveNoParametersOrAudioDuration() {
        let events: [UsageEvent] = [.modelInstallStarted, .modelInstallCompleted, .modelInstallFailed, .modelInstallCancelled]
        XCTAssertEqual(events.map(\.type), ["ModelInstall.started", "ModelInstall.completed", "ModelInstall.failed", "ModelInstall.cancelled"])
        for event in events {
            XCTAssertTrue(event.parameters.isEmpty)
            XCTAssertNil(event.minutes)
        }
    }
}

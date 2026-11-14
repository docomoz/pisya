import Foundation
import XCTest
@testable import PisaCore

// These are presentation *behaviour* checks, not proof of rendered layout.
// The native controls probe and the UI matrix still own clipping, focus and input.
// History: 2eb4821/aeb7bc6 (dates), b3c0382/b64ddab (search highlights),
// 522745b/ed42e7d (voice drafts/groups), 94a7767/b5f75ee (interrupted progress).
final class InterfaceDateRegressionTests: XCTestCase {
    private func makeCalendar(_ timeZone: String = "Europe/Moscow") throws -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                      in calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    func testSameRecordingChangesFromTodayToYesterdayToAbsoluteDate() throws {
        let calendar = try makeCalendar()
        let recorded = try date(2026, 11, 12, 23, 50, in: calendar)
        let beforeMidnight = try date(2026, 11, 12, 23, 55, in: calendar)
        let afterMidnight = try date(2026, 11, 13, 0, 1, in: calendar)
        let twoDaysLater = try date(2026, 11, 14, 0, 1, in: calendar)

        for compact in [false, true] {
            XCTAssertEqual(meetingDateLabel(recorded, now: beforeMidnight, calendar: calendar, compact: compact),
                           "Сегодня в\u{00a0}23:50")
            XCTAssertEqual(meetingDateLabel(recorded, now: afterMidnight, calendar: calendar, compact: compact),
                           "Вчера в\u{00a0}23:50")
        }
        XCTAssertEqual(meetingDateLabel(recorded, now: twoDaysLater, calendar: calendar),
                       "12\u{00a0}ноября в\u{00a0}23:50")
        XCTAssertEqual(meetingDateLabel(recorded, now: twoDaysLater, calendar: calendar, compact: true),
                       "12.11, 23:50")
    }

    func testYesterdayUsesCalendarDaysAcrossTheAutumnClockChange() throws {
        let calendar = try makeCalendar("America/New_York")
        let recorded = try date(2026, 10, 31, 23, 30, in: calendar)
        let now = try date(2026, 11, 1, 23, 0, in: calendar)
        // The previous local day can be more than 24 hours ago.
        XCTAssertGreaterThan(now.timeIntervalSince(recorded), 24 * 60 * 60)
        for compact in [false, true] {
            XCTAssertEqual(meetingDateLabel(recorded, now: now, calendar: calendar, compact: compact),
                           "Вчера в\u{00a0}23:30")
        }
    }

    func testChangingTimeZoneUpdatesBothTheRelativeDayAndTheClock() throws {
        let parser = ISO8601DateFormatter()
        let recorded = try XCTUnwrap(parser.date(from: "2026-11-11T22:30:00Z"))
        let now = try XCTUnwrap(parser.date(from: "2026-11-12T08:00:00Z"))
        let moscow = try makeCalendar("Europe/Moscow")
        let newYork = try makeCalendar("America/New_York")

        XCTAssertEqual(meetingDateLabel(recorded, now: now, calendar: moscow), "Сегодня в\u{00a0}01:30")
        XCTAssertEqual(meetingDateLabel(recorded, now: now, calendar: newYork), "Вчера в\u{00a0}17:30")
        XCTAssertEqual(meetingDateLabel(recorded, now: now, calendar: moscow, showsRelativeDay: false, compact: true),
                       "12.11, 01:30")
        XCTAssertEqual(meetingDateLabel(recorded, now: now, calendar: newYork, showsRelativeDay: false, compact: true),
                       "11.11, 17:30")
    }

    func testAbsoluteLabelsStayStableAcrossMidnight() throws {
        let calendar = try makeCalendar()
        let recorded = try date(2026, 11, 12, 23, 50, in: calendar)
        let referenceDates = [recorded, try date(2026, 11, 13, 0, 1, in: calendar)]
        for now in referenceDates {
            XCTAssertEqual(meetingDateLabel(recorded, now: now, calendar: calendar, showsRelativeDay: false),
                           "12\u{00a0}ноября в\u{00a0}23:50")
        }
    }

    func testSavedMinutesRoundUpWhileLiveAndTranscriptClocksKeepSeconds() {
        let cases: [(Double, String, String, String)] = [
            (59.999, "1\u{00a0}мин", "00:59", "00:59"),
            (60.001, "2\u{00a0}мин", "01:00", "01:00"),
            (3_599.999, "1\u{00a0}ч", "59:59", "59:59"),
            (3_600.001, "1\u{00a0}ч\u{00a0}1\u{00a0}мин", "01:00:00", "1:00:00"),
            (27 * 3_600 + 3 * 60 + 1, "27\u{00a0}ч\u{00a0}4\u{00a0}мин", "27:03:01", "27:03:01")
        ]
        for (seconds, saved, live, transcript) in cases {
            XCTAssertEqual(sidebarDuration(seconds), saved, "duration: \(seconds)")
            XCTAssertEqual(recordingTimecode(seconds), live, "duration: \(seconds)")
            XCTAssertEqual(timecode(seconds), transcript, "duration: \(seconds)")
        }
    }

    func testMissingClockMeasurementsDoNotBecomeNegativeOrInvalidLiveLabels() {
        for seconds in [-1.0, -.infinity, .infinity, .nan] {
            XCTAssertEqual(recordingTimecode(seconds), "00:00")
        }
    }
}

final class InterfaceSearchRegressionTests: XCTestCase {
    private func highlightedParts(in value: String, query: String,
                                  file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let ranges = transcriptSearchRanges(in: value, query: query)
        let attributed = AttributedString(value)
        var previousEnd = 0
        var parts: [String] = []
        for range in ranges {
            XCTAssertGreaterThan(range.length, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(range.location, previousEnd, file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(range), (value as NSString).length, file: file, line: line)
            // ScreenTypography converts these exact UTF-16 ranges to attributed runs.
            if let textRange = Range(range, in: value) {
                XCTAssertNotNil(Range(textRange, in: attributed), file: file, line: line)
                parts.append(String(value[textRange]))
            } else {
                XCTFail("Search range splits a displayed character: \(range)", file: file, line: line)
            }
            previousEnd = NSMaxRange(range)
        }
        return parts
    }

    func testDictionaryHighlightsKeepUnicodeOffsetsAndAbbreviationEndings() {
        let text = "👩🏽‍💻 ЛПР'ов, лпр'ом и ЛПР'ы"
        XCTAssertEqual(highlightedParts(in: text, query: "лпр"), ["ЛПР", "лпр", "ЛПР"])
        XCTAssertEqual(highlightedParts(in: text, query: "ЛПР'ом"), ["лпр'ом"])
        XCTAssertEqual(transcriptSearchRanges(in: text, query: "лпр").first?.location,
                       ("👩🏽‍💻 " as NSString).length)
    }

    func testTechnicalDictionaryQueriesAreLiteralRatherThanRegularExpressions() {
        let text = "C++, c++, .NET, xNET, API [v2], API v2, A.B"
        XCTAssertEqual(highlightedParts(in: text, query: "C++"), ["C++", "c++"])
        XCTAssertEqual(highlightedParts(in: text, query: ".NET"), [".NET"])
        XCTAssertEqual(highlightedParts(in: text, query: "API [v2]"), ["API [v2]"])
        XCTAssertTrue(highlightedParts(in: text, query: "A.*B").isEmpty)
    }

    func testHighlightsUseDisplayedOffsetsAfterTypographyChangesTheLength() {
        let raw = "👩🏽‍💻 75 % API и API"
        let displayed = typographicText(raw)
        XCTAssertNotEqual((raw as NSString).length, (displayed as NSString).length)
        XCTAssertEqual(highlightedParts(in: displayed, query: "api"), ["API", "API"])
        XCTAssertEqual(highlightedParts(in: displayed, query: "и API"), ["и\u{00a0}API"])
        XCTAssertEqual(transcriptSearchRanges(in: displayed, query: "API").first?.location,
                       ("👩🏽‍💻 75% " as NSString).length)
    }

    func testAdjacentMatchesRemainSeparateAndEmptyOrMissingQueriesReturnNoRanges() {
        let text = "APIAPI API"
        XCTAssertEqual(highlightedParts(in: text, query: "API"), ["API", "API", "API"])
        XCTAssertTrue(highlightedParts(in: text, query: "не найдено").isEmpty)
        XCTAssertTrue(highlightedParts(in: text, query: "").isEmpty)
        XCTAssertEqual(highlightedParts(in: text, query: "apiapi"), ["APIAPI"])
    }
}

final class InterfaceVoiceDraftRegressionTests: XCTestCase {
    func testReloadedSelectedFragmentRetainsEvenAnEmptyUnsavedName() throws {
        var selected = TranscriptSegment(start: 0, end: 4, speaker: "Голос 1", text: "Тестовая реплика")
        // A background update/reload can replace the struct while playback reselects its ID.
        selected.speaker = "Анна"
        let reloaded = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(selected))
        for draft in ["", "  ", "Анна Петрова", "Новое имя 👩🏽‍💻"] {
            XCTAssertEqual(voiceNameForSelection(currentSpeaker: selected.speaker, currentName: draft, segment: reloaded), draft)
        }
    }

    func testChoosingAnotherFragmentOfTheSameSpeakerRetainsUnappliedName() {
        let first = TranscriptSegment(start: 0, end: 4, speaker: "Голос 1", text: "Первая реплика")
        let second = TranscriptSegment(start: 8, end: 12, speaker: "Голос 1", text: "Другая реплика")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(voiceNameForSelection(currentSpeaker: first.speaker, currentName: "Черновик имени", segment: second),
                       "Черновик имени")
    }

    func testRenamingToAnExistingParticipantMergesGroupsAtTheEarliestFragment() throws {
        var first = TranscriptSegment(start: 0, end: 4, speaker: "Голос 1", text: "Первая реплика")
        let other = TranscriptSegment(start: 5, end: 9, speaker: "Борис", text: "Ответ")
        let existing = TranscriptSegment(start: 10, end: 14, speaker: "Анна", text: "Продолжение")
        var later = TranscriptSegment(start: 15, end: 19, speaker: "Голос 1", text: "Ещё реплика")
        first.speaker = "Анна"
        later.speaker = "Анна"
        let reloaded = try JSONDecoder().decode([TranscriptSegment].self,
                                               from: JSONEncoder().encode([first, other, existing, later]))
        let anchors = voiceGroupAnchors(in: reloaded)
        XCTAssertEqual(anchors.map(\.id), [first.id, other.id])
        XCTAssertEqual(anchors.map(\.speaker), ["Анна", "Борис"])
        XCTAssertEqual(voiceSamples(for: "Анна", in: reloaded).map(\.id), [first.id, existing.id])
    }
}

final class InterfaceProgressRegressionTests: XCTestCase {
    private func interruptedMeeting() -> Meeting {
        var meeting = Meeting(title: "Проверка состояния", source: "Тестовое аудио")
        meeting.status = .failed
        meeting.duration = 100
        meeting.liveCommittedUntil = 25
        return meeting
    }

    func testInvalidBatchProgressFallsBackToTheDurableLiveCheckpoint() {
        var meeting = interruptedMeeting()
        for progress in [-0.1, 1.1, .nan, .infinity, -.infinity] {
            meeting.interruptedBatchProgress = progress
            XCTAssertEqual(meeting.interruptedTranscriptionProgress, .savedAudio(0.25))
        }
    }

    func testNewBatchAtZeroDoesNotReuseAnOlderLivePercentage() throws {
        var meeting = interruptedMeeting()
        meeting.interruptedBatchProgress = 0
        let reloaded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(reloaded.interruptedTranscriptionProgress, .batch(0))
    }

    func testInterruptedProgressIsOnlyExposedInTheFailedState() {
        var meeting = interruptedMeeting()
        XCTAssertEqual(meeting.interruptedTranscriptionProgress, .savedAudio(0.25))
        for status in [MeetingStatus.recorded, .processing, .ready] {
            meeting.status = status
            XCTAssertNil(meeting.interruptedTranscriptionProgress, "status: \(status)")
        }
        meeting.status = .failed
        meeting.interruptedBatchProgress = 0.5
        XCTAssertEqual(meeting.interruptedTranscriptionProgress, .batch(0.5))
    }

    func testUnusableCheckpointsDoNotInventAnInterruptedPercentage() {
        var meeting = interruptedMeeting()
        meeting.interruptedBatchProgress = nil
        for checkpoint in [-1.0, 101, .nan, .infinity] {
            meeting.liveCommittedUntil = checkpoint
            XCTAssertNil(meeting.interruptedTranscriptionProgress)
        }
    }
}

// REC-01/02 and DATA-04: these are the decisions used by MeetingView itself.
// They do not assert that a referenced file exists or that a player can decode it.
final class MeetingPresentationRegressionTests: XCTestCase {
    private func makeMeeting(status: MeetingStatus, hasText: Bool = false) -> Meeting {
        var meeting = Meeting(title: "Синтетическая встреча", source: "Тестовое аудио")
        meeting.status = status
        meeting.audioFiles = ["test-mic.caf"]
        if hasText {
            meeting.segments = [TranscriptSegment(start: 0, end: 4, speaker: "Анна", text: "Проверка интерфейса")]
        }
        return meeting
    }

    func testSavedMeetingStatesExposeOnlyTheirApplicableControls() {
        typealias Scenario = (name: String, status: MeetingStatus, hasText: Bool, queued: Bool,
                              processing: Bool, tools: Bool, automaticPlayer: Bool, statusVisible: Bool)
        let cases: [Scenario] = [
            ("recorded, no text", .recorded, false, false, false, false, true, false),
            ("recorded, draft", .recorded, true, false, false, false, false, false),
            ("failed, no text", .failed, false, false, false, false, true, false),
            ("failed, draft", .failed, true, false, false, false, false, true),
            ("queued, no text", .recorded, false, true, false, false, true, true),
            ("queued, old ready text", .ready, true, true, false, false, false, true),
            ("processing, no text", .processing, false, false, true, false, true, true),
            ("processing, draft", .processing, true, false, true, false, false, true),
            ("ready, no text", .ready, false, false, false, true, false, false),
            ("ready, text", .ready, true, false, false, true, false, false)
        ]
        for scenario in cases {
            let meeting = makeMeeting(status: scenario.status, hasText: scenario.hasText)
            let presentation = MeetingPresentation(
                meeting: meeting, recordingID: nil, savingID: nil,
                processingID: scenario.processing ? meeting.id : nil, isQueued: scenario.queued)
            XCTAssertFalse(presentation.isRecording, scenario.name)
            XCTAssertFalse(presentation.isSaving, scenario.name)
            XCTAssertEqual(presentation.isQueued, scenario.queued, scenario.name)
            XCTAssertEqual(presentation.isTranscribing, scenario.processing, scenario.name)
            XCTAssertEqual(presentation.showsTranscriptTools, scenario.tools, scenario.name)
            XCTAssertEqual(presentation.showsAutomaticPlayer, scenario.automaticPlayer, scenario.name)
            XCTAssertEqual(presentation.showsTranscriptStatus, scenario.statusVisible, scenario.name)
            XCTAssertTrue(presentation.allowsSavedAudio, scenario.name)
        }
    }

    func testRecordingAndSavingHideSavedAudioAndToolsEvenIfTheOldStatusWasReady() {
        for status in [MeetingStatus.recorded, .processing, .ready, .failed] {
            for hasText in [false, true] {
                let meeting = makeMeeting(status: status, hasText: hasText)
                let recording = MeetingPresentation(meeting: meeting, recordingID: meeting.id,
                                                    savingID: nil, processingID: nil, isQueued: false)
                XCTAssertTrue(recording.isRecording)
                XCTAssertFalse(recording.allowsSavedAudio, "recording \(status), text: \(hasText)")
                XCTAssertFalse(recording.showsTranscriptTools, "recording \(status), text: \(hasText)")

                let saving = MeetingPresentation(meeting: meeting, recordingID: nil,
                                                 savingID: meeting.id, processingID: nil, isQueued: false)
                XCTAssertTrue(saving.isSaving)
                XCTAssertFalse(saving.allowsSavedAudio, "saving \(status), text: \(hasText)")
                XCTAssertFalse(saving.showsTranscriptTools, "saving \(status), text: \(hasText)")
                XCTAssertTrue(saving.showsTranscriptStatus, "saving \(status), text: \(hasText)")
            }
        }
    }

    func testWorkOnAnotherRecordingDoesNotHideTheSelectedMeetingControls() {
        let otherID = UUID()
        for status in [MeetingStatus.recorded, .processing, .ready, .failed] {
            let meeting = makeMeeting(status: status, hasText: true)
            let idle = MeetingPresentation(meeting: meeting, recordingID: nil, savingID: nil,
                                           processingID: nil, isQueued: false)
            let otherWork = MeetingPresentation(meeting: meeting, recordingID: otherID, savingID: otherID,
                                                processingID: otherID, isQueued: false)
            XCTAssertEqual(otherWork, idle, "Selected meeting status: \(status)")
            XCTAssertTrue(otherWork.allowsSavedAudio)
            XCTAssertFalse(otherWork.isTranscribing)
        }
    }

    func testRecordingSavingQueueProcessingAndReadyTransition() {
        var meeting = makeMeeting(status: .recorded)
        var recordingID: UUID? = meeting.id
        var savingID: UUID? = nil
        var processingID: UUID? = nil
        var queued = false
        func current() -> MeetingPresentation {
            MeetingPresentation(meeting: meeting, recordingID: recordingID, savingID: savingID,
                                processingID: processingID, isQueued: queued)
        }

        XCTAssertTrue(current().isRecording)
        XCTAssertFalse(current().showsTranscriptTools)
        XCTAssertFalse(current().allowsSavedAudio)

        recordingID = nil
        savingID = meeting.id
        XCTAssertTrue(current().isSaving)
        XCTAssertTrue(current().showsTranscriptStatus)
        XCTAssertFalse(current().showsTranscriptTools)
        XCTAssertFalse(current().allowsSavedAudio)

        savingID = nil
        queued = true
        XCTAssertTrue(current().isQueued)
        XCTAssertTrue(current().showsTranscriptStatus)
        XCTAssertTrue(current().allowsSavedAudio)
        XCTAssertFalse(current().showsTranscriptTools)

        queued = false
        processingID = meeting.id
        meeting.status = .processing
        XCTAssertTrue(current().isTranscribing)
        XCTAssertTrue(current().showsTranscriptStatus)
        XCTAssertTrue(current().allowsSavedAudio)
        XCTAssertFalse(current().showsTranscriptTools)

        processingID = nil
        meeting.status = .ready
        meeting.segments = [TranscriptSegment(start: 0, end: 4, speaker: "Анна", text: "Готовый результат")]
        XCTAssertTrue(current().showsTranscriptTools)
        XCTAssertTrue(current().allowsSavedAudio)
        XCTAssertFalse(current().showsAutomaticPlayer)
        XCTAssertFalse(current().showsTranscriptStatus)
    }

    func testInterruptionKeepsSavedAudioReachableWithAndWithoutADraft() {
        for hasText in [false, true] {
            var meeting = makeMeeting(status: .processing, hasText: hasText)
            let active = MeetingPresentation(meeting: meeting, recordingID: nil, savingID: nil,
                                             processingID: meeting.id, isQueued: false)
            XCTAssertTrue(active.isTranscribing)

            meeting.status = .failed
            meeting.error = "Обработка остановлена. Аудио сохранено."
            let interrupted = MeetingPresentation(meeting: meeting, recordingID: nil, savingID: nil,
                                                  processingID: nil, isQueued: false)
            XCTAssertFalse(interrupted.isTranscribing)
            XCTAssertFalse(interrupted.showsTranscriptTools)
            XCTAssertTrue(interrupted.allowsSavedAudio)
            XCTAssertEqual(interrupted.showsAutomaticPlayer, !hasText)
            XCTAssertEqual(interrupted.showsTranscriptStatus, hasText)
        }
    }

    func testProcessingIdentityAloneDoesNotMakeACompletedMeetingLookBusy() {
        let meeting = makeMeeting(status: .ready, hasText: true)
        let presentation = MeetingPresentation(meeting: meeting, recordingID: nil, savingID: nil,
                                               processingID: meeting.id, isQueued: false)
        XCTAssertFalse(presentation.isTranscribing)
        XCTAssertFalse(presentation.showsTranscriptStatus)
        XCTAssertTrue(presentation.showsTranscriptTools)
        XCTAssertTrue(presentation.allowsSavedAudio)
    }
}

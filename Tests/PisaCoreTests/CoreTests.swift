import XCTest
@testable import PisaCore
final class CoreTests: XCTestCase {
    func testVoiceNameSuggestionsCombineSavedAndMeetingNamesWithoutCaseDuplicates() {
        XCTAssertEqual(voiceNameSuggestions(query: "артем", meetingNames: ["артём Смирнов", "Артём Петров", "Спикер 1"], savedNames: ["Артём Смирнов", "МАРТА"]), ["Артём Смирнов", "Артём Петров"])
        XCTAssertEqual(voiceNameSuggestions(query: " СМИР", meetingNames: [], savedNames: ["Артём Смирнов", "Анна"]), ["Артём Смирнов"])
        XCTAssertTrue(voiceNameSuggestions(query: "  ", meetingNames: ["Артём"], savedNames: []).isEmpty)
        XCTAssertTrue(voiceNameSuggestions(query: "Артём", meetingNames: [], savedNames: ["Артём"]).isEmpty)
    }

    func testVoiceNameSuggestionsMatchPrefixesOfAnyNameWord() {
        let savedNames = ["Денис Петров", "Наталья Иванова"]
        let meetingNames = ["Лидия Смирнова", "Анна-Мария Петровна"]
        XCTAssertEqual(voiceNameSuggestions(query: "И", meetingNames: meetingNames, savedNames: savedNames), ["Наталья Иванова"])
        XCTAssertEqual(voiceNameSuggestions(query: "ива нат", meetingNames: meetingNames, savedNames: savedNames), ["Наталья Иванова"])
        XCTAssertEqual(voiceNameSuggestions(query: "мар петр", meetingNames: meetingNames, savedNames: savedNames), ["Анна-Мария Петровна"])
        XCTAssertTrue(voiceNameSuggestions(query: "нат ван", meetingNames: meetingNames, savedNames: savedNames).isEmpty)
    }

    func testTranscriptSearchFindsEveryCaseInsensitiveSubstring() {
        let text = "😀 Смерцы, СМЕРЦЫ и смерцы"
        let ranges = transcriptSearchRanges(in: text, query: "смер")
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["Смер", "СМЕР", "смер"])
        XCTAssertEqual(ranges.first?.location, 3) // Emoji occupies two UTF-16 code units.
        XCTAssertTrue(transcriptSearchRanges(in: text, query: "").isEmpty)
        XCTAssertTrue(transcriptSearchRanges(in: text, query: "другое").isEmpty)
    }

    func testTranscriptSearchMatchesAcrossTypographicSpacesWithoutChangingOffsets() {
        let text = typographicText("Я в Москве, а в Москве ещё снег")
        let ranges = transcriptSearchRanges(in: text, query: "в Москве")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["в\u{00a0}Москве", "в\u{00a0}Москве"])
        XCTAssertEqual(transcriptSearchRanges(in: "Я в Москве", query: "в\u{00a0}Москве").count, 1)
        XCTAssertEqual(transcriptSearchRanges(in: "Спикер 1", query: "СПИКЕР"), [NSRange(location: 0, length: 6)])
    }

    func testVoiceNameDraftFollowsSpeakerAcrossSamples() {
        let first = TranscriptSegment(start: 0, end: 2, speaker: "Спикер 1", text: "Первый")
        let second = TranscriptSegment(start: 3, end: 5, speaker: "Спикер 1", text: "Второй")
        let other = TranscriptSegment(start: 6, end: 8, speaker: "Спикер 2", text: "Другой")
        XCTAssertEqual(voiceNameForSelection(currentSpeaker: first.speaker, currentName: "Юра Соколов", segment: first), "Юра Соколов")
        XCTAssertEqual(voiceNameForSelection(currentSpeaker: first.speaker, currentName: "Юра Соколов", segment: second), "Юра Соколов")
        XCTAssertEqual(voiceNameForSelection(currentSpeaker: first.speaker, currentName: "Юра Соколов", segment: other), "Спикер 2")
        XCTAssertEqual(voiceNameForSelection(currentSpeaker: nil, currentName: "", segment: first), "Спикер 1")
    }

    func testSidebarDurationRoundsUpAndUsesNonbreakingUnits() {
        let space = "\u{00A0}"
        for (seconds, expected) in [
            (0.0, "0\(space)мин"), (0.1, "1\(space)мин"), (11, "1\(space)мин"),
            (60, "1\(space)мин"), (61, "2\(space)мин"), (118, "2\(space)мин"),
            (3599, "1\(space)ч"), (3600, "1\(space)ч"),
            (3601, "1\(space)ч\(space)1\(space)мин"), (7199, "2\(space)ч")
        ] { XCTAssertEqual(sidebarDuration(seconds), expected) }
        XCTAssertEqual(sidebarDuration(-1), "0\(space)мин")
        XCTAssertEqual(sidebarDuration(.nan), "—")
        XCTAssertEqual(sidebarDuration(.infinity), "—")
        XCTAssertEqual(sidebarDuration(.greatestFiniteMagnitude), "—")
    }

    func testRecordingCounterSwitchesToHoursAtOneHour() {
        XCTAssertEqual(recordingTimecode(0), "00:00")
        XCTAssertEqual(recordingTimecode(9), "00:09")
        XCTAssertEqual(recordingTimecode(10), "00:10")
        XCTAssertEqual(recordingTimecode(3599), "59:59")
        XCTAssertEqual(recordingTimecode(3600), "01:00:00")
        XCTAssertEqual(recordingTimecode(6000), "01:40:00")
        XCTAssertEqual(recordingTimecode(3601), "01:00:01")
        XCTAssertEqual(recordingTimecode(45296), "12:34:56")
    }
    func testCaptureTimelinePreservesDropoutsAndDetectsDuplicateBuffers() {
        XCTAssertEqual(AudioTimeline.adjustment(timestamp: 12, firstTimestamp: 10, framesWritten: 16000, sampleRate: 16000), 16000)
        XCTAssertEqual(AudioTimeline.adjustment(timestamp: 10.5, firstTimestamp: 10, framesWritten: 16000, sampleRate: 16000), -8000)
        XCTAssertEqual(AudioTimeline.adjustment(timestamp: 11.001, firstTimestamp: 10, framesWritten: 16000, sampleRate: 16000), 0)
    }
    func testPurgeOnlyTrashedAndRetainsSharedAudioAndVoiceSamples() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var active = Meeting(title: "Keep", source: "Synthetic")
        active.audioFiles = ["shared.caf"]; try lib.save(active)
        var trashed = Meeting(title: "Delete", source: "Synthetic")
        trashed.audioFiles = ["shared.caf", "private.caf"]; trashed.deletedAt = Date(); try lib.save(trashed)
        for name in trashed.audioFiles { try Data([1,2]).write(to: lib.audioURL(name)) }
        try lib.saveVoices([VoiceProfile(name: "Kept", samples: [[1,0]])])
        XCTAssertThrowsError(try lib.purgeTrashed(active.id))
        try lib.purgeTrashed(trashed.id)
        XCTAssertEqual(try lib.all(includeDeleted: true).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try lib.audioURL("shared.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try lib.audioURL("private.caf").path))
        XCTAssertEqual(try lib.voices().count, 1)
    }
    func testMeetingWideSpeakerCentroidsDoNotMultiplyAcrossWindows() {
        var segments: [TranscriptSegment] = []
        for i in 0..<150 {
            var a = TranscriptSegment(start: Double(i * 4), end: Double(i * 4 + 3), speaker: "Собеседники", text: "Fixture")
            a.embedding = i % 2 == 0 ? [1, Float(i % 5) * 0.04, 0] : [0, Float(i % 7) * 0.03, 1]
            segments.append(a)
        }
        let output = SpeakerClustering.assign(segments, profiles: [])
        XCTAssertEqual(Set(output.map(\.speaker)).count, 2)
        XCTAssertEqual(Set(stride(from: 0, to: 150, by: 2).map { output[$0].speaker }).count, 1)
        XCTAssertNotEqual(output[0].speaker, output[1].speaker)
    }
    func testShortAndInvalidVoicesDoNotCreatePeopleAndMicRemainsMe() {
        var short = TranscriptSegment(start: 0, end: 1, speaker: "Собеседники", text: "Да")
        short.embedding = [1,0]
        var invalid = short; invalid.embedding = [.nan,0]; invalid.end = 5
        var mic = short; mic.speaker = "Я"; mic.end = 4
        let result = SpeakerClustering.assign([short, invalid, mic], profiles: [VoiceProfile(name: "Remote", samples: [[1,0]])])
        XCTAssertEqual(result.map(\.speaker), ["Remote", "Собеседники", "Я"])
        XCTAssertEqual(SpeakerClustering.assign([short], profiles: []).first?.speaker, "Собеседники")
    }
    func testLegacyPreferencesDefaultToQuietProcessing() throws {
        let data = try JSONEncoder().encode(Preferences())
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: data).usesQuietProcessing)
        var preferences = Preferences(); preferences.quietProcessing = false
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).usesQuietProcessing)
    }
    func testFolderIconBackwardCompatibilityAndPersistence() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Работа\"}".utf8)
        let folder = try JSONDecoder().decode(MeetingFolder.self, from: legacy)
        XCTAssertEqual(folder.iconName, "folder")
        XCTAssertEqual(folder.id, id)
        var changed = folder
        changed.symbol = "briefcase"
        let restored = try JSONDecoder().decode(MeetingFolder.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(restored, changed)
        XCTAssertEqual(restored.iconName, "briefcase")
    }

    func testEchoRequiresSignalAndPreservesDoubleTalk() {
        var seed: UInt64 = 42
        func noise(_ count: Int) -> [Float] {
            (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23) * 0.2
            }
        }
        let reference = noise(37600)
        let echo = Array(reference[4000..<36000]).map { $0 * 0.4 }
        XCTAssertTrue(EchoDetector.isEcho(microphone: echo, reference: reference))
        let voice = noise(32000)
        XCTAssertFalse(EchoDetector.isEcho(microphone: zip(echo, voice).map(+), reference: reference))
        XCTAssertFalse(EchoDetector.isEcho(microphone: voice, reference: reference))
        XCTAssertFalse(EchoDetector.isEcho(microphone: Array(repeating: 0, count: 32000), reference: reference))
        XCTAssertTrue(EchoDetector.sameWords("Вот такой простой пример.", "А вот такой простой пример сегодня"))
        XCTAssertFalse(EchoDetector.sameWords("Вот такой другой пример", "Вот такой простой пример"))
        XCTAssertFalse(EchoDetector.sameWords("Да", "Да"))
    }
    func testAutomaticTitleAndRenamedMetadata() {
        var meeting = Meeting(title: "", source: "System")
        meeting.title = "Встреча · " + meeting.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))
        XCTAssertTrue(meeting.hasAutomaticTitle)
        XCTAssertEqual(meeting.headingTitle, "Созвон")
        meeting.automaticTitle = meeting.title
        meeting.title = "Планирование"
        XCTAssertFalse(meeting.hasAutomaticTitle)
        meeting.title = meeting.automaticTitle!
        XCTAssertTrue(meeting.hasAutomaticTitle)
    }
    func testAutomaticNamesFollowAudioSourceAndPreserveCustomNames() {
        var call = Meeting(title: "", source: "Системный звук")
        call.title = "Встреча · " + call.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))
        XCTAssertTrue(call.refreshAutomaticTitle())
        XCTAssertTrue(call.title.hasPrefix("Созвон · "))
        XCTAssertTrue(call.hasAutomaticTitle)
        XCTAssertFalse(call.refreshAutomaticTitle())
        call.title = "Планирование"
        XCTAssertFalse(call.refreshAutomaticTitle())
        XCTAssertEqual(call.title, "Планирование")
        var imported = Meeting(title: "", source: "Аудиофайл")
        imported.title = imported.defaultTitle; imported.automaticTitle = imported.title
        XCTAssertTrue(imported.title.hasPrefix("Запись · "))
        XCTAssertTrue(imported.hasAutomaticTitle)
        XCTAssertEqual(imported.headingTitle, "Запись")
        let customTitle = imported.title
        XCTAssertTrue(imported.rename(to: customTitle))
        XCTAssertEqual(imported.headingTitle, customTitle)
    }
    func testMeetingDateUsesLocalCalendarDayAtMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, minute: 5)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 55)))
        let older = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 30, hour: 23, minute: 55)))

        XCTAssertEqual(meetingDateLabel(now, now: now, calendar: calendar), "Сегодня в\u{00a0}00:05")
        XCTAssertEqual(meetingDateLabel(yesterday, now: now, calendar: calendar), "Вчера в\u{00a0}23:55")
        XCTAssertEqual(meetingDateLabel(older, now: now, calendar: calendar), "30\u{00a0}декабря в\u{00a0}23:55")
        XCTAssertEqual(meetingDateLabel(yesterday, now: now, calendar: calendar, showsRelativeDay: false), "31\u{00a0}декабря в\u{00a0}23:55")
    }
    func testDateYearAppearsAtCalendarAnniversary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 11, 3)
        XCTAssertFalse(meetingDateLabel(date(2026, 11, 3), now: now, calendar: calendar).contains("2026"))
        XCTAssertFalse(meetingDateLabel(date(2025, 11, 4), now: now, calendar: calendar).contains("2025"))
        XCTAssertTrue(meetingDateLabel(date(2025, 11, 3), now: now, calendar: calendar).contains("2025"))
        XCTAssertTrue(meetingDateLabel(date(2024, 2, 29), now: date(2025, 2, 28), calendar: calendar).contains("2024"))
        XCTAssertFalse(meetingDateLabel(date(2027, 1, 1), now: now, calendar: calendar).contains("2027"))
    }
    func testCompactMeetingDateKeepsYearAndTimeAtCalendarAnniversary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: 10, day: day, hour: 12, minute: 7))!
        }
        let now = date(2026, 8)
        XCTAssertEqual(meetingDateLabel(date(2025, 8), now: now, calendar: calendar, compact: true), "08.10.2025, 12:07")
        XCTAssertEqual(meetingDateLabel(date(2025, 9), now: now, calendar: calendar, compact: true), "09.10, 12:07")
        XCTAssertEqual(meetingDateLabel(now, now: now, calendar: calendar, compact: true), "Сегодня в\u{00a0}12:07")
        XCTAssertEqual(meetingDateLabel(date(2026, 7), now: now, calendar: calendar, compact: true), "Вчера в\u{00a0}12:07")
    }
    func testScreenTypographyBindsShortWordsDatesAndUnitsWithoutChangingCode() {
        XCTAssertEqual(typographicText("В папку отправляется текст для встречи"), "В\u{00a0}папку отправляется текст для\u{00a0}встречи")
        XCTAssertEqual(typographicText("3 ноября · 45 секунд · 16 кГц · 25%"), "3\u{00a0}ноября · 45\u{00a0}секунд · 16\u{00a0}кГц · 25%")
        XCTAssertEqual(typographicText("команда\nи результат"), "команда\nи\u{00a0}результат")
        XCTAssertEqual(typographicText("https://example.com/a/b?x=1"), "https://example.com/a/b?x=1")
        XCTAssertEqual(typographicText("https://example.com/a?x=25%20"), "https://example.com/a?x=25%20")
        let text = "А в папку для записи — через 45 секунд"
        XCTAssertEqual(typographicText(typographicText(text)), typographicText(text))
    }
    func testScreenTypographyKeepsPercentagesCompactWithoutChangingCurrency() {
        let text = "75% · 75 % · 75\u{00a0}% · 75\u{202f}% · 12,5 % · 12.5\u{202f}% · 50 ₽"
        XCTAssertEqual(typographicText(text), "75% · 75% · 75% · 75% · 12,5% · 12.5% · 50\u{00a0}₽")
    }

    func testScreenTypographySeparatesAWordFromADollarPrice() {
        XCTAssertEqual(typographicText("Купили за$37, позже за$12.50."), "Купили за\u{00a0}$37, позже за\u{00a0}$12.50.")
        XCTAssertEqual(typographicText("От$5 до$20, по$7 за штуку."), "От\u{00a0}$5 до\u{00a0}$20, по\u{00a0}$7 за\u{00a0}штуку.")
        XCTAssertEqual(typographicText("«За$37»"), "«За\u{00a0}$37»")
        XCTAssertEqual(typographicText("Купили за\u{00a0}$37."), "Купили за\u{00a0}$37.")
    }

    func testScreenTypographyLeavesDollarSignsInPathsURLsAndCode() {
        for value in ["/tmp/за$37", "за$37.txt", "https://example.com/за$37?q=37", "https://example.com/?q=за$37", "цена$37", "`echo за$37 test`"] {
            XCTAssertEqual(typographicText(value), value)
        }
    }

    func testMarkdownCompactsPercentagesInSavedTranscript() {
        var meeting = Meeting(title: "План", source: "Аудиофайл")
        let segment = TranscriptSegment(start: 0, end: 3, speaker: "Я", text: "Готовность 75\u{202f}%, время 45 секунд.")
        meeting.segments = [segment]
        XCTAssertTrue(MarkdownExporter.render(meeting).contains("Готовность 75%, время 45\u{00a0}секунд."))
        XCTAssertEqual(meeting.segments.first?.text, segment.text)
    }
    func temporaryLibrary() throws -> MeetingLibrary { try MeetingLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    func testFailedStartupDiscardsOnlyEmptyJournal() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var meeting = Meeting(title: "Отказ в доступе", source: "Толк")
        meeting.audioFiles = ["sample.caf"]
        try lib.save(meeting)
        try lib.discardEmptyDraft(meeting)
        XCTAssertTrue(try lib.all().isEmpty)
        try lib.save(meeting)
        try Data([1]).write(to: lib.audioURL("sample.caf"))
        try lib.discardEmptyDraft(meeting)
        XCTAssertEqual(try lib.all().count, 1)
        try FileManager.default.removeItem(at: lib.audioURL("sample.caf"))
        meeting.segments = [.init(start: 0, end: 1, speaker: "Я", text: "Текст")]
        try lib.save(meeting)
        try lib.discardEmptyDraft(meeting)
        XCTAssertEqual(try lib.all().count, 1)
    }
    func testLegacyMeetingsFoldersAndTrash() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var m = Meeting(title: "Old meeting", source: "Talk")
        m.segments = [.init(start: 0, end: 3, speaker: "Me", text: "Hello")]
        let legacy = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Meeting.self, from: legacy)
        XCTAssertNil(decoded.folderID); XCTAssertNil(decoded.deletedAt); XCTAssertNil(decoded.segments[0].audioFile)
        let folder = MeetingFolder(name: "Work")
        try lib.saveFolders([folder]); XCTAssertEqual(try lib.folders(), [folder])
        m.folderID = folder.id; m.deletedAt = Date(); try lib.save(m)
        XCTAssertTrue(try lib.all().isEmpty)
        XCTAssertEqual(try lib.all(includeDeleted: true).count, 1)
        m.deletedAt = nil; try lib.save(m)
        XCTAssertEqual(try lib.all().first?.folderID, folder.id)
        XCTAssertEqual(try lib.all().first?.segments, decoded.segments)
    }
    func testVoiceExamplesRoundTripAndIdentify() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let m = Meeting(title: "Meeting", source: "System")
        var profile = VoiceProfile(name: "Person", samples: [[1, 0]])
        profile.examples = [VoiceExample(file: "example.caf", meetingID: m.id, segmentID: UUID(), embedding: [1, 0])]
        try lib.saveVoices([profile]); try lib.save(m)
        let saved = try lib.voices()
        XCTAssertEqual(saved[0].examples?.first?.meetingID, m.id)
        XCTAssertEqual(VoiceMatcher.identify([1, 0], profiles: saved), "Person")
    }
    func testMeterDistinguishesSilentBuffersFromMissingBuffers() {
        var track = AudioMeterTrack()
        track.update(peak: 0, seconds: 1, lastWrite: 10, now: 10)
        XCTAssertTrue(track.isFresh(now: 10)); XCTAssertEqual(track.level, 0)
        track.update(peak: 0.1, seconds: 2, lastWrite: 11, now: 11)
        XCTAssertGreaterThan(track.level, 0)
        track.update(peak: 0.1, seconds: 2, lastWrite: 11, now: 15)
        XCTAssertFalse(track.isFresh(now: 15)); XCTAssertEqual(track.level, 0)
        XCTAssertEqual(track.seconds, 2)
        for _ in 0..<track.history.count { track.update(peak: 0, seconds: 2, lastWrite: 11, now: 16) }
        XCTAssertEqual(track.history.count, 512)
        XCTAssertEqual(track.historyTimes.count, track.history.count)
        XCTAssertEqual(track.historyTimes.last, 16)
        XCTAssertTrue(track.history.allSatisfy { $0 == 0 })
        XCTAssertEqual(AudioMeterTrack.displayLevel(.nan), 0)
        XCTAssertEqual(AudioMeterTrack.displayLevel(2), 1)
        XCTAssertEqual(AudioMeterTrack.displayLevel(0.0001), 0)
    }
    func testDetectorDoesNotStopBeforeCallAndIgnoresShortActivity() {
        var detector = CallDetector(); let now = Date()
        XCTAssertEqual(detector.update(active: false, now: now), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(300)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(301)), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(302)), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(360)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(361)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(365)), .start)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(366)), .none)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(411)), .stop)
    }
    func testDetectorDebouncesReconnectAndManualStop() {
        var detector = CallDetector(); let now = Date()
        XCTAssertEqual(detector.update(active: true, now: now), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(3)), .start)
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(5)), .none)
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(30)), .none)
        detector.manuallyStopped()
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(60)), .none)
        _ = detector.update(active: false, now: now.addingTimeInterval(61))
        _ = detector.update(active: false, now: now.addingTimeInterval(107))
        _ = detector.update(active: true, now: now.addingTimeInterval(110))
        XCTAssertEqual(detector.update(active: true, now: now.addingTimeInterval(114)), .start)
        _ = detector.update(active: false, now: now.addingTimeInterval(115))
        XCTAssertEqual(detector.update(active: false, now: now.addingTimeInterval(161)), .stop)
    }
    func testTypographyBindsShortWordsWithoutBreakingParagraphs() {
        XCTAssertEqual(typographicText("а в четверг"), "а\u{00a0}в\u{00a0}четверг")
        XCTAssertEqual(typographicText("Привет.\nСледующая строка"), "Привет.\nСледующая строка")
    }
    func testVoiceMatcherRejectsAmbiguityAndDifferentDimensions() {
        XCTAssertEqual(VoiceMatcher.similarity([1, 0], [0, 1]), 0)
        XCTAssertEqual(VoiceMatcher.similarity([1], [1, 0]), -1)
        let profiles = [VoiceProfile(name: "A", samples: [[1, 0]]), VoiceProfile(name: "B", samples: [[0.99, 0.01]])]
        XCTAssertNil(VoiceMatcher.identify([1, 0], profiles: profiles))
        XCTAssertEqual(VoiceMatcher.identify([1, 0], profiles: [profiles[0]]), "A")
        XCTAssertNil(VoiceMatcher.identify([0, 1], profiles: [profiles[0]]))
    }
    func testMeetingLibraryRoundTripAndSafeAudioPath() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let m = Meeting(title: "Встреча", source: "Толк")
        try lib.save(m); XCTAssertEqual(try lib.read(m.id), m)
        XCTAssertThrowsError(try lib.audioURL("../secret"))
    }
    func testExportKeepsItsDatedPathAfterTitleAndTimeZoneChange() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        var m = Meeting(title: "../Встреча\nтест", source: "Толк")
        m.date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T22:03:00Z"))
        m.segments = [.init(start: 12, end: 20, speaker: "Даша", text: "Проверка сохранения")]
        let moscow = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let first = try MarkdownExporter.export(m, to: lib.root, timeZone: moscow)
        XCTAssertEqual(first.deletingLastPathComponent().path, lib.root.appendingPathComponent("2026/11").path)
        XCTAssertEqual(first.lastPathComponent, "2026-11-01 01-03 — Встреча тест.md")
        m.title = "Новое название"
        let second = try MarkdownExporter.export(m, to: lib.root, timeZone: utc)
        XCTAssertEqual(first, second)
        let content = try String(contentsOf: second, encoding: .utf8)
        XCTAssertTrue(content.contains("# Новое название"))
        XCTAssertTrue(content.contains("00:12 · Даша"))
    }
    func testExportDoesNotOverwriteAnUnrelatedNoteWithTheSameName() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let first = Meeting(title: "Статус", source: "Толк")
        var second = Meeting(title: first.title, source: first.source)
        second.date = first.date
        let firstURL = try MarkdownExporter.export(first, to: lib.root)
        let secondURL = try MarkdownExporter.export(second, to: lib.root)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try MarkdownExporter.export(second, to: lib.root), secondURL)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), MarkdownExporter.render(first))
    }
    func testExportRefreshesAnExistingLegacyPath() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let m = Meeting(title: "Обновлённая тема", source: "Толк")
        let legacy = lib.root.appendingPathComponent("pisya-\(m.id.uuidString.lowercased()).md")
        try "---\nid: \(m.id.uuidString)\ndate: 2026-11-05T10:00:00Z\n---\n\n# Старая тема\n".write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(try MarkdownExporter.export(m, to: lib.root), legacy)
        XCTAssertTrue(try String(contentsOf: legacy, encoding: .utf8).contains("# Обновлённая тема"))
    }
    func testTrashingExportUsesMeetingIDAfterRenameAndKeepsOtherNotes() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let first = Meeting(title: "Статус", source: "Толк")
        var second = Meeting(title: first.title, source: first.source)
        second.date = first.date
        let target = try MarkdownExporter.export(first, to: lib.root)
        let other = try MarkdownExporter.export(second, to: lib.root)
        try MarkdownExporter.render(first).appending("\nМои правки\n").write(to: target, atomically: true, encoding: .utf8)
        var renamed = first
        renamed.title = "Обновлённая тема"
        let trashed = try XCTUnwrap(MarkdownExporter.trashExport(for: renamed, in: lib.root))
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try String(contentsOf: trashed, encoding: .utf8).hasSuffix("Мои правки\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertNil(try MarkdownExporter.trashExport(for: renamed, in: lib.root))
    }
    func testTrashingLegacyExportLeavesAManualExportAlone() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let meeting = Meeting(title: "Статус", source: "Толк")
        let legacy = lib.root.appendingPathComponent("pisya-\(meeting.id.uuidString.lowercased()).md")
        let manual = lib.root.appendingPathComponent("Статус.md")
        let month = lib.root.appendingPathComponent("2026/11", isDirectory: true)
        let datedManual = month.appendingPathComponent("2026-11-06 личные заметки.md")
        var datedMeeting = meeting
        datedMeeting.date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z"))
        let markdown = MarkdownExporter.render(meeting)
        try markdown.write(to: legacy, atomically: true, encoding: .utf8)
        try markdown.write(to: manual, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try markdown.write(to: datedManual, atomically: true, encoding: .utf8)
        let trashed = try XCTUnwrap(MarkdownExporter.trashExport(for: datedMeeting, in: lib.root))
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try String(contentsOf: manual, encoding: .utf8), markdown)
        let unexpected = try MarkdownExporter.trashExport(for: datedMeeting, in: lib.root)
        defer { if let unexpected { try? FileManager.default.removeItem(at: unexpected) } }
        XCTAssertNil(unexpected)
        XCTAssertEqual(try String(contentsOf: datedManual, encoding: .utf8), markdown)
    }
    func testTrashingExportDoesNotFollowSymlinkedYear() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let outside = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: outside.root) }
        var meeting = Meeting(title: "Статус", source: "Толк")
        meeting.date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z"))
        let target = try MarkdownExporter.export(meeting, to: outside.root, timeZone: .gmt)
        try FileManager.default.createSymbolicLink(
            at: lib.root.appendingPathComponent("2026"),
            withDestinationURL: outside.root.appendingPathComponent("2026")
        )
        let unexpected = try MarkdownExporter.trashExport(for: meeting, in: lib.root)
        defer { if let unexpected { try? FileManager.default.removeItem(at: unexpected) } }
        XCTAssertNil(unexpected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
    func testExportFindsAnExistingNoteWhenTheNewTimeZoneSkippedItsDate() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let apia = try XCTUnwrap(TimeZone(identifier: "Pacific/Apia"))
        var m = Meeting(title: "Статус", source: "Толк")
        m.date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2011-12-30T10:30:00Z"))
        let first = try MarkdownExporter.export(m, to: lib.root, timeZone: .gmt)
        XCTAssertEqual(try MarkdownExporter.export(m, to: lib.root, timeZone: apia), first)
    }
    func testExportIgnoresANonDirectoryAtTheNeighboringMonth() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let year = lib.root.appendingPathComponent("2026")
        try FileManager.default.createDirectory(at: year, withIntermediateDirectories: true)
        try Data().write(to: year.appendingPathComponent("10"))
        var m = Meeting(title: "Статус", source: "Толк")
        m.date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        let url = try MarkdownExporter.export(m, to: lib.root, timeZone: .gmt)
        XCTAssertEqual(url.deletingLastPathComponent().path, year.appendingPathComponent("11").path)
    }
    func testMarkdownExposesMeetingPropertiesAndKeepsNotesAndTranscript() throws {
        var m = Meeting(title: "Поиск: тест #1", source: "Толк")
        m.date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T14:03:00Z"))
        m.duration = 720.5
        m.notes = "Сверить сроки"
        m.segments = [
            .init(start: 0, end: 2, speaker: "Даша", text: "Начали"),
            .init(start: 2, end: 3, speaker: "О'Коннор", text: "Обсудили"),
            .init(start: 3, end: 4, speaker: "Даша", text: "Согласовали")
        ]
        let markdown = MarkdownExporter.render(m)
        let properties = try XCTUnwrap(markdown.components(separatedBy: "---\n").dropFirst().first)
        XCTAssertTrue(properties.contains("title: 'Поиск: тест #1'\n"))
        XCTAssertTrue(properties.contains("date: 2026-11-05T14:03:00Z\n"))
        XCTAssertTrue(properties.contains("source: 'Толк'\n"))
        XCTAssertTrue(properties.contains("duration_seconds: 720.5\n"))
        XCTAssertTrue(properties.contains("speakers:\n  - 'Даша'\n  - 'О''Коннор'\n"))
        XCTAssertTrue(markdown.contains("## Заметки\n\nСверить сроки"))
        XCTAssertTrue(markdown.contains("## Расшифровка\n\n**00:00 · Даша**\n\nНачали"))
    }
    func testMCPEnabledByDefaultAndRevokesDuringSession() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        let m = Meeting(title: "Встреча", source: "Толк"); try lib.save(m)
        let handler = MCPHandler(library: lib)
        func call(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] { handler.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])! }
        XCTAssertNotNil(call("tools/list")["error"])
        XCTAssertNotNil(call("initialize")["result"])
        XCTAssertNotNil(call("tools/list")["result"])
        XCTAssertNotNil(call("tools/call", ["name": "list_meetings"])["result"])
        XCTAssertNotNil(call("tools/call", ["name": "read_transcript", "arguments": ["meeting_id": "../../etc/passwd"]])["error"])
        var deleted = m; deleted.deletedAt = Date(); try lib.save(deleted)
        XCTAssertNotNil(call("tools/call", ["name": "read_transcript", "arguments": ["meeting_id": m.id.uuidString]])["error"])
        var prefs = try lib.preferences(); prefs.mcpEnabled = false; try lib.savePreferences(prefs)
        XCTAssertNotNil(call("tools/list")["error"])
        XCTAssertNotNil(call("tools/call", ["name": "list_meetings"])["error"])
        prefs.mcpEnabled = true; try lib.savePreferences(prefs)
        XCTAssertNotNil(call("tools/list")["result"])
    }
    func testMCPPreferencesPreserveSavedAccessChoice() throws {
        let lib = try temporaryLibrary(); defer { try? FileManager.default.removeItem(at: lib.root) }
        XCTAssertTrue(try lib.preferences().mcpEnabled)
        var prefs = Preferences(); prefs.mcpEnabled = false; try lib.savePreferences(prefs)
        let reopened = try MeetingLibrary(root: lib.root)
        XCTAssertFalse(try reopened.preferences().mcpEnabled)
        prefs.mcpEnabled = true; try reopened.savePreferences(prefs)
        XCTAssertTrue(try lib.preferences().mcpEnabled)
    }
}

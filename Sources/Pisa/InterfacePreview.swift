import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Opens the production views with disposable content. Never opens the user's library.
@MainActor
final class InterfacePreview: NSObject {
    private let state: AppState
    private let meeting: Meeting
    private let window: NSWindow

    private init(root: URL) throws {
        state = AppState(rootURL: root)
        try VoiceProfileTests.seed(state, count: 12)
        state.modelSetup.phase = .ready
        var fixture = Meeting(title: "Обсуждение планов и результатов проверки интерфейса", source: "Тестовое аудио")
        fixture.status = .ready
        fixture.duration = 180
        if let example = state.voiceProfiles.first?.examples?.first {
            let file = "preview-mic.caf"
            try FileManager.default.copyItem(at: root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file), to: state.library.audioURL(file))
            fixture.audioFiles = [file]
        }
        fixture.segments = (0..<20).map { index in
            var segment = TranscriptSegment(start: Double(index * 8), end: Double(index * 8 + 3), speaker: index.isMultiple(of: 2) ? "Анна" : "Борис", text: "На следующей встрече обсудим планы команды и результаты проверки. Посмотрим, как читается длинный текст, где переносятся строки и достаточно ли расстояния между ними. После обсуждения сохраним решения и вернёмся к открытым вопросам.")
            segment.embedding = index.isMultiple(of: 2) ? [1, 0] : [0, 1]
            return segment
        }
        if CommandLine.arguments.contains("--unidentified-speakers-preview") {
            fixture.segments[1].speaker = TranscriptSegment.unidentifiedSpeaker
            var unidentifiedOnly = fixture
            unidentifiedOnly.id = UUID()
            unidentifiedOnly.title = "Встреча без различимых голосов"
            unidentifiedOnly.segments = [fixture.segments[1]]
            state.update(unidentifiedOnly)
        }
        if CommandLine.arguments.contains("--audio-saved-preview") {
            fixture.status = .recorded
            fixture.segments = []
            let mic = "waveform-mic.caf", remote = "waveform-remote.caf"
            try Self.writeAudio(to: state.library.audioURL(mic), duration: 42, frequency: 180)
            try Self.writeAudio(to: state.library.audioURL(remote), duration: 34, frequency: 260)
            fixture.audioFiles = [mic, remote]
            fixture.audioOffsets = [remote: 5]
            fixture.duration = 42
        }
        let recordingPreview = CommandLine.arguments.contains("--recording-transcription-preview")
        let interruptedPreview = CommandLine.arguments.contains("--interrupted-transcription-preview")
        if interruptedPreview {
            let file = "interrupted-preview-mic.caf"
            try Self.writeAudio(to: state.library.audioURL(file), duration: 60, frequency: 180)
            fixture.title = "Встреча с черновиком расшифровки"
            fixture.duration = 60
            fixture.audioFiles = [file]
            fixture.status = .failed
            fixture.error = "Обработка остановлена. Аудио сохранено."
            fixture.liveCommittedUntil = 12
            fixture.segments = Array(fixture.segments.prefix(2))
        } else if recordingPreview {
            fixture.status = .failed
            fixture.liveCommittedUntil = 160
        } else if CommandLine.arguments.contains("--processing-preview") {
            fixture.status = .processing
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--progress-preview=") }) {
                fixture.segments = []
            }
        }
        if CommandLine.arguments.contains("--storage-preview") {
            var older = fixture
            older.id = UUID()
            older.date = Date.now.addingTimeInterval(-20 * 86_400)
            older.title = "Старая встреча с расшифровкой"
            let file = "old-preview-mic.caf"
            try Self.writeAudio(to: state.library.audioURL(file), duration: 30, frequency: 180)
            older.audioFiles = [file]
            state.update(older)
            fixture.date = Date.now.addingTimeInterval(-10 * 86_400)
        }
        if CommandLine.arguments.contains("--library-search-stress-preview") {
            for index in 0..<160 {
                var sample = Meeting(title: "Тестовая встреча \(index + 1)", source: "Тестовое аудио")
                sample.status = .ready
                let speaker = index == 159 ? "Уникальный участник" : "Анна"
                for segment in 0..<200 {
                    let text = index == 159 && segment == 199
                        ? "Ключевая фраза для проверки поиска"
                        : "Обсудили планы команды, результаты и следующие шаги. Проверили детали проекта и договорились продолжить работу."
                    let start = Double(segment * 4)
                    sample.segments.append(TranscriptSegment(start: start, end: start + 3, speaker: speaker, text: text))
                }
                state.update(sample)
            }
        }
        if CommandLine.arguments.contains("--trash-preview") { fixture.deletedAt = Date() }
        meeting = fixture
        state.update(fixture)
        if fixture.deletedAt != nil { state.openFolder(trash: true) }
        state.select(fixture.id)
        if interruptedPreview {
            try Self.prepareModelPath(for: state)
            var batch = fixture
            batch.id = UUID()
            batch.title = "Остановленная обработка аудиофайла"
            batch.segments = []
            batch.liveCommittedUntil = nil
            batch.interruptedBatchProgress = 0.36
            state.update(batch)

            var repeated = batch
            repeated.id = UUID()
            repeated.title = "Остановленная повторная расшифровка"
            repeated.segments = fixture.segments
            state.update(repeated)
            if CommandLine.arguments.contains("--interrupted-reprocessing-preview") { state.select(repeated.id) }

            var earlier = batch
            earlier.id = UUID()
            earlier.title = "Остановка без сохранённого прогресса"
            earlier.interruptedBatchProgress = nil
            state.update(earlier)
        } else if recordingPreview {
            try Self.prepareModelPath(for: state)
            var saved = Meeting(title: "Сохранённое аудио", source: state.source)
            saved.audioFiles = fixture.audioFiles
            saved.duration = fixture.duration
            state.update(saved)
            let current = Meeting(title: "Текущая запись", source: state.source)
            state.update(current)
            state.beginRecordingSession(current, automatic: false)
        } else if CommandLine.arguments.contains("--processing-preview") {
            state.processingID = fixture.id
            if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--progress-preview=") }),
               let fraction = Double(argument.dropFirst("--progress-preview=".count)) {
                state.phase = "Загружаю модель в память"
                state.progress = fraction
            } else {
                state.liveStatus = "Завершаю расшифровку"
            }
        }
        if CommandLine.arguments.contains("--queue-preview") {
            state.processingID = UUID()
            state.enqueue(fixture.id, reprocess: true)
        }
        if CommandLine.arguments.contains("--sidebar-date-preview") {
            try Self.seedSidebarDates(state)
            state.select(fixture.id)
        }
        state.preferences.vocabulary = Array(repeating: "2ГИС, Бронегис, Геопэй, названия проектов для проверки длинного словаря", count: 18).joined(separator: "\n")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Pisa · Проверка интерфейса"
        window.minSize = NSSize(width: 980, height: 660)
        let hosting = NSHostingView(rootView: InterfacePreviewRoot(state: state, setup: state.modelSetup)
            .preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.appTextScale, CommandLine.arguments.contains("--large-text-preview") ? 1.2 :
                CommandLine.arguments.contains("--medium-text-preview") ? 1.1 :
                CommandLine.arguments.contains("--small-text-preview") ? 0.8 : 1))
        // The review window owns its size, as SwiftUI's Window does in the app.
        // Content switches must not resize it to a view's unconstrained ideal size.
        hosting.sizingOptions = []
        window.contentView = hosting
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Pisa", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Завершить просмотр", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let reviewItem = NSMenuItem(title: "Просмотр", action: nil, keyEquivalent: "")
        let reviewMenu = NSMenu()
        for (index, title) in ["Главный экран", "Расшифровка", "Настройки", "Пустой список голосов", "Список голосов", "Первая настройка", "Модели готовы", "Проверка моделей", "Загрузка моделей", "Ошибка загрузки", "Окно 1200 × 800", "Окно 980 × 660"].enumerated() {
            let item = reviewMenu.addItem(withTitle: title, action: #selector(show(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        reviewItem.submenu = reviewMenu
        menu.addItem(reviewItem)
        NSApp.mainMenu = menu
    }

    private static func seedSidebarDates(_ state: AppState) throws {
        let calendar = Calendar.current
        let now = Date()
        let olderDay = calendar.date(byAdding: .day, value: -400, to: now) ?? now
        let older = calendar.date(bySettingHour: 12, minute: 7, second: 0, of: olderDay) ?? olderDay
        let folder = state.saveFolder("Документы и рабочие созвоны")

        func add(_ title: String, date: Date, duration: Double = 181, inFolder: Bool = false,
                 status: MeetingStatus = .recorded, automatic: Bool = false) -> Meeting {
            var meeting = Meeting(title: title, source: automatic ? "Аудиофайл" : "Тестовое аудио")
            meeting.date = date
            meeting.duration = duration
            meeting.folderID = inFolder ? folder : nil
            meeting.status = status
            if automatic { meeting.automaticTitle = title }
            state.update(meeting)
            return meeting
        }
        _ = add("Вчерашняя встреча", date: calendar.date(byAdding: .day, value: -1, to: now) ?? now, inFolder: true)
        _ = add("Встреча на неделе", date: calendar.date(byAdding: .day, value: -2, to: now) ?? now)
        _ = add("Встреча старше года", date: older)
        _ = add("Тестовая запись", date: older, duration: 3_670, inFolder: true, automatic: true)
        let processing = add("Расшифровывается", date: older, duration: 3_670, inFolder: true, status: .processing)
        let queued = add("В очереди", date: older, duration: 3_670, inFolder: true)
        try prepareModelPath(for: state)
        state.processingID = processing.id
        state.enqueue(queued.id)
        let recording = add("Текущая запись", date: now, inFolder: true)
        state.beginRecordingSession(recording, automatic: false)
    }

    private static func writeAudio(to url: URL, duration: Int, frequency: Double) throws {
        let rate = 16_000
        let frames = rate * duration
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { throw PisaError.message("Не удалось подготовить тестовое аудио") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let time = Double(frame) / Double(rate)
            let phrase = max(0, sin(time * 1.8 + frequency))
            let syllable = pow(sin(time * (8 + frequency / 100)), 4)
            samples[frame] = Float(0.04 * phrase * syllable * sin(time * frequency * 2 * .pi))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @objc private func show(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: state.select(nil)
        case 1: state.select(meeting.id)
        case 2: state.showingSettings = true
        case 3: state.voiceProfiles = []; state.showingSettings = true
        case 4:
            state.voiceProfiles = (try? state.library.voices()) ?? []
            state.showingSettings = true
        case 10, 11:
            window.setContentSize(sender.tag == 10 ? NSSize(width: 1200, height: 800) : NSSize(width: 980, height: 660))
            window.center()
        default:
            let setup = state.modelSetup
            setup.phase = sender.tag == 6 ? .ready : sender.tag == 7 ? .checking : sender.tag == 8 ? .downloading : sender.tag == 9 ? .failed : .available
            setup.error = sender.tag == 9 ? "Не удалось загрузить модель. Проверьте подключение к интернету и повторите попытку. Уже загруженные файлы сохранены." : nil
            setup.presented = true
        }
    }

    static func testTrashActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Trash-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        var deleted = Meeting(title: "Удалённая", source: "Аудио")
        deleted.deletedAt = Date()
        let active = Meeting(title: "Сохранённая", source: "Аудио")
        state.update(deleted); state.update(active)
        state.openFolder(trash: true); state.select(deleted.id)
        let items = MeetingActionSet(state: state, meeting: deleted).contextMenuItems
        guard items.map(\.title) == ["Восстановить", "Удалить"], items.allSatisfy(\.isEnabled) else {
            throw PisaError.message("Неверное меню удалённой записи")
        }
        state.deletePermanently(active)
        guard state.meetings.contains(where: { $0.id == active.id }) else { throw PisaError.message("Удалена запись вне корзины") }
        state.deletePermanently(deleted)
        guard !state.meetings.contains(where: { $0.id == deleted.id }), state.selection != deleted.id else {
            throw PisaError.message("Удалённая запись осталась в библиотеке: \(state.message ?? "нет ошибки"), записей: \(state.meetings.count), выбрана: \(state.selection == deleted.id)")
        }
        guard (try? state.library.read(deleted.id)) == nil else { throw PisaError.message("Запись осталась на диске") }
    }

    static func testQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Queue-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        state.modelSetup.phase = .ready
        let active = UUID()
        let first = Meeting(title: "Первая", source: "Аудио")
        let second = Meeting(title: "Вторая", source: "Аудио")
        state.update(first); state.update(second); state.processingID = active
        state.enqueue(first.id, reprocess: true); state.enqueue(second.id)
        guard state.isQueued(first.id), state.isQueued(second.id) else { throw PisaError.message("Записи не добавлены в очередь") }
        state.rename(first, to: "Название в очереди")
        guard try state.library.read(first.id).title == "Название в очереди" else { throw PisaError.message("Не удалось переименовать запись в очереди") }
        var processing = Meeting(title: "Исходное название", source: "Аудио")
        processing.status = .processing
        processing.segments = [.init(start: 0, end: 1, speaker: "Я", text: "Привет")]
        state.update(processing); state.processingID = processing.id
        state.rename(processing, to: "Название во время расшифровки")
        guard let folderID = state.saveFolder("Работа"),
              let moveItem = MeetingActionSet(state: state, meeting: processing).contextMenuItems.first(where: \.hasSubmenu),
              moveItem.isEnabled, let submenu = moveItem.submenu,
              let destination = submenu.item(withTitle: "Работа") else {
            throw PisaError.message("Перемещение из контекстного меню недоступно во время расшифровки")
        }
        _ = NSApplication.shared
        submenu.performActionForItem(at: submenu.index(of: destination))
        guard try state.library.read(processing.id).folderID == folderID else {
            throw PisaError.message("Папка записи не сохранилась во время расшифровки")
        }
        state.moveToNewFolder(processing, name: "Планы", symbol: "folder")
        guard let newFolder = state.folders.first(where: { $0.name == "Планы" }),
              try state.library.read(processing.id).folderID == newFolder.id else {
            throw PisaError.message("Не удалось переместить запись в новую папку во время расшифровки")
        }
        var completed = try state.library.read(processing.id)
        guard completed.title == "Название во время расшифровки", completed.segments == processing.segments,
              completed.status == .processing, state.processingID == processing.id else {
            throw PisaError.message("Перемещение изменило название, текст или состояние расшифровки")
        }
        completed.status = .ready
        _ = completed.applyGeneratedTitle("Автоматическое название")
        try state.library.save(completed)
        let finished = try state.library.read(processing.id)
        guard finished.title == "Название во время расшифровки", finished.folderID == newFolder.id else {
            throw PisaError.message("Название или папка изменились после завершения расшифровки")
        }
        state.processingID = active
        state.cancelQueued(first.id)
        guard !state.isQueued(first.id), state.isQueued(second.id), state.processingID == active,
              try state.library.read(first.id).title == "Название в очереди" else { throw PisaError.message("Отмена изменила запись или другую задачу") }
        state.enqueue(first.id)
        guard state.isQueued(first.id) else { throw PisaError.message("Запись нельзя снова добавить в очередь") }
        state.cancelQueued(first.id); state.cancelQueued(second.id); state.cancelQueued(active)
        guard state.processingID == active else { throw PisaError.message("Отмена очереди остановила обработку") }
    }

    static func testTrashQueuedRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Queued-Trash-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        state.modelSetup.phase = .ready

        var recording = Meeting(title: "Короткая запись", source: "Аудио")
        recording.duration = 3
        recording.audioFiles = ["short-mic.caf"]
        try writeAudio(to: state.library.audioURL("short-mic.caf"), duration: 3, frequency: 180)
        var processing = Meeting(title: "Текущая обработка", source: "Аудио")
        processing.status = .processing
        var finalized = Meeting(title: "Готовая расшифровка", source: "Аудио")
        finalized.status = .ready
        for meeting in [recording, processing, finalized] { state.update(meeting) }
        state.processingID = processing.id
        state.enqueue(recording.id)
        state.enqueue(finalized.id, reprocess: true)
        guard state.isQueued(recording.id), state.isQueued(finalized.id) else {
            throw PisaError.message("Тестовые записи не добавлены в очередь")
        }

        _ = NSApplication.shared
        let title = "В корзину"
        let menu = nativeActionMenu(items: MeetingActionSet(state: state, meeting: recording).contextMenuItems)
        guard let trash = menu.item(withTitle: title), trash.isEnabled else {
            throw PisaError.message("Команда «В корзину» недоступна для ожидающей записи")
        }
        for busy in [processing, finalized] {
            let items = MeetingActionSet(state: state, meeting: busy).contextMenuItems
            guard items.first(where: { $0.title == title })?.isEnabled == false else {
                throw PisaError.message("Команда «В корзину» доступна для занятой записи с готовой или текущей расшифровкой")
            }
        }
        menu.performActionForItem(at: menu.index(of: trash))
        let trashed = try state.library.read(recording.id)
        guard trashed.deletedAt != nil, !state.isQueued(recording.id),
              !state.filtered.contains(where: { $0.id == recording.id }), state.hasAudio(trashed),
              state.isQueued(finalized.id), state.processingID == processing.id else {
            throw PisaError.message("Перенос в корзину изменил аудио или другие задачи либо оставил запись в очереди")
        }
        state.enqueue(recording.id)
        guard !state.isQueued(recording.id) else {
            throw PisaError.message("Запись из корзины снова попала в очередь")
        }
        state.openFolder(trash: true)
        guard state.filtered.map(\.id) == [recording.id] else {
            throw PisaError.message("Запись не появилась в корзине")
        }
        state.trash(trashed, restore: true)
        let restored = try state.library.read(recording.id)
        guard restored.deletedAt == nil, !state.isQueued(recording.id), state.hasAudio(restored) else {
            throw PisaError.message("Не удалось восстановить запись с аудио из корзины")
        }
    }

    static func testQueuedTurboTranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Queued-Turbo-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        try prepareModelPath(for: state)
        let blocker = Meeting(title: "Текущая обработка", source: state.source)
        let normal = Meeting(title: "Обычная обработка", source: state.source)
        let requeued = Meeting(title: "Повторно в очереди", source: state.source)
        let batch = Meeting(title: "Новая расшифровка", source: state.source)
        var resume = Meeting(title: "Продолжение черновика", source: state.source)
        resume.status = .failed
        resume.liveCommittedUntil = 3
        for meeting in [blocker, normal, requeued, batch, resume] { state.update(meeting) }
        state.enqueue(blocker.id)
        state.enqueue(normal.id)
        state.enqueue(requeued.id)
        state.enqueue(batch.id, reprocess: true)
        state.enqueue(resume.id)

        guard !state.canUseTurboTranscription(batch.id) else {
            throw PisaError.message("Турбо-режим доступен в очереди при тихой обработке")
        }
        state.preferences.quietProcessing = false
        guard state.canUseTurboTranscription(batch.id), state.canUseTurboTranscription(resume.id) else {
            throw PisaError.message("Турбо-режим недоступен для записей в очереди")
        }
        state.setTurboTranscription(true, for: normal.id)
        state.preferences.quietProcessing = true
        state.preferences.quietProcessing = false
        state.setTurboTranscription(true, for: requeued.id)
        state.cancelQueued(requeued.id)
        state.enqueue(requeued.id)
        state.setTurboTranscription(true, for: batch.id)
        state.setTurboTranscription(true, for: resume.id)
        guard state.processingID == blocker.id, !state.turboTranscriptionEnabled else {
            throw PisaError.message("Турбо-режим в очереди изменил текущую обработку")
        }

        var turboStarts: [UUID] = []
        let observation = state.$turboTranscriptionEnabled.sink { enabled in
            if enabled, let id = state.processingID { turboStarts.append(id) }
        }
        defer { observation.cancel() }
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)
        guard turboStarts == [batch.id, resume.id], !state.turboTranscriptionEnabled,
              [normal, requeued, batch, resume].allSatisfy({ !state.isQueued($0.id) }) else {
            throw PisaError.message("Очередь запустила обработку с неверным турбо-режимом")
        }
    }

    static func testQueuedResumeWithProtectedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Protected-Resume-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        try prepareModelPath(for: state)
        var resume = Meeting(title: "Продолжение черновика", source: state.source)
        resume.status = .failed
        resume.audioFiles = ["resume-mic.caf"]
        resume.duration = 3
        resume.liveCommittedUntil = 3
        resume.segments = [.init(start: 0, end: 2, speaker: "Я", text: "Сохранённая реплика")]
        resume.segments[0].audioFile = resume.audioFiles[0]
        var blocker = resume
        blocker.id = UUID()
        blocker.title = "Первая запись"
        var next = resume
        next.id = UUID()
        next.title = "Следующая запись"
        try writeAudio(to: state.library.audioURL(resume.audioFiles[0]), duration: 3, frequency: 180)
        for meeting in [blocker, resume, next] { state.update(meeting) }

        let metadata = state.library.meetingsDirectory.appendingPathComponent(resume.id.uuidString + ".json")
        let files = FileManager.default
        var accessWasDenied = false
        let observation = state.$processingID.sink { id in
            guard id == resume.id else { return }
            // Revoke reads after runNext has written the processing status.
            try? files.setAttributes([.posixPermissions: 0], ofItemAtPath: metadata.path)
            accessWasDenied = (try? state.library.read(resume.id)) == nil
        }
        defer { observation.cancel() }
        state.enqueue(blocker.id)
        state.enqueue(resume.id)
        state.enqueue(next.id)
        for _ in 0..<200 {
            if accessWasDenied && (state.liveStatus == "Жду доступа к записи" || state.processingID != resume.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard accessWasDenied, state.processingID == resume.id, state.isQueued(next.id),
              state.meetings.first(where: { $0.id == blocker.id })?.status == .ready,
              state.liveStatus == "Жду доступа к записи" else {
            throw PisaError.message("Продолжение черновика потеряло своё место в очереди при отказе чтения")
        }

        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        for _ in 0..<500 {
            if state.processingID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try state.library.read(resume.id)
        guard state.processingID == nil, !state.isQueued(next.id), state.meetings.first(where: { $0.id == next.id })?.status == .ready,
              completed.status == .ready, completed.liveCommittedUntil == nil, completed.segments == resume.segments,
              state.canReviewTerms(completed) else {
            throw PisaError.message("После восстановления доступа черновик или очередь не завершились")
        }
    }

    static func testTranscriptionDuringRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Recording-Queue-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        try prepareModelPath(for: state)
        var saved = Meeting(title: "Предыдущая встреча", source: state.source)
        saved.liveCommittedUntil = 3
        saved.audioFiles = ["saved-mic.caf"]
        saved.segments = [.init(start: 0, end: 2, speaker: "Я", text: "Сохранённая реплика")]
        try writeAudio(to: state.library.audioURL(saved.audioFiles[0]), duration: 6, frequency: 180)
        state.update(saved)
        state.enqueue(saved.id)
        guard state.processingID == saved.id else { throw PisaError.message("Не запустилась расшифровка предыдущей встречи") }

        guard !state.canUseTurboTranscription(saved.id) else {
            throw PisaError.message("Турбо-режим доступен при включённой тихой обработке")
        }
        state.preferences.quietProcessing = false
        state.setTurboTranscription(true, for: saved.id)
        guard state.turboTranscriptionEnabled else {
            throw PisaError.message("Турбо-режим не включился для сохранённого аудио")
        }

        let current = Meeting(title: "Текущая встреча", source: state.source)
        state.update(current)
        state.beginRecordingSession(current, automatic: false)
        state.setTurboTranscription(false, for: current.id)
        guard state.canUseTurboTranscription(saved.id), state.turboTranscriptionEnabled else {
            throw PisaError.message("Текущая запись повлияла на турбо-режим предыдущей встречи")
        }
        state.preferences.quietProcessing = true
        guard !state.canUseTurboTranscription(saved.id), !state.turboTranscriptionEnabled else {
            throw PisaError.message("Тихая обработка не отключила турбо-режим")
        }
        state.preferences.quietProcessing = false
        guard !state.turboTranscriptionEnabled else {
            throw PisaError.message("Турбо-режим включился без запроса")
        }
        state.setTurboTranscription(true, for: saved.id)
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)
        guard state.recordingMeetingID == current.id else { throw PisaError.message("Отмена расшифровки остановила запись") }

        state.enqueue(saved.id)
        let resumed = try state.library.read(saved.id)
        guard state.processingID == saved.id, resumed.liveCommittedUntil == 3, resumed.segments == saved.segments else {
            throw PisaError.message("Не удалось продолжить предыдущую расшифровку с сохранённого места во время записи")
        }
        guard state.canUseTurboTranscription(saved.id), !state.turboTranscriptionEnabled else {
            throw PisaError.message("Турбо-режим сохранился после остановки расшифровки")
        }
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)

        state.enqueue(current.id)
        let live = try state.library.read(current.id)
        guard state.recordingMeetingID == current.id, state.processingID == current.id,
              live.status == .processing, live.liveCommittedUntil == 0 else {
            throw PisaError.message("Текущая запись не запустила черновик с начала записанного аудио")
        }
        state.setTurboTranscription(true, for: current.id)
        guard !state.canUseTurboTranscription(current.id), !state.turboTranscriptionEnabled else {
            throw PisaError.message("Турбо-режим доступен при расшифровке текущей записи")
        }
        state.recording = false
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)
    }

    private static func prepareModelPath(for state: AppState) throws {
        // The test covers task selection before inference. A live task waits for capture boundaries.
        let model = state.library.root.appendingPathComponent("Models/Qwen3-ASR")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
        state.modelSetup.phase = .ready
    }

    private static func waitForTranscriptionToStop(_ state: AppState) async throws {
        for _ in 0..<200 {
            if state.processingID == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PisaError.message("Обработка не остановилась")
    }

    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Interface-Preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try InterfacePreview(root: root)
        preview.window.center(); preview.window.makeKeyAndOrderFront(nil)
        preview.window.makeFirstResponder(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(preview) { app.run() }
    }
}

private struct InterfacePreviewRoot: View {
    @ObservedObject var state: AppState
    @ObservedObject var setup: ModelSetup
    var body: some View {
        MainView().environmentObject(state)
            .sheet(isPresented: $state.showingSettings) { SettingsView().environmentObject(state) }
            .sheet(isPresented: $setup.presented) { ModelSetupView(setup: setup, onReady: {}) }
    }
}

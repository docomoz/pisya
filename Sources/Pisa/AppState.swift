import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import OSLog

@MainActor
final class AppState: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: UUID?
    @Published var folders: [MeetingFolder] = []
    @Published var folderFilter: UUID?
    @Published var showingTrash = false
    @Published var unfiledOnly = false
    @Published var renameTarget: Meeting?
    @Published var newFolderMeeting: Meeting?
    @Published var voiceMeeting: Meeting?
    @Published var reprocessTarget: Meeting?
    @Published var permanentDeleteTarget: Meeting?
    private var termReplacementUndo: [UUID: (before: [UUID: String], after: [UUID: String])] = [:]
    private let searchIndex = LibrarySearchIndex()
    private var searchGeneration = 0
    private var searchAnalyticsTask: Task<Void, Never>?
    private var searchReported = false
    private var searchMatches: Set<UUID> = []
    private var selectAfterSearch = false
    @Published private(set) var searchInProgress = false
    @Published var preferences = Preferences() {
        didSet {
            if preferences.usesQuietProcessing != oldValue.usesQuietProcessing {
                setTurboEnabled(false)
                for index in pending.indices where pending[index].turbo {
                    pending[index].turbo = false
                }
            }
        }
    }
    @Published var search = "" {
        didSet {
            if search != oldValue {
                refreshSearch()
                scheduleSearchAnalytics()
            }
        }
    }
    @Published var recording = false
    @Published var starting = false
    @Published var recordingStarted: Date?
    @Published var processingID: UUID? {
        didSet {
            if processingID != oldValue { setTurboEnabled(false) }
        }
    }
    @Published private(set) var turboTranscriptionEnabled = false
    @Published var progress: Double = 0
    @Published var phase = ""
    @Published var permissionIssue: CapturePermission?
    @Published var message: String?
    @Published var showingSettings = false
    @Published private(set) var exportFolderUnavailable = false
    @Published var callActive = false
    @Published var livePaused = false
    @Published var liveStatus = ""
    @Published private(set) var liveAudioDuration: Double?
    @Published private(set) var isReprocessing = false
    let source = "Системный звук"
    @Published var demo = false
    @Published var voiceProfiles: [VoiceProfile] = []
    private var voiceAssignmentRequests: [UUID: UUID] = [:]
    let library: MeetingLibrary
    struct SourceReveal: Equatable {
        let meetingID: UUID
        let segmentID: UUID
        let requestID = UUID()
    }
    struct SourceNotice: Identifiable {
        let id = UUID()
        let message: String
    }
    @Published var sourceNotice: SourceNotice?
    private var sourceRequestID = UUID()
    @Published var sourceReveal: SourceReveal?
    @Published var playingSegmentID: UUID?
    let savedAudioPlayer = AVPlayer()
    private var player: AVAudioPlayer?
    private var playbackEnd: Double = 0
    private var playbackTimer: Timer?
    private var audioExports: Set<UUID> = []
    private var audioArchiveTask: Task<Void, Never>?
    private var audioArchiveRetryAfter: [UUID: Date] = [:]
    private static let audioArchiveLog = Logger(subsystem: "com.docomoz.pisa", category: "audio-archive")
    private let capture = AudioCapture()
    let recordingMonitor = RecordingMonitor()
    private var meterTask: Task<Void, Never>?
    private var offsetTask: Task<Void, Never>?
    private let transcriber = Transcriber()
    private static let transcriptionLog = Logger(subsystem: "com.docomoz.pisa", category: "transcription")
    private let transcriptionPerformance = TranscriptionPerformance(mode: .quiet)
    private var turboActivity: NSObjectProtocol?
    private let titleModel = MeetingTitleModel()
    private var processingTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveStopped = false
    private var timer: Timer?
    private var detector = CallDetector()
    private var activeMeeting: Meeting?
    private var recordingTitleDraft: String?
    var recordingMeetingID: UUID? { recording ? activeMeeting?.id : nil }
    var savingMeetingID: UUID? { recording ? nil : activeMeeting?.id }
    var canStartLiveTranscription: Bool { !demo && recordingMeetingID != nil && processingID == nil && modelReady }
    private var automaticallyStarted = false
    private var recordingStartedAutomatically = false
    private struct QueuedTranscription {
        let id: UUID
        let reprocess: Bool
        var turbo = false
    }
    @Published private var pending: [QueuedTranscription] = []
    var selected: Meeting? { meetings.first { $0.id == selection } }
    var filtered: [Meeting] {
        meetings.filter { m in
            (showingTrash ? m.deletedAt != nil : m.deletedAt == nil) &&
            (showingTrash || (folderFilter == nil || m.folderID == folderFilter) && (!unfiledOnly || m.folderID == nil)) &&
            (search.isEmpty || searchMatches.contains(m.id))
        }
    }
    private func scheduleSearchAnalytics() {
        searchAnalyticsTask?.cancel()
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchReported = false
            return
        }
        guard !searchReported, !demo else { return }
        searchAnalyticsTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, !self.searchReported, !self.demo else { return }
            self.searchReported = true
            Analytics.feature(.librarySearched)
        }
    }
    private func refreshSearch() {
        searchGeneration += 1
        let generation = searchGeneration
        let query = search
        guard !query.isEmpty else {
            searchIndex.cancelSearch()
            searchMatches = []
            searchInProgress = false
            if selectAfterSearch {
                selectAfterSearch = false
                select(filtered.first?.id)
            }
            return
        }
        searchInProgress = true
        searchIndex.search(query) { [weak self] matches in
            guard let self, self.searchGeneration == generation, self.search == query else { return }
            self.searchMatches = matches
            self.searchInProgress = false
            if self.selectAfterSearch {
                self.selectAfterSearch = false
                self.select(self.filtered.first?.id)
            }
        }
    }
    private func replaceSearchIndex() {
        searchIndex.replace(meetings)
        if !search.isEmpty { refreshSearch() }
    }
    private func selectFirstMatching() {
        select(filtered.first?.id)
        if searchInProgress { selectAfterSearch = true }
    }
    func openSource(_ url: URL) {
        sourceRequestID = UUID()
        let requestID = sourceRequestID
        let wasShowingSettings = showingSettings
        showingSettings = false; sourceNotice = nil
        func notice(_ text: String) {
            let value = SourceNotice(message: text)
            if wasShowingSettings {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.sourceRequestID == requestID else { return }
                    self.sourceNotice = value
                }
            } else { sourceNotice = value }
        }
        guard let link = TranscriptLink(url: url) else { stopPlayback(); notice("Некорректная ссылка на фрагмент"); return }
        guard let meeting = try? library.read(link.meetingID), meeting.id == link.meetingID, meeting.deletedAt == nil else {
            stopPlayback(); notice("Встреча недоступна или находится в корзине"); return
        }
        guard let result = link.resolve(in: meeting) else { stopPlayback(); notice("Фрагмент больше недоступен"); return }
        if demo {
            guard let actualMeetings = try? library.all(includeDeleted: true) else {
                notice("Не удалось открыть библиотеку встреч"); return
            }
            demo = false; meetings = actualMeetings
            replaceSearchIndex()
        }
        upsert(meeting)
        showingTrash = false; folderFilter = nil; unfiledOnly = false; search = ""
        if selection != meeting.id { select(meeting.id) }
        sourceReveal = SourceReveal(meetingID: meeting.id, segmentID: result.segment.id)
        var notices: [String] = []
        if result.isApproximate {
            stopPlayback()
            notices.append("Исходная реплика изменилась или удалена. Показан ближайший фрагмент по времени.")
        }
        if recording || savingMeetingID == meeting.id {
            stopPlayback()
            notices.append("Аудио сейчас недоступно во время записи или сохранения")
        } else if !result.isApproximate && !startPlayback(result.segment, in: meeting, toggle: false) {
            notices.append("Аудио этого фрагмента недоступно, но текст сохранён")
        }
        if !notices.isEmpty { notice(notices.joined(separator: "\n\n")) }
    }
    func select(_ id: UUID?) { selectAfterSearch = false; stopPlayback(); selection = id }
    func openFolder(_ id: UUID? = nil, trash: Bool = false, unfiled: Bool = false) {
        folderFilter = id; showingTrash = trash; unfiledOnly = unfiled
        selectFirstMatching()
    }
    func canModify(_ m: Meeting, allowQueued: Bool = false) -> Bool {
        !demo && activeMeeting?.id != m.id && processingID != m.id && (allowQueued || !isQueued(m.id))
    }
    func canTrash(_ m: Meeting) -> Bool {
        canModify(m, allowQueued: m.deletedAt == nil && m.status != .ready)
    }
    func canRename(_ m: Meeting) -> Bool { !demo }
    func canMove(_ m: Meeting) -> Bool {
        !demo && m.deletedAt == nil && activeMeeting?.id != m.id && !isQueued(m.id)
            && (processingID != m.id || !isReprocessing)
    }
    func isQueued(_ id: UUID) -> Bool { pending.contains { $0.id == id } }
    func stageRecordingTitle(_ title: String, for meeting: Meeting) {
        guard recordingMeetingID == meeting.id else { return }
        recordingTitleDraft = title == meeting.headingTitle ? nil : title
    }
    func rename(_ m: Meeting, to title: String, resetIfEmpty: Bool = false) {
        guard canRename(m), var latest = meetings.first(where: { $0.id == m.id }) else { return }
        let isRecording = recordingMeetingID == m.id
        if isRecording { recordingTitleDraft = nil }
        guard latest.rename(to: title, resetIfEmpty: isRecording && resetIfEmpty) else { return }
        if isRecording {
            do { try library.save(latest); upsert(latest) }
            catch { message = error.localizedDescription }
        } else {
            update(latest)
        }
    }
    func move(_ m: Meeting, to folder: UUID?) {
        guard var latest = meetings.first(where: { $0.id == m.id }), canMove(latest) else { return }
        let changed = latest.folderID != folder
        latest.folderID = folder
        do {
            try library.save(latest)
            upsert(latest)
            if changed { Analytics.feature(.meetingMoved) }
            if !filtered.contains(where: { $0.id == selection }) { selectFirstMatching() }
        } catch { message = error.localizedDescription }
    }
    func trash(_ m: Meeting, restore: Bool = false) {
        guard var latest = meetings.first(where: { $0.id == m.id }), canTrash(latest),
              restore == (latest.deletedAt != nil) else { return }
        stopPlayback(); latest.deletedAt = restore ? nil : Date()
        do {
            try library.save(latest)
            if !restore { cancelQueued(latest.id) }
            upsert(latest)
            selectFirstMatching()
        } catch {
            message = error.localizedDescription
            return
        }
        if !restore {
            do {
                try withConfiguredExportFolder { folder in
                    _ = try MarkdownExporter.trashExport(for: latest, in: folder)
                }
            } catch {
                message = "Запись в корзине Pisa. Не удалось переместить Markdown в корзину: \(error.localizedDescription)"
            }
        }
    }
    var canEmptyTrash: Bool {
        !demo && meetings.contains { $0.deletedAt != nil } && meetings.filter { $0.deletedAt != nil }.allSatisfy { canModify($0) }
    }
    func deletePermanently(_ meeting: Meeting) {
        guard let latest = meetings.first(where: { $0.id == meeting.id }),
              latest.deletedAt != nil, canModify(latest) else { return }
        stopPlayback()
        do {
            try library.purgeTrashed(latest.id)
            termReplacementUndo[latest.id] = nil
            meetings.removeAll { $0.id == latest.id }
            replaceSearchIndex()
            if selection == latest.id { selectFirstMatching() }
        } catch { message = error.localizedDescription }
    }
    func emptyTrash() {
        guard canEmptyTrash else { return }
        stopPlayback()
        do {
            for m in meetings where m.deletedAt != nil {
                try library.purgeTrashed(m.id)
                termReplacementUndo[m.id] = nil
            }
        } catch { message = error.localizedDescription }
        do {
            meetings = try library.all(includeDeleted: true)
            for index in meetings.indices {
                if meetings[index].refreshAutomaticTitle() {
                    do { try library.save(meetings[index]) }
                    catch { message = "Не удалось сохранить новое название: " + error.localizedDescription }
                }
            }
            replaceSearchIndex()
            selectFirstMatching()
        } catch { message = error.localizedDescription }
    }
    @discardableResult
    func saveFolder(_ name: String, id: UUID? = nil, symbol: String? = nil) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !demo else { return nil }
        var updated = folders
        let savedID: UUID
        let createsFolder = !updated.contains { $0.id == id }
        if let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index].name = name
            if let symbol { updated[index].symbol = symbol }
            savedID = updated[index].id
        } else {
            let folder = MeetingFolder(name: name, symbol: symbol)
            updated.append(folder)
            savedID = folder.id
        }
        do {
            try library.saveFolders(updated)
            folders = updated
            if createsFolder { Analytics.feature(.folderCreated) }
            return savedID
        } catch {
            message = error.localizedDescription
            return nil
        }
    }
    func moveToNewFolder(_ meeting: Meeting, name: String, symbol: String) {
        guard let latest = meetings.first(where: { $0.id == meeting.id }), canMove(latest) else { return }
        if let folderID = saveFolder(name, symbol: symbol) {
            move(latest, to: folderID)
        }
    }
    func reorderFolder(_ id: UUID, relativeTo targetID: UUID, after: Bool) {
        guard !demo, id != targetID,
              let source = folders.firstIndex(where: { $0.id == id }) else { return }
        var updated = folders
        let folder = updated.remove(at: source)
        guard let target = updated.firstIndex(where: { $0.id == targetID }) else { return }
        updated.insert(folder, at: after ? target + 1 : target)
        guard updated != folders else { return }
        do {
            try library.saveFolders(updated)
            folders = updated
        } catch {
            message = error.localizedDescription
        }
    }
    func removeFolder(_ folder: MeetingFolder) {
        guard !demo else { return }
        do {
            for var m in meetings where m.folderID == folder.id { m.folderID = nil; try library.save(m); upsert(m) }
            let updated = folders.filter { $0.id != folder.id }; try library.saveFolders(updated); folders = updated
            if folderFilter == folder.id { openFolder() }
        } catch { message = error.localizedDescription }
    }
    lazy var modelSetup = ModelSetup(root: library.root.appendingPathComponent("Models"), customModel: { [weak self] in self?.modelURL() }, usesCustomModel: { [weak self] in self?.preferences.modelBookmark != nil })
    private var modelSetupObservation: AnyCancellable?
    var modelReady: Bool { modelSetup.ready }
    func modelInstallationCompleted() {
        if !modelSetup.installedUsingCustom { preferences.modelBookmark = nil; preferences.modelDisplayPath = nil; savePreferences() }
    }
    var mcpPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pisa-mcp").path }
    init(rootURL: URL? = nil) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisa", isDirectory: true)
        do { library = try MeetingLibrary(root: root) } catch { fatalError("Не удалось открыть библиотеку: \(error.localizedDescription)") }
        do {
            preferences = try library.preferences()
            refreshExportFolderAccess()
            voiceProfiles = try library.voices()
            meetings = try library.all(includeDeleted: true)
            for index in meetings.indices {
                if meetings[index].refreshAutomaticTitle() {
                    do { try library.save(meetings[index]) }
                    catch { message = "Не удалось сохранить новое название: " + error.localizedDescription }
                }
            }
            folders = try library.folders()
            replaceSearchIndex()
            for index in meetings.indices where meetings[index].status == .processing {
                meetings[index].status = .failed
                meetings[index].error = "Обработка прервалась. Аудио сохранено — можно повторить"
                try library.save(meetings[index])
            }
            selection = filtered.first?.id
        } catch { message = error.localizedDescription }
        modelSetupObservation = modelSetup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        capture.onFailure = { [weak self] error in Task { @MainActor in
            self?.message = error
            if self?.recording == true { Analytics.recordingIssue(.interrupted); await self?.stopRecording() }
        } }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollCall() } }
        runAudioArchive()
    }
    func hasAudio(_ meeting: Meeting) -> Bool {
        meeting.audioFiles.contains { name in
            guard let url = try? library.audioURL(name), FileManager.default.fileExists(atPath: url.path), let file = try? AVAudioFile(forReading: url) else { return false }
            return file.length > 0
        }
    }
    func savePreferences() { do { try library.savePreferences(preferences) } catch { message = error.localizedDescription } }
    func setAutomatic(_ enabled: Bool) {
        let changed = preferences.automaticRecording != enabled
        preferences.automaticRecording = enabled; detector.reset()
        do { try library.savePreferences(preferences); if changed { Analytics.setting(.automaticRecording, enabled: enabled) } }
        catch { message = error.localizedDescription }
    }
    func setBackgroundTranscription(_ enabled: Bool) {
        let changed = preferences.usesBackgroundTranscription != enabled
        preferences.backgroundTranscription = enabled
        do { try library.savePreferences(preferences); if changed { Analytics.setting(.backgroundTranscription, enabled: enabled) } }
        catch { message = error.localizedDescription }
    }
    func saveMCPSetting() {
        do { try library.savePreferences(preferences); Analytics.setting(.mcp, enabled: preferences.mcpEnabled) }
        catch { message = error.localizedDescription }
    }
    func canUseTurboTranscription(_ id: UUID) -> Bool {
        guard !demo, !preferences.usesQuietProcessing, activeMeeting?.id != id else { return false }
        return isQueued(id) || (processingID == id && meetings.contains { $0.id == id && $0.status == .processing })
    }
    func isTurboTranscriptionEnabled(for id: UUID) -> Bool {
        if processingID == id { return turboTranscriptionEnabled }
        return pending.first(where: { $0.id == id })?.turbo ?? false
    }
    func setTurboTranscription(_ enabled: Bool, for id: UUID) {
        guard canUseTurboTranscription(id) else { return }
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending[index].turbo = enabled
        } else {
            setTurboEnabled(enabled)
        }
    }
    private func setTurboEnabled(_ enabled: Bool) {
        if enabled != turboTranscriptionEnabled {
            turboTranscriptionEnabled = enabled
            if enabled {
                turboActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                    reason: "Turbo transcription")
            } else if let activity = turboActivity {
                ProcessInfo.processInfo.endActivity(activity)
                turboActivity = nil
            }
        }
        let liveCapture = processingID != nil && processingID == activeMeeting?.id
        transcriptionPerformance.mode = liveCapture || preferences.usesQuietProcessing
            ? .quiet : enabled ? .turbo : .normal
    }
    func toggleLivePause() { livePaused.toggle(); liveStatus = livePaused ? "Расшифровка на паузе" : "Готовлю черновик" }
    private func pollCall() {
        if let player, player.isPlaying, player.currentTime >= playbackEnd { player.stop(); playingSegmentID = nil }
        if let player, !player.isPlaying { playingSegmentID = nil }
        runAudioArchive()
        guard preferences.automaticRecording, !demo, !modelSetup.presented, !modelSetup.busy else { return }
        Task {
            let active = await Task.detached(priority: .utility) { CallAudioProbe.isActive() }.value
            guard preferences.automaticRecording else { return }
            if callActive != active { callActive = active }
            handleCallActivity(active)
        }
    }
    private func handleCallActivity(_ active: Bool) {
        switch detector.update(active: active, now: Date()) {
        case .start:
            if recording { automaticallyStarted = true } // Arm stop only after a call actually appears.
            else if !starting { Task { await startRecording(automatic: true) } }
        case .stop: if automaticallyStarted && recording { Task { await stopRecording() } }
        case .none: break
        }
    }
    func startRecording(automatic: Bool = false) async {
        guard !recording, !starting, !demo else { return }
        guard !modelSetup.busy, !modelSetup.presented else { modelSetup.presented = true; return }
        stopPlayback()
        starting = true; defer { starting = false }
        let selectedSource = source
        var m = Meeting(title: "", source: selectedSource)
        m.title = m.defaultTitle; m.automaticTitle = m.title
        // Journal expected paths before capture, so interrupted sessions remain discoverable.
        m.audioArchive = .waitingForTranscription
        m.audioFiles = ["\(m.id.uuidString)-mic.caf", "\(m.id.uuidString)-remote.caf"]
        do {
            try await capture.prepare()
            try library.save(m)
            try await capture.start(folder: library.audioDirectory, id: m.id)
            beginRecordingSession(m, automatic: automatic)
            Analytics.recordingStarted(automatic: automatic)
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let sample = await self.capture.meterSnapshot()
                    guard !Task.isCancelled else { return }
                    self.recordingMonitor.update(microphone: sample.0, system: sample.1)
                    do { try await Task.sleep(nanoseconds: 33_333_333) } catch { return }
                }
            }
            let recordingID = m.id
            offsetTask = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let tracks = await self.capture.transcriptionBoundary(requireBoth: false)
                    guard !Task.isCancelled, self.recording, self.activeMeeting?.id == recordingID else { return }
                    if let tracks {
                        let offsets = Dictionary(uniqueKeysWithValues: tracks.map { ($0.url.lastPathComponent, $0.offset) })
                        if var latest = try? self.library.read(recordingID), latest.audioOffsets != offsets {
                            latest.audioOffsets = offsets
                            do { try self.library.save(latest); self.upsert(latest) }
                            catch { self.message = error.localizedDescription }
                        }
                    }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
            if preferences.usesBackgroundTranscription && canStartLiveTranscription { enqueue(m.id) }
        } catch {
            Analytics.recordingIssue(.start)
            m.status = .failed; m.error = error.localizedDescription
            if hasAudio(m) { try? library.save(m); upsert(m) }
            else { try? library.discardEmptyDraft(m) }
            if let permission = error as? CapturePermission { permissionIssue = permission }
            else { message = error.localizedDescription }
            detector.manuallyStopped()
        }
    }
    func beginRecordingSession(_ meeting: Meeting, automatic: Bool) {
        activeMeeting = meeting; recording = true; recordingStarted = Date()
        automaticallyStarted = automatic; recordingStartedAutomatically = automatic
        recordingMonitor.reset()
        showingTrash = false; folderFilter = nil; unfiledOnly = false
        upsert(meeting); selectAfterSearch = false; selection = meeting.id
    }
    func stopRecording(manual: Bool = false) async {
        guard recording, var m = activeMeeting else { return }
        // Stopping from the menu bar or call detector can leave the title field focused.
        if let title = recordingTitleDraft { rename(m, to: title) }
        meterTask?.cancel(); meterTask = nil
        offsetTask?.cancel(); offsetTask = nil
        recording = false; starting = true; defer { starting = false }
        if manual { detector.manuallyStopped() }
        automaticallyStarted = false
        do {
            let result = try await capture.stop()
            m = (try? library.read(m.id)) ?? m
            m.audioFiles = result.files; m.audioOffsets = result.offsets; m.duration = result.duration
            guard !result.files.isEmpty else { throw PisaError.message("Звук не получен. Проверьте разрешения и выбранное приложение") }
            try library.save(m); upsert(m)
            Analytics.recordingSaved(duration: m.duration, automatic: recordingStartedAutomatically)
            if let warning = result.warning { Analytics.recordingIssue(.partial); message = warning }
            if liveTask != nil && processingID == m.id {
                liveStopped = true
                livePaused = false
                liveStatus = "Завершаю расшифровку"
            }
            else if result.warning == nil && modelReady { enqueue(m.id) }
            else if !modelReady { message = "Запись сохранена. Загрузите модели в настройках, чтобы расшифровать её" }
        } catch {
            Analytics.recordingIssue(.stop)
            if processingID == m.id { liveStopped = true; liveTask?.cancel() }
            m = (try? library.read(m.id)) ?? m
            m.status = .failed; m.error = error.localizedDescription
            try? library.save(m); upsert(m); message = error.localizedDescription
        }
        activeMeeting = nil; recordingStarted = nil
        if processingID == m.id { setTurboEnabled(false) }
    }
    func importAudio() {
        guard !demo else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]; panel.message = "Записи iPhone, M4A, WAV, MP3 и другие аудиофайлы"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let file = try AVAudioFile(forReading: url)
                var m = Meeting(title: "", source: "Аудиофайл")
                m.title = m.defaultTitle; m.automaticTitle = m.title
                m.duration = Double(file.length) / file.processingFormat.sampleRate
                let name = "\(m.id.uuidString)-import.\(url.pathExtension)"
                try FileManager.default.copyItem(at: url, to: library.audioURL(name))
                m.audioFiles = [name]; try library.save(m); upsert(m); selectAfterSearch = false; selection = m.id
                Analytics.audioImported(duration: m.duration)
                if modelReady { enqueue(m.id) }
            } catch { message = error.localizedDescription }
        }
    }
    private func runLiveTranscription(id: UUID, model: URL, committed: Double, mode: String, reprocess: Bool) async {
        Analytics.transcriptionStarted(mode: mode, reprocess: reprocess)
        let granted = model.startAccessingSecurityScopedResource()
        var schedule = LiveTranscriptionSchedule(committed: committed)
        var failedDuringCapture = false
        var boundaryExhausted = false
        do {
            while true {
                try Task.checkCancellation()
                let stopped = liveStopped
                if transcriptionPerformance.mode.pausesForHeat(ProcessInfo.processInfo.thermalState) {
                    if liveStatus != "Обработка отложена до охлаждения" {
                        liveStatus = "Обработка отложена до охлаждения"
                    }
                    let delay: Duration = stopped && !preferences.usesQuietProcessing ? .milliseconds(200) : .seconds(5)
                    try await Task.sleep(for: delay)
                    continue
                }
                if !stopped && (livePaused || failedDuringCapture || boundaryExhausted) {
                    liveStatus = livePaused ? "Расшифровка на паузе" : "Черновик продолжится после записи"
                    try await Task.sleep(nanoseconds: 1_000_000_000); continue
                }
                let tracks: [CaptureTrackBoundary]
                if stopped {
                    let meeting = try await withLiveMeetingAccess { try library.read(id) }
                    tracks = try meeting.audioFiles.filter { !$0.contains(".clean.") }.compactMap { name in
                        let url = try library.audioURL(name)
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            if meeting.audioOffsets[name] != nil { throw PisaError.message("Аудиодорожка встречи недоступна") }
                            return nil // The expected second stream never started.
                        }
                        let file = try AVAudioFile(forReading: url)
                        guard file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0 else { throw PisaError.message("Некорректный формат аудиодорожки") }
                        return CaptureTrackBoundary(url: url, offset: meeting.audioOffsets[name] ?? 0, frames: file.length, sampleRate: file.processingFormat.sampleRate)
                    }
                    guard !tracks.isEmpty else { throw PisaError.message("Аудио этой встречи недоступно") }
                } else {
                    guard let boundary = await capture.transcriptionBoundary() else {
                        try await Task.sleep(nanoseconds: 1_000_000_000); continue
                    }
                    tracks = boundary
                }
                let ends = tracks.map { $0.offset + Double($0.frames) / $0.sampleRate }
                let available = stopped ? (ends.max() ?? 0) : (ends.min() ?? 0)
                guard available.isFinite else { throw PisaError.message("Некорректная длительность аудиодорожки") }
                if stopped && available + 0.05 < schedule.committed { throw PisaError.message("Сохранённый черновик выходит за доступную длину аудио") }
                if stopped && liveAudioDuration != available { liveAudioDuration = available }
                // The two seconds after the proposed cut are uncommitted
                // lookahead, so a turn crossing the cut can move wholly to the
                // next window without ever rereading the committed prefix.
                let schedulable = stopped ? available : max(0, available - 2)
                guard let window = schedule.next(available: schedulable, stopped: stopped) else {
                    if stopped {
                        liveStatus = "Собираю расшифровку"
                        await transcriber.finishLive()
                        await refreshSavedVoiceEmbeddings()
                        try Task.checkCancellation()
                        let availableNames = Set(tracks.map { $0.url.lastPathComponent })
                        let latest = try await saveLiveMeeting(id) { meeting in
                            guard meeting.segments.allSatisfy({ $0.audioFile.map(availableNames.contains) ?? true }) else {
                                throw PisaError.message("Аудио черновика недоступно")
                            }
                            meeting.segments = SpeakerClustering.assign(meeting.segments.sorted { $0.start < $1.start }, profiles: voiceProfiles)
                            meeting.duration = max(meeting.duration, available)
                            meeting.finishTranscription()
                        }
                        setTurboEnabled(false)
                        Analytics.transcriptionCompleted(mode: mode, reprocess: reprocess, duration: latest.duration)
                        await nameCompletedMeeting(id, exportOnCompletion: true)
                        break
                    }
                    liveStatus = "Готовлю черновик"
                    try await Task.sleep(nanoseconds: 1_000_000_000); continue
                }
                let startedAt = Date()
                do {
                    liveStatus = stopped ? "Завершаю расшифровку" : "Готовлю черновик"
                    let preceding = try await withLiveMeetingAccess {
                        try library.read(id).segments.filter { $0.end <= window.start && $0.end >= window.start - 300 }
                    }
                    let lookaheadEnd = min(available, window.end + 2)
                    let check: Transcriber.WindowBoundaryCheck? = stopped && lookaheadEnd == window.end + 2 ? .lookahead(window) : nil
                    var pass = try await transcribeWindow(tracks, window: window, end: lookaheadEnd, model: model,
                                                          preceding: preceding, boundaryCheck: check)
                    var usedNominalCut = false
                    if case .withoutLookahead(let isMic) = pass.retry {
                        do {
                            pass = try await transcribeWindow(tracks, window: window, end: window.end, model: model,
                                                             preceding: preceding, boundaryCheck: .nominal(window, isMic: isMic))
                        } catch {
                            try Task.checkCancellation()
                            if error is CancellationError { throw error }
                            pass = Transcriber.WindowPass(retry: .withLookahead)
                        }
                        if case .withLookahead = pass.retry {
                            pass = try await transcribeWindow(tracks, window: window, end: lookaheadEnd, model: model, preceding: preceding)
                        } else { usedNominalCut = true }
                    }
                    var segments = pass.segments
                    var committedEnd = usedNominalCut ? window.end
                        : LiveTranscriptionSchedule.safeBoundary(start: window.start, proposed: window.end, segments: segments)
                    if committedEnd == window.start {
                        if !stopped {
                            boundaryExhausted = !schedule.deferBoundary(window)
                            let delay = min(10.0, max(1.0, Date().timeIntervalSince(startedAt)))
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            continue
                        }
                        // The safe cut leaves too little progress. Recognize
                        // this uncommitted batch without lookahead after stop.
                        segments = try await transcribeWindow(tracks, window: window, end: window.end, model: model, preceding: preceding).segments
                        committedEnd = window.end
                    } else if !usedNominalCut { segments.removeAll { $0.end > committedEnd } }
                    try Task.checkCancellation()
                    try await saveLiveMeeting(id) { meeting in
                        meeting.segments.append(contentsOf: segments)
                        meeting.segments.sort { $0.start < $1.start }
                        meeting.liveCommittedUntil = committedEnd
                        for track in tracks { meeting.audioOffsets[track.url.lastPathComponent] = track.offset }
                        meeting.status = .processing; meeting.error = nil
                    }
                    schedule.commit(window, through: committedEnd)
                    if !stopped {
                        let delay = min(10.0, max(1.0, Date().timeIntervalSince(startedAt)))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                } catch {
                    schedule.fail(window)
                    if stopped || error is CancellationError { throw error }
                    failedDuringCapture = true
                }
            }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            Analytics.transcriptionFailed(mode: mode, cancelled: cancelled, reprocess: reprocess)
            if !cancelled {
                let failure = error as NSError
                Self.transcriptionLog.error("Transcription interrupted (\(mode, privacy: .public)): \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            }
            if var latest = (try? library.read(id)) ?? meetings.first(where: { $0.id == id }) {
                latest.status = .failed
                latest.error = cancelled ? "Обработка остановлена. Аудио сохранено." : error.localizedDescription
                try? library.save(latest)
                upsert(latest)
            }
        }
        await transcriber.finishLive()
        if granted { model.stopAccessingSecurityScopedResource() }
        liveTask = nil; liveStatus = ""; liveAudioDuration = nil; processingID = nil; phase = ""; runNext()
        runAudioArchive()
    }

    private func withLiveMeetingAccess<Value>(_ access: () throws -> Value) async throws -> Value {
        let previousStatus = liveStatus
        let waitingStatus = "Жду доступа к записи"
        defer { if liveStatus == waitingStatus { liveStatus = previousStatus } }
        return try await ProtectedFileRead.waitForAccess(read: access, onDenied: {
            if liveStatus != waitingStatus { liveStatus = waitingStatus }
        })
    }

    @discardableResult
    private func saveLiveMeeting(_ id: UUID, update: (inout Meeting) throws -> Void) async throws -> Meeting {
        try await withLiveMeetingAccess {
            var latest = try library.read(id)
            try update(&latest)
            try library.save(latest) // Cursor and text are saved together before the schedule advances.
            upsert(latest)
            return latest
        }
    }

    private func transcribeWindow(_ tracks: [CaptureTrackBoundary], window: LiveTranscriptionSchedule.Window, end: Double, model: URL,
                                  preceding: [TranscriptSegment], boundaryCheck: Transcriber.WindowBoundaryCheck? = nil) async throws -> Transcriber.WindowPass {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pisa-window-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try await Task.detached(executorPreference: transcriptionPerformance, priority: .utility) {
            try CaptureWindow.copy(tracks, start: window.start, end: end, directory: directory)
        }.value
        guard !files.isEmpty else {
            if case .nominal = boundaryCheck { return Transcriber.WindowPass(retry: .withLookahead) }
            return Transcriber.WindowPass()
        }
        var pass = try await transcriber.transcribeWindow(files: files.map { ($0.url, $0.offset) }, modelDirectory: model,
            context: preferences.vocabulary, speakerDirectory: library.root.appendingPathComponent("Models/Speakers"),
            performance: transcriptionPerformance, preceding: preceding, boundaryCheck: boundaryCheck)
        pass.segments = try pass.segments.map { segment in
            var mapped = segment
            guard let temporaryName = segment.audioFile,
                  let file = files.first(where: { temporaryName.contains("-mic.") ? $0.original.lastPathComponent.contains("-mic.") : $0.original.lastPathComponent.contains("-remote.") }) else {
                throw PisaError.message("Не удалось связать расшифровку с исходной записью")
            }
            mapped.audioFile = file.original.lastPathComponent
            return mapped
        }
        return pass
    }
    func enqueue(_ id: UUID, reprocess: Bool = false) {
        guard !demo, id != processingID, !isQueued(id),
              let saved = meetings.first(where: { $0.id == id }), saved.deletedAt == nil else { return }
        guard modelReady else { modelSetup.presented = true; return }
        if id == recordingMeetingID {
            // An open recording can only be read through the capture boundaries.
            guard !reprocess, canStartLiveTranscription, let model = modelURL() else { return }
            var meeting = saved
            meeting.status = .processing; meeting.error = nil
            meeting.interruptedBatchProgress = nil
            let committed = meeting.liveCommittedUntil ?? 0
            meeting.liveCommittedUntil = committed
            do { try library.save(meeting) } catch { message = error.localizedDescription; return }
            upsert(meeting); processingID = id
            livePaused = false; liveStopped = false; liveStatus = "Готовлю черновик"
            liveTask = Task(executorPreference: transcriptionPerformance, priority: .utility) { @MainActor in
                await self.runLiveTranscription(id: id, model: model, committed: committed, mode: "live", reprocess: false)
            }
            return
        }
        pending.append(QueuedTranscription(id: id, reprocess: reprocess)); runNext()
    }
    func cancelQueued(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index)
    }
    private func runNext() {
        guard processingID == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        let id = request.id
        let reprocess = request.reprocess
        guard var m = meetings.first(where: { $0.id == id }), let model = modelURL() else { return }
        // A manual retry of an interrupted draft must honor its saved checkpoint.
        let needsCleanDraft = m.status != .failed && m.liveCommittedUntil != nil
            && m.segments.contains { MeetingSpeechText.containsForeignLetters($0.text) }
        m.interruptedBatchProgress = nil
        if case .resume(let committed) = LiveTranscriptionSchedule.processingMode(committed: m.liveCommittedUntil, reprocess: reprocess || needsCleanDraft) {
            guard committed.isFinite, committed >= 0 else { m.status = .failed; m.error = "Некорректный курсор черновика"; try? library.save(m); upsert(m); runNext(); return }
            m.status = .processing; m.error = nil
            do { try library.save(m) } catch { message = error.localizedDescription; runNext(); return }
            upsert(m); processingID = id; progress = 0
            if request.turbo { setTurboTranscription(true, for: id) }
            liveStopped = true; livePaused = false; liveStatus = "Подготавливаю аудио"
            liveTask = Task(executorPreference: transcriptionPerformance, priority: .utility) { @MainActor in
                await self.runLiveTranscription(id: id, model: model, committed: committed, mode: "resume", reprocess: reprocess)
            }
            return
        }
        let granted = model.startAccessingSecurityScopedResource()
        m.status = .processing; m.error = nil
        do { try library.save(m) } catch { message = error.localizedDescription; if granted { model.stopAccessingSecurityScopedResource() }; return }
        isReprocessing = reprocess
        upsert(m); processingID = id; progress = 0
        if request.turbo { setTurboTranscription(true, for: id) }
        Analytics.transcriptionStarted(mode: "batch", reprocess: reprocess)
        let vocabulary = preferences.vocabulary
        processingTask = Task(executorPreference: transcriptionPerformance, priority: .utility) { @MainActor [self] in
            defer {
                if granted { model.stopAccessingSecurityScopedResource() }
                isReprocessing = false
                processingID = nil; processingTask = nil; phase = ""; runNext()
                runAudioArchive()
            }
            do {
                let files = try m.audioFiles.filter { !$0.contains(".clean.") }.map { (try library.audioURL($0), m.audioOffsets[$0] ?? 0) }
                    .filter { FileManager.default.fileExists(atPath: $0.0.path) }
                guard !files.isEmpty else { throw PisaError.message("Аудио этой встречи недоступно") }
                let result = try await transcriber.transcribe(files: files, modelDirectory: model, context: vocabulary,
                    speakerDirectory: library.root.appendingPathComponent("Models/Speakers"), performance: transcriptionPerformance,
                    retainProcessedMicrophone: m.audioArchive == nil) { [self] fraction, description in
                    await self.updateProcessingProgress(fraction, description)
                }
                let generated = try Set(result.compactMap(\.audioFile)).filter { $0.contains(".clean.") && !m.audioFiles.contains($0) }.map { try library.audioURL($0) }
                var persisted = false
                defer { if !persisted { for url in generated { try? FileManager.default.removeItem(at: url) } } }
                await refreshSavedVoiceEmbeddings()
                try Task.checkCancellation()
                var latest = try await ProtectedFileRead.waitForAccess(read: {
                    try library.read(id)
                }, onDenied: {
                    updateProcessingProgress(1, "Жду доступа к записи")
                })
                // Use the current profiles even if a name changed during recognition.
                latest.segments = SpeakerClustering.assign(result, profiles: voiceProfiles)
                latest.finishTranscription()
                let referenced = Set(result.compactMap(\.audioFile))
                let obsolete = latest.audioFiles.filter { $0.contains(".clean.") && !referenced.contains($0) }
                latest.audioFiles.removeAll { obsolete.contains($0) }
                for name in obsolete { latest.audioOffsets[name] = nil }
                for segment in result {
                    if let name = segment.audioFile, name.contains(".clean."), !latest.audioFiles.contains(name) {
                        latest.audioFiles.append(name)
                        if let original = latest.audioFiles.first(where: { $0.contains("-mic.") && !$0.contains(".clean.") }) {
                            latest.audioOffsets[name] = latest.audioOffsets[original] ?? 0
                        }
                    }
                }
                try library.save(latest); persisted = true; upsert(latest)
                setTurboEnabled(false)
                Analytics.transcriptionCompleted(mode: "batch", reprocess: reprocess, duration: latest.duration)
                await nameCompletedMeeting(id, exportOnCompletion: true)
                let shared = Set(meetings.filter { $0.id != id }.flatMap(\.audioFiles))
                for name in obsolete where !shared.contains(name) {
                    if let url = try? library.audioURL(name) { try? FileManager.default.removeItem(at: url) }
                }
            } catch {
                Analytics.transcriptionFailed(mode: "batch", cancelled: error is CancellationError || Task.isCancelled, reprocess: reprocess)
                var latest = (try? library.read(id)) ?? meetings.first(where: { $0.id == id }) ?? m
                latest.status = .failed
                latest.error = error is CancellationError ? "Обработка остановлена. Аудио сохранено." : error.localizedDescription
                if !phase.isEmpty && (0...1).contains(progress) {
                    latest.interruptedBatchProgress = progress
                }
                try? library.save(latest); upsert(latest)
            }
        }
    }
    private func runAudioArchive() {
        guard audioArchiveTask == nil, !demo, !recording, !starting, processingID == nil else { return }
        let now = Date()
        guard let meeting = meetings.last(where: {
            $0.audioArchive == .pending && $0.status == .ready && $0.deletedAt == nil &&
            (audioArchiveRetryAfter[$0.id] ?? .distantPast) <= now
        }) else { return }
        let library = self.library
        audioArchiveTask = Task { @MainActor [weak self] in
            defer {
                self?.audioArchiveTask = nil
                self?.runAudioArchive()
            }
            do {
                let worker = Task.detached(priority: .background) {
                    try await MeetingAudioArchive.prepare(meeting, in: library)
                }
                let replacements = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                defer { for replacement in replacements { replacement.discard() } }
                while let self {
                    try Task.checkCancellation()
                    let id = meeting.id
                    guard let current = self.meetings.first(where: { $0.id == id }), current.deletedAt == nil,
                          current.audioArchive == .pending, current.audioFiles == meeting.audioFiles,
                          current.audioOffsets == meeting.audioOffsets, current.status == .ready else { return }
                    if !replacements.isEmpty && self.audioArchiveIsInUse(current) {
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }
                    var latest = try library.read(id)
                    try MeetingAudioArchive.install(replacements, for: meeting, in: library)
                    latest.audioArchive = .complete
                    try library.save(latest)
                    self.audioArchiveRetryAfter[id] = nil
                    self.upsert(latest)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                self?.audioArchiveRetryAfter[meeting.id] = Date().addingTimeInterval(60)
                let failure = error as NSError
                Self.audioArchiveLog.error("Audio archive deferred: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            }
        }
    }

    private func audioArchiveIsInUse(_ meeting: Meeting) -> Bool {
        audioExports.contains(meeting.id) || voiceAssignmentRequests[meeting.id] != nil ||
            (selection == meeting.id && savedAudioPlayer.timeControlStatus != .paused) ||
            meeting.segments.contains { $0.id == playingSegmentID }
    }

    private func updateProcessingProgress(_ fraction: Double, _ description: String) {
        progress = fraction; phase = description
    }
    /// Failure here never changes the successful transcription's status or text.
    func nameCompletedMeeting(_ id: UUID, exportOnCompletion: Bool = false) async {
        var needsExport = exportOnCompletion
        defer {
            if needsExport, let meeting = try? library.read(id), meeting.status == .ready, meeting.deletedAt == nil {
                exportIfConfigured(meeting)
            }
        }
        do {
            let snapshot = try library.read(id)
            guard snapshot.deletedAt == nil, snapshot.needsGeneratedTitle else { return }
            liveStatus = ""
            let title = try await titleModel.title(for: snapshot.segments, root: library.root.appendingPathComponent("Models")) { [weak self] description in
                await self?.updateProcessingProgress(1, description)
            }
            try Task.checkCancellation()
            guard let title, var latest = try? library.read(id), latest.deletedAt == nil,
                  latest.segments.map(\.text) == snapshot.segments.map(\.text),
                  latest.applyGeneratedTitle(title) else { return }
            try library.save(latest); upsert(latest); needsExport = true
        } catch {
            if !(error is CancellationError) {
                message = "Расшифровка сохранена. Не удалось придумать название: " + error.localizedDescription
            }
        }
    }
    func stopPlayback() {
        savedAudioPlayer.pause()
        player?.stop(); playingSegmentID = nil; playbackTimer?.invalidate(); playbackTimer = nil
    }
    func play(_ segment: TranscriptSegment, in meeting: Meeting) {
        if !startPlayback(segment, in: meeting, toggle: true) { message = "Аудио этого фрагмента недоступно" }
        else if playingSegmentID == segment.id { Analytics.feature(.segmentPlayed) }
    }
    @discardableResult
    private func startPlayback(_ segment: TranscriptSegment, in meeting: Meeting, toggle: Bool, normalizePreview: Bool = false) -> Bool {
        guard !demo, !recording else { stopPlayback(); return false }
        if toggle && playingSegmentID == segment.id { stopPlayback(); return true }
        let name = segment.audioFile ?? meeting.audioFiles.first { segment.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") } ?? meeting.audioFiles.first
        guard let name, meeting.audioFiles.contains(name), let url = try? library.audioURL(name),
              SavedVoiceAudio.isRegularAudio(url, in: library.audioDirectory),
              let candidate = try? AVAudioPlayer(contentsOf: url) else { stopPlayback(); return false }
        let offset = meeting.audioOffsets[name] ?? 0
        let start = segment.start - offset, end = segment.end - offset
        guard offset.isFinite, start.isFinite, end.isFinite, end > start, end > 0,
              start < candidate.duration, candidate.duration > 0 else { stopPlayback(); return false }
        if !toggle && playingSegmentID == segment.id && player?.isPlaying == true { return true }
        stopPlayback()
        let clipStart = max(0, start), clipEnd = min(end, candidate.duration)
        if normalizePreview,
           let data = try? AudioPreview.normalizedData(from: url, start: clipStart, end: clipEnd),
           let preview = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.caf.rawValue),
           preview.play() {
            player = preview
            playbackEnd = preview.duration
        } else {
            candidate.currentTime = clipStart
            guard candidate.play() else { return false }
            player = candidate
            playbackEnd = clipEnd
        }
        playingSegmentID = segment.id
        schedulePlaybackStop()
        return true
    }
    private func schedulePlaybackStop() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player?.isPlaying != true || (self.player?.currentTime ?? 0) >= self.playbackEnd { self.stopPlayback() }
            }
        }
    }
    func preview(_ segment: TranscriptSegment, in meeting: Meeting) {
        var clip = segment
        clip.end = min(clip.end, clip.start + 8)
        if !startPlayback(clip, in: meeting, toggle: true, normalizePreview: true) {
            message = "Аудио этого фрагмента недоступно"
        }
    }
    func playExample(_ example: VoiceExample) {
        guard !recording else { return }
        if playingSegmentID == example.id { stopPlayback(); return }
        guard example.file == URL(fileURLWithPath: example.file).lastPathComponent else { return }
        do {
            let candidate = try AVAudioPlayer(contentsOf: library.root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file))
            stopPlayback()
            player = candidate
            playbackEnd = candidate.duration; candidate.play(); playingSegmentID = example.id; schedulePlaybackStop()
        } catch { message = "Образец голоса недоступен" }
    }
    func voiceSample(for segmentID: UUID, in meeting: Meeting) -> TranscriptSegment? {
        guard let candidate = automaticVoiceSample(for: segmentID, in: meeting), let filename = candidate.audioFile,
              let url = try? library.audioURL(filename), SavedVoiceAudio.isRegularAudio(url, in: library.audioDirectory),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return automaticVoiceSample(for: segmentID, in: meeting, audioDurations: [filename: duration])
    }
    func assignVoice(meetingID: UUID, segmentID: UUID, name: String, allMatching: Bool, remember: Bool,
                     extractEmbedding: (@Sendable ([Float]) throws -> [Float]?)? = nil) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let m = meetings.first(where: { $0.id == meetingID }), canModify(m),
              let sample = m.segments.first(where: { $0.id == segmentID }) else { return }
        func applyingName(to original: Meeting) -> Meeting {
            var meeting = original
            for index in meeting.segments.indices
                where meeting.segments[index].id == segmentID || (allMatching && meeting.segments[index].speaker == sample.speaker) {
                // Preserve the original track when a microphone label is renamed.
                if meeting.segments[index].audioFile == nil {
                    meeting.segments[index].audioFile = meeting.audioFiles.first {
                        meeting.segments[index].speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.")
                    } ?? meeting.audioFiles.first
                }
                meeting.segments[index].speaker = clean
            }
            return meeting
        }
        let request = UUID()
        voiceAssignmentRequests[meetingID] = request
        defer { if voiceAssignmentRequests[meetingID] == request { voiceAssignmentRequests[meetingID] = nil } }
        if remember {
            do {
                guard let automatic = voiceSample(for: sample.id, in: m), let filename = automatic.audioFile else {
                    throw PisaError.message("Не найден подходящий образец голоса от 2 секунд без отмеченных наложений. Можно применить имя без запоминания голоса")
                }
                let profileID = voiceProfiles.first(where: { $0.name == clean })?.id
                let source = try library.audioURL(filename)
                let offset = m.audioOffsets[filename] ?? 0
                let model = speakerEmbeddingModel
                let knownProfiles = voiceProfiles
                let clipName = UUID().uuidString + ".caf"
                let destination = library.root.appendingPathComponent("VoiceSamples").appendingPathComponent(clipName)
                var saved = false
                defer { if !saved { try? FileManager.default.removeItem(at: destination) } }
                let task = Task.detached(priority: .userInitiated) {
                    try SavedVoiceAudio.saveSample(source: source, start: automatic.start - offset, end: automatic.end - offset,
                                                  destination: destination, model: model, extractEmbedding: extractEmbedding,
                                                  profiles: knownProfiles, name: clean)
                }
                let embedding = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                try Task.checkCancellation()
                guard voiceAssignmentRequests[meetingID] == request else { return }
                guard let latest = meetings.first(where: { $0.id == meetingID }), canModify(latest),
                      latest.deletedAt == m.deletedAt, latest.segments == m.segments,
                      latest.audioFiles == m.audioFiles, latest.audioOffsets == m.audioOffsets,
                      voiceProfiles == knownProfiles,
                      profileID == nil || voiceProfiles.contains(where: { $0.id == profileID && $0.name == clean }) else {
                    throw PisaError.message("Запись или голос изменились. Выберите фрагмент заново")
                }
                let example = VoiceExample(file: clipName, meetingID: meetingID, segmentID: sample.id, embedding: embedding)
                    .withCurrentEmbedding(embedding)
                let updated = preservingAudioFiles(in: applyingName(to: latest))
                let profiles = voiceProfilesAdding(example, name: clean)
                try saveVoiceChanges([(before: latest, after: updated)], profiles: profiles)
                saved = true
                Analytics.voiceAssigned(remembered: true, allMatching: allMatching)
            } catch is CancellationError {
                return
            } catch {
                if voiceAssignmentRequests[meetingID] == request {
                    message = "Имя не сохранено: \(error.localizedDescription)"
                }
            }
        } else if update(applyingName(to: m)) {
            Analytics.voiceAssigned(remembered: false, allMatching: allMatching)
        }
    }
    private var speakerEmbeddingModel: URL {
        library.root.appendingPathComponent("Models/Speakers/titanet.onnx")
    }
    private func refreshSavedVoiceEmbeddings() async {
        let examples = voiceProfiles.flatMap { $0.examples ?? [] }.filter(\.needsEmbeddingRefresh)
        let model = speakerEmbeddingModel
        guard !examples.isEmpty, !Task.isCancelled, FileManager.default.fileExists(atPath: model.path) else { return }
        let folder = library.root.appendingPathComponent("VoiceSamples", isDirectory: true)
        let snapshot = voiceProfiles
        let task = Task.detached(priority: .utility) { SavedVoiceAudio.refreshedExamples(snapshot, folder: folder, model: model) }
        let refreshed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, !refreshed.isEmpty, voiceProfiles == snapshot else { return }
        var profiles = voiceProfiles
        var changed = false
        for index in profiles.indices where profiles[index].refreshExampleEmbeddings(refreshed) { changed = true }
        guard changed else { return }
        do { try saveVoiceProfiles(profiles) }
        catch { Self.transcriptionLog.error("Could not refresh voice embeddings: \(error.localizedDescription)") }
    }
    private func voiceProfilesAdding(_ example: VoiceExample, name: String) -> [VoiceProfile] {
        var profiles = voiceProfiles
        // A clip belongs to the voice it was most recently assigned to.
        for index in profiles.indices {
            let examples = profiles[index].examples ?? []
            let retained = examples.filter { $0.meetingID != example.meetingID || $0.segmentID != example.segmentID }
            if retained.count != examples.count {
                replaceVoiceExamples(in: &profiles[index], with: retained)
            }
        }
        let index: Int
        if let existing = profiles.firstIndex(where: { $0.name == name }) {
            index = existing
        } else {
            index = profiles.count
            profiles.append(VoiceProfile(name: name, samples: []))
        }
        profiles[index].samples.append(example.embedding)
        profiles[index].examples = (profiles[index].examples ?? []) + [example]
        return profiles
    }

    func cancelProcessing() {
        setTurboEnabled(false)
        processingTask?.cancel()
        if processingID != recordingMeetingID { liveTask?.cancel() }
    }
    func canReviewTerms(_ meeting: Meeting) -> Bool {
        meeting.status == .ready && meeting.liveCommittedUntil == nil && meeting.deletedAt == nil &&
            !meeting.segments.isEmpty && canModify(meeting)
    }
    func replaceTerms(_ occurrences: [TermOccurrence], with replacement: String, meetingID: UUID) throws {
        guard var meeting = meetings.first(where: { $0.id == meetingID }), canReviewTerms(meeting),
              let updated = TranscriptTerms.replacing(occurrences, with: replacement, in: meeting.segments) else {
            throw PisaError.message("Не удалось применить замену. Проверьте написание и найдите термин заново")
        }
        var before: [UUID: String] = [:]
        var after: [UUID: String] = [:]
        for (original, edited) in zip(meeting.segments, updated) where original.text != edited.text {
            before[original.id] = original.text
            after[original.id] = edited.text
        }
        guard !before.isEmpty else { return }
        meeting.segments = updated
        try library.save(meeting)
        termReplacementUndo[meetingID] = (before, after)
        upsert(meeting)
        Analytics.feature(.termsReplaced)
        exportIfConfigured(meeting)
    }
    func canUndoTermReplacement(meetingID: UUID) -> Bool {
        guard let undo = termReplacementUndo[meetingID],
              let meeting = meetings.first(where: { $0.id == meetingID }), canReviewTerms(meeting) else { return false }
        return meeting.segments.filter { undo.after[$0.id] == $0.text }.count == undo.after.count
    }
    func undoTermReplacement(meetingID: UUID) throws {
        guard canUndoTermReplacement(meetingID: meetingID), let undo = termReplacementUndo[meetingID],
              var meeting = meetings.first(where: { $0.id == meetingID }) else {
            throw PisaError.message("Расшифровка изменилась. Последнюю замену уже нельзя отменить")
        }
        for index in meeting.segments.indices {
            if let original = undo.before[meeting.segments[index].id] { meeting.segments[index].text = original }
        }
        try library.save(meeting)
        termReplacementUndo[meetingID] = nil
        upsert(meeting)
        exportIfConfigured(meeting)
    }
    func addRecognitionTerm(_ term: String) throws {
        guard !demo else { return }
        var updated = preferences
        updated.vocabulary = TranscriptTerms.adding(term, to: preferences.vocabulary)
        guard updated.vocabulary != preferences.vocabulary else {
            throw PisaError.message("Введите один новый термин без запятых и точек с запятой")
        }
        try library.savePreferences(updated)
        preferences = updated
        Analytics.feature(.dictionaryTermAdded)
    }
    private func preservingAudioFiles(in value: Meeting) -> Meeting {
        var meeting = value
        if let previous = meetings.first(where: { $0.id == meeting.id }) {
            meeting.audioArchive = previous.audioArchive
            let originals = Dictionary(uniqueKeysWithValues: previous.segments.map { ($0.id, $0) })
            for i in meeting.segments.indices where meeting.segments[i].audioFile == nil {
                let original = originals[meeting.segments[i].id] ?? meeting.segments[i]
                meeting.segments[i].audioFile = original.audioFile ?? meeting.audioFiles.first { original.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") } ?? meeting.audioFiles.first
            }
        }
        return meeting
    }
    @discardableResult
    func update(_ value: Meeting) -> Bool {
        let meeting = preservingAudioFiles(in: value)
        guard !demo else { upsert(meeting); return false }
        do {
            try library.save(meeting); upsert(meeting)
            if meeting.status == .ready { exportIfConfigured(meeting) }
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func editSegmentText(_ text: String, from original: TranscriptSegment, meetingID: UUID) {
        guard text != original.text,
              var meeting = meetings.first(where: { $0.id == meetingID }),
              let index = meeting.segments.firstIndex(where: { $0.id == original.id }) else { return }
        meeting.segments[index].text = text
        if update(meeting) { Analytics.feature(.transcriptEdited) }
    }
    func renameVoice(_ id: UUID, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PisaError.message("Введите имя") }
        guard let index = voiceProfiles.firstIndex(where: { $0.id == id }) else { throw PisaError.message("Голос уже удалён") }
        guard !voiceProfiles.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else {
            throw PisaError.message("Голос с таким именем уже сохранён. Укажите другое имя")
        }
        let profile = voiceProfiles[index]
        guard profile.name != clean else { return }
        var updated = voiceProfiles
        updated[index].name = clean
        updated[index].requestIdentityRevalidation()
        try saveVoiceNameChange(from: profile, to: clean, profiles: updated)
    }
    func mergeVoice(_ sourceID: UUID, into targetID: UUID) throws {
        guard sourceID != targetID else { throw PisaError.message("Выберите другой голос") }
        guard let source = voiceProfiles.first(where: { $0.id == sourceID }),
              let targetIndex = voiceProfiles.firstIndex(where: { $0.id == targetID }) else {
            throw PisaError.message("Один из выбранных голосов уже удалён")
        }
        var updated = voiceProfiles
        var merged = updated[targetIndex]
        let targetExamples = merged.examples ?? []
        let sourceExamples = source.examples ?? []
        merged.samples = unpairedVoiceSamples(in: merged) + unpairedVoiceSamples(in: source)
        let examples = targetExamples + sourceExamples
        merged.samples += examples.map(\.embedding)
        if !examples.isEmpty { merged.examples = examples }
        merged.requestIdentityRevalidation()
        updated[targetIndex] = merged
        updated.removeAll { $0.id == sourceID }
        try saveVoiceNameChange(from: source, to: merged.name, profiles: updated)
    }
    private func saveVoiceNameChange(from profile: VoiceProfile, to newName: String, profiles: [VoiceProfile]) throws {
        let oldName = profile.name
        guard oldName != newName else {
            try saveVoiceProfiles(profiles)
            return
        }
        let isDefaultLabel = oldName == "Я" || oldName == "Собеседники" ||
            (oldName.hasPrefix("Спикер ") && Int(oldName.dropFirst("Спикер ".count)) != nil)
        let examples = Dictionary(grouping: profile.examples ?? [], by: \.meetingID)
        let matcher = isDefaultLabel ? VoiceMatcher(profiles: voiceProfiles) : nil
        let changes = try library.all(includeDeleted: true).compactMap { original -> (before: Meeting, after: Meeting)? in
            var meeting = original
            let sampleIDs = Set(examples[original.id, default: []].map(\.segmentID))
            var changed = false
            for index in meeting.segments.indices where meeting.segments[index].speaker == oldName {
                let segment = meeting.segments[index]
                if isDefaultLabel && !sampleIDs.contains(segment.id) {
                    // Generic labels are shared by unrelated voices.
                    let isRemote = segment.audioFile.map { !$0.contains("-mic.") } ?? false
                    guard oldName != "Я" || isRemote, let embedding = segment.embedding,
                          matcher?.identify(embedding) == oldName else { continue }
                }
                if segment.audioFile == nil, (oldName == "Я") != (newName == "Я") {
                    meeting.segments[index].audioFile = meeting.audioFiles.first {
                        oldName == "Я" ? $0.contains("-mic.") : $0.contains("-remote.")
                    } ?? meeting.audioFiles.first
                }
                meeting.segments[index].speaker = newName
                changed = true
            }
            return changed ? (original, meeting) : nil
        }
        try saveVoiceChanges(changes, profiles: profiles)
    }
    private func saveVoiceChanges(_ changes: [(before: Meeting, after: Meeting)], profiles: [VoiceProfile]) throws {
        var saved: [Meeting] = []
        do {
            for change in changes {
                try library.save(change.after)
                saved.append(change.before)
            }
            try saveVoiceProfiles(profiles)
        } catch {
            var rollbackFailed = false
            for meeting in saved.reversed() {
                do { try library.save(meeting) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw PisaError.message("Не удалось сохранить изменение и восстановить все прежние подписи. Проверьте доступ к библиотеке и повторите действие.")
            }
            throw error
        }
        if !demo {
            for change in changes { upsert(change.after) }
            for change in changes where change.after.status == .ready { exportIfConfigured(change.after) }
        }
    }
    func removeVoiceExample(_ exampleID: UUID, from profileID: UUID) throws {
        guard let index = voiceProfiles.firstIndex(where: { $0.id == profileID }),
              let examples = voiceProfiles[index].examples,
              examples.contains(where: { $0.id == exampleID }) else {
            throw PisaError.message("Образец уже удалён")
        }
        let retained = examples.filter { $0.id != exampleID }
        guard !retained.isEmpty else {
            throw PisaError.message("Последний образец можно удалить вместе с голосом")
        }
        var updated = voiceProfiles
        replaceVoiceExamples(in: &updated[index], with: retained)
        try saveVoiceProfiles(updated)
    }
    private func replaceVoiceExamples(in profile: inout VoiceProfile, with examples: [VoiceExample]) {
        profile.samples = unpairedVoiceSamples(in: profile) + examples.map(\.embedding)
        profile.examples = examples
    }
    private func unpairedVoiceSamples(in profile: VoiceProfile) -> [[Float]] {
        // Older profiles may have embeddings without audio, or fewer embeddings than clips.
        var unpairedSamples = profile.samples
        for example in profile.examples ?? [] {
            if let index = unpairedSamples.firstIndex(of: example.embedding) {
                unpairedSamples.remove(at: index)
            }
        }
        return unpairedSamples
    }
    func forgetVoice(_ id: UUID) throws {
        try saveVoiceProfiles(voiceProfiles.filter { $0.id != id })
    }
    private func saveVoiceProfiles(_ profiles: [VoiceProfile]) throws {
        try library.saveVoices(profiles)
        let previous = voiceProfiles
        if let playingSegmentID,
           previous.contains(where: { $0.examples?.contains(where: { $0.id == playingSegmentID }) == true }),
           !profiles.contains(where: { $0.examples?.contains(where: { $0.id == playingSegmentID }) == true }) {
            stopPlayback()
        }
        voiceProfiles = profiles
        cleanupVoiceExamples(previous: previous, current: profiles)
    }
    private func cleanupVoiceExamples(previous: [VoiceProfile], current: [VoiceProfile]) {
        let retained = Set(current.flatMap { $0.examples ?? [] }.map(\.file))
        for example in previous.flatMap({ $0.examples ?? [] }) where !retained.contains(example.file) {
            guard example.file == URL(fileURLWithPath: example.file).lastPathComponent else { continue }
            try? FileManager.default.removeItem(at: library.root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file))
        }
    }
    private func upsert(_ m: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == m.id }) { meetings[index] = m } else { meetings.insert(m, at: 0) }
        searchIndex.upsert(m)
        if !search.isEmpty { refreshSearch() }
    }
    func modelURL() -> URL? {
        if let data = preferences.modelBookmark { var stale = false; return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) }
        let local = library.root.appendingPathComponent("Models/Qwen3-ASR")
        return FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path) ? local : nil
    }
    func chooseModel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Папка Qwen3-ASR в формате MLX. Все вычисления останутся на Mac"
        if panel.runModal() == .OK, let url = panel.url {
            do { preferences.modelBookmark = try url.bookmarkData(options: .withSecurityScope); preferences.modelDisplayPath = url.path; savePreferences(); modelSetup.check(presentWhenNeeded: false); objectWillChange.send() } catch { message = error.localizedDescription }
        }
    }
    func chooseExportFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Папка для Markdown. Если это Dropbox или iCloud, тексты будут синхронизироваться их приложением"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try setExportFolder(url) }
        catch { message = error.localizedDescription }
    }
    func disableExportFolder() {
        do { try setExportFolder(nil) }
        catch { message = error.localizedDescription }
    }
    func setExportFolder(_ folder: URL?) throws {
        var updated = preferences
        updated.exportBookmark = try folder?.bookmarkData(options: .withSecurityScope)
        updated.exportDisplayPath = folder?.path
        try library.savePreferences(updated)
        preferences = updated
        Analytics.setting(.automaticExport, enabled: folder != nil)
        refreshExportFolderAccess()
    }
    func refreshExportFolderAccess() {
        withConfiguredExportFolder { _ in }
    }
    func exportIfConfigured(_ meeting: Meeting) {
        guard meeting.deletedAt == nil else { return }
        do {
            try withConfiguredExportFolder { folder in
                _ = try MarkdownExporter.export(meeting, to: folder)
            }
        } catch {
            let detail = error.localizedDescription
            let punctuation = detail.hasSuffix(".") ? "" : "."
            message = "Экспорт не выполнен. \(detail)\(punctuation) Расшифровка сохранена на Mac."
        }
    }
    private func withConfiguredExportFolder(_ action: (URL) throws -> Void) rethrows {
        guard !demo else { return }
        guard let data = preferences.exportBookmark else {
            if exportFolderUnavailable { exportFolderUnavailable = false }
            return
        }
        var stale = false
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
        guard let folder = try? URL(resolvingBookmarkData: data, options: options, bookmarkDataIsStale: &stale),
              folder.startAccessingSecurityScopedResource() else {
            if !exportFolderUnavailable { exportFolderUnavailable = true }
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey]),
              values.isDirectory == true, values.isWritable == true else {
            if !exportFolderUnavailable { exportFolderUnavailable = true }
            return
        }

        if exportFolderUnavailable { exportFolderUnavailable = false }
        if stale, let bookmark = try? folder.bookmarkData(options: .withSecurityScope) {
            var updated = preferences
            updated.exportBookmark = bookmark
            updated.exportDisplayPath = folder.path
            if (try? library.savePreferences(updated)) != nil { preferences = updated }
        }
        try action(folder)
    }
    private func canDeleteAudio(_ meeting: Meeting) -> Bool {
        canModify(meeting) && meeting.status == .ready && !audioExports.contains(meeting.id)
    }

    func audioCleanupPlan(olderThan cutoff: Date, usage: LibraryStorageUsage) -> AudioCleanupPlan {
        let excluded = Set(meetings.filter { !canDeleteAudio($0) }.map(\.id))
        return usage.cleanupPlan(olderThan: cutoff, meetings: meetings, excluding: excluded)
    }

    func cleanUpAudio(_ approved: AudioCleanupPlan, usage: LibraryStorageUsage) -> AudioCleanupResult {
        let current = audioCleanupPlan(olderThan: approved.cutoff, usage: usage)
        var result = AudioCleanupResult()
        for meeting in meetings {
            guard let approvedNames = approved.filesByMeeting[meeting.id],
                  let currentNames = current.filesByMeeting[meeting.id] else { continue }
            let names = Set(approvedNames).intersection(currentNames)
            guard !names.isEmpty else { continue }
            do {
                let removal = try removeAudio(from: meeting, names: names)
                if removal.meeting.audioFiles != meeting.audioFiles { result.meetings += 1 }
                result.bytes += removal.bytes
                if removal.failedFiles > 0 { result.failedMeetings += 1 }
            } catch {
                result.failedMeetings += 1
            }
        }
        if result.meetings > 0 { Analytics.feature(.audioCleanedUp) }
        return result
    }

    func deleteAudio(_ meeting: Meeting) {
        guard let current = meetings.first(where: { $0.id == meeting.id }), canDeleteAudio(current) else { return }
        let shared = Set(meetings.filter { $0.id != current.id }.flatMap(\.audioFiles))
        do {
            let result = try removeAudio(from: current, names: Set(current.audioFiles), keepingFiles: shared)
            if result.meeting.audioFiles != current.audioFiles { Analytics.feature(.audioDeleted) }
            if result.failedFiles > 0 {
                message = "Не всё аудио удалось удалить"
            }
        } catch {
            message = "Не всё аудио удалось удалить: \(error.localizedDescription)"
        }
    }

    private func removeAudio(from meeting: Meeting, names: Set<String>, keepingFiles shared: Set<String> = []) throws
        -> (meeting: Meeting, bytes: Int64, failedFiles: Int) {
        if selection == meeting.id || meeting.segments.contains(where: { $0.id == playingSegmentID }) {
            stopPlayback()
            player = nil
            savedAudioPlayer.replaceCurrentItem(with: nil)
        }
        let result = try library.removeAudio(from: meeting, names: names, keepingFiles: shared)
        if result.meeting != meeting { upsert(result.meeting) }
        return result
    }
    func canExport(_ meeting: Meeting) -> Bool {
        canModify(meeting) && !meeting.segments.isEmpty
    }
    func exportTranscript(_ meeting: Meeting) {
        guard canExport(meeting) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(meeting.title.replacingOccurrences(of: "/", with: "-" )).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.isExtensionHidden = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try MarkdownExporter.render(meeting).write(to: url, atomically: true, encoding: .utf8)
                Analytics.feature(.transcriptExported)
            } catch { message = error.localizedDescription }
        }
    }
    func canExportAudio(_ meeting: Meeting) -> Bool {
        guard !audioExports.contains(meeting.id), canModify(meeting), let sources = try? MeetingAudioExport.sources(for: meeting, in: library) else { return false }
        return !sources.isEmpty
    }
    func exportAudio(_ meeting: Meeting) async {
        guard canExportAudio(meeting) else { return }
        audioExports.insert(meeting.id)
        defer { audioExports.remove(meeting.id) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".m4a"
        panel.allowedContentTypes = [UTType(filenameExtension: "m4a") ?? .mpeg4Audio]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            try await MeetingAudioExport.write(meeting, from: library, to: url)
            Analytics.feature(.audioExported)
        } catch {
            message = "Не удалось экспортировать аудио: \(error.localizedDescription)"
        }
    }
    func showDemo() {
        guard !recording, processingID == nil else { return }
        demo.toggle()
        if !demo {
            meetings = (try? library.all(includeDeleted: true)) ?? []
            replaceSearchIndex()
            selectFirstMatching()
            return
        }
        var m = Meeting(title: "Планы на неделю", source: "Толк"); m.duration = 1842; m.status = .ready
        m.segments = [
            .init(start: 12, end: 28, speaker: "Я", text: "Давайте сверим планы на неделю. Хочется сначала проверить основной сценарий и только потом добавлять новые возможности."),
            .init(start: 29, end: 48, speaker: "Даша", text: "Да, я подготовлю несколько примеров к среде. Посмотрим, где людям приходится делать лишние шаги."),
            .init(start: 49, end: 70, speaker: "Я", text: "Отлично. Тогда в четверг вместе посмотрим результаты. Если что-то не успеваем, сразу обсудим, что можно упростить."),
            .init(start: 72, end: 94, speaker: "Даша", text: "Договорились. Ещё соберу обратную связь от команды и принесу короткий список вопросов.")]
        meetings = [m]; replaceSearchIndex(); selectAfterSearch = false; selection = m.id
    }
}


struct AudioCleanupResult {
    var meetings = 0
    var bytes: Int64 = 0
    var failedMeetings = 0
}

@MainActor
final class RecordingMonitor: ObservableObject {
    var microphone = AudioMeterTrack()
    var system = AudioMeterTrack()
    @Published var now: Double = 0
    private(set) var updatedAt = Date()
    private(set) var began: Double = 0
    func reset() {
        microphone = AudioMeterTrack(); system = AudioMeterTrack()
        updatedAt = Date()
        began = ProcessInfo.processInfo.systemUptime; now = began
    }
    func update(microphone: CaptureMeterSample, system: CaptureMeterSample) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        self.microphone.update(peak: microphone.peak, seconds: microphone.seconds, lastWrite: microphone.lastWrite, now: timestamp)
        self.system.update(peak: system.peak, seconds: system.seconds, lastWrite: system.lastWrite, now: timestamp)
        updatedAt = Date()
        now = timestamp
    }
}

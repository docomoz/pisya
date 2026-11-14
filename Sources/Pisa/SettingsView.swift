import SwiftUI
import AppKit
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var updates = AppUpdates.shared
    @State private var section = "Запись"
    @State private var showRecordingDetails = false
    init(initialSection: String = "Запись") {
        _section = State(initialValue: initialSection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            HStack(spacing: PisaDesign.Spacing.inline) { SectionHeading("Настройки", style: .window); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(PisaDesign.Typography.Icon.close).foregroundStyle(Color.mutedInk) }.shapeAwarePlainButton(Circle()).screenHelp("Закрыть настройки").accessibilityLabel("Закрыть настройки") }
            SettingsSectionPicker(selection: $section)
            if section == "Голоса" {
                SavedVoicesSettings()
            } else if section == "Словарь" {
                VocabularyDictionaryView()
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                    switch section {
                    case "Запись":
                        recordingSettings
                    case "Модель":
                        modelSettings
                    case "Экспорт":
                        columns {
                        block("Папка для расшифровок", "Markdown — для обычной папки, Dropbox или Obsidian") {
                            if state.preferences.exportBookmark != nil {
                                if let path = state.preferences.exportDisplayPath {
                                    screenText(verbatim: path).textStyle(PisaDesign.Typography.code)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            } else {
                                screenText("Автоэкспорт выключен").foregroundStyle(Color.mutedInk)
                            }
                            HStack(spacing: PisaDesign.Spacing.related) {
                                screenButton("Выбрать папку…") { state.chooseExportFolder() }.actionButton()
                                if state.preferences.exportBookmark != nil {
                                    screenButton("Отключить") { state.disableExportFolder() }.actionButton()
                                }
                            }
                            if state.exportFolderUnavailable {
                                SupportingText("Папка недоступна. Автоэкспорт приостановлен. Выберите папку заново, чтобы его возобновить.")
                            } else {
                                SupportingText("После расшифровки и последующих правок файл обновляется автоматически. В него входят текст, участники и временные метки. Аудио остаётся в библиотеке.")
                            }
                        }.onAppear { state.refreshExportFolderAccess() }
                        } right: {
                            VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                        block("Если папка синхронизируется", "Dropbox, iCloud или другой сервис могут отправлять её содержимое в облако") { SupportingText("Выбор такой папки разрешает выгрузку текстов через приложение синхронизации. Это отдельно от локального распознавания.") }

                            }
                        }
                    case "Хранилище":
                        StorageSettings()
                    case "MCP":
                        columns {
                        block("Доступ к встречам через MCP", "Локальный сервер даёт доступ только для чтения и работает без сетевого порта") {
                            screenToggle("Разрешить MCP читать библиотеку", isOn: $state.preferences.mcpEnabled).onChange(of: state.preferences.mcpEnabled) { state.saveMCPSetting() }
                            SupportingText("Подключённый клиент сможет находить реплики с контекстом и читать расшифровки. Ссылки на источники открывают нужный фрагмент в Pisa. Если клиент использует облачную модель, прочитанный текст может уйти к ней. Аудиофайлы и изменение библиотеки через MCP недоступны.")
                        }
                        } right: {
                            VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                        block("Подключение", "Добавьте этот локальный сервер в настройки вашего клиента:") {
                            screenText(verbatim: "[mcp_servers.pisa]\ncommand = \"\(state.mcpPath)\"")
                                .textStyle(PisaDesign.Typography.code)
                                .foregroundStyle(PisaDesign.Colors.paper)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(PisaDesign.Spacing.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(PisaDesign.Colors.ink, in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                            screenButton("Скопировать конфигурацию") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("[mcp_servers.pisa]\ncommand = \"\(state.mcpPath)\"", forType: .string) }.actionButton()
                            SupportingText("Доступны встречи, папки, поиск реплик и сведения о полноте расшифровки. Выключатель отзывает доступ и у уже запущенного клиента.")
                        }
                            }
                            .disabled(!state.preferences.mcpEnabled)
                            .opacity(state.preferences.mcpEnabled ? 1 : 0.45)
                        }
                    default:
                        block("Обновления Pisa", "Новые версии загружаются с GitHub") {
                            screenToggle("Устанавливать обновления автоматически", isOn: Binding(
                                get: { updates.installsAutomatically },
                                set: { updates.setAutomaticInstallation($0) }
                            )).disabled(!updates.isReady)
                            SupportingText("Если выключить, Pisa сообщит о новой версии и предложит установить её вручную")
                            screenButton("Проверить обновления…") { updates.check() }
                                .actionButton().disabled(!updates.canCheck)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                    }
                }.padding(.vertical, PisaDesign.Spacing.compact)
            }.id(section)
            }
            HStack(spacing: PisaDesign.Spacing.inline) {
                Image(nsImage: BrandMark.headerIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                screenText("Pisa \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .textStyle(PisaDesign.Typography.footnote)
                    .foregroundStyle(Color.mutedInk)
                Spacer()
                screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction)
            }
        }.dialogContent().frame(width: 900, height: 700)
            .background(SettingsInitialFocus().allowsHitTesting(false))
            .background(ClickToUnfocus())
    }
    private var modelSettings: some View {
        columns {
            FormSection("Qwen3-ASR", subtitle: "Локальное распознавание русской речи на Apple Silicon") {
                screenLabel(
                    state.modelReady ? "Модель готова" : "Модели ещё не установлены",
                    systemImage: state.modelReady ? "checkmark.circle.fill" : "externaldrive"
                ).foregroundStyle(Color.moss)
                if let url = state.modelURL() {
                    screenText(verbatim: url.path).textStyle(PisaDesign.Typography.code)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.mutedInk).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                    screenButton(state.modelReady ? "Проверить и установить модели" : "Загрузить модели") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            state.modelSetup.check()
                            state.modelSetup.presented = true
                        }
                    }.actionButton()
                    screenButton("Выбрать папку модели…") { state.chooseModel() }.actionButton()
                }
                SupportingText("Pisa загрузит проверенные модели речи и участников с Hugging Face — около 3 ГБ. Можно также выбрать свою папку с моделью Qwen3-ASR в формате MLX.")
            }
        } right: {
            FormSection("Производительность") {
                screenToggle("Тихая обработка", isOn: Binding(
                    get: { state.preferences.usesQuietProcessing },
                    set: { state.preferences.quietProcessing = $0; state.savePreferences() }
                ))
                SupportingText("Меньше параллельной нагрузки и паузы между фрагментами. Расшифровка займёт больше времени.")
            }
        }
    }
    private var recordingSettings: some View {
        HStack(alignment: .top, spacing: PisaDesign.Spacing.section) {
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                block("Источники звука", "Микрофон и системный звук") {
                    SupportingText("Начните запись заранее, затем откройте встречу в любом приложении или браузере. Записываются и другие звуки Mac.")
                }
                block("Автозапись", "Экспериментальная функция") {
                    screenToggle("Автоматический старт и стоп", isOn: Binding(get: { state.preferences.automaticRecording }, set: { state.setAutomatic($0) }))
                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                        screenLabel("Старт — через 3 секунды", systemImage: "record.circle")
                        screenLabel("Стоп — через 45 секунд без микрофона", systemImage: "stop.circle").fixedSize(horizontal: false, vertical: true)
                    }.textStyle(PisaDesign.Typography.body).fixedSize(horizontal: false, vertical: true)
                    SupportingText("Ориентируется на использование микрофона другими приложениями, а не на громкость звука")
                    // Keep the disclosure and its text together so the block's row spacing
                    // cannot add a second gap between the heading and its content.
                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                        Button { showRecordingDetails.toggle() } label: {
                            HStack(spacing: PisaDesign.Spacing.inline) {
                                Image(systemName: showRecordingDetails ? "chevron.down" : "chevron.right").font(PisaDesign.Typography.Icon.disclosure).frame(width: 12)
                                screenText("Как работает и ограничения")
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.shapeAwarePlainButton().foregroundStyle(Color.moss)
                            .accessibilityValue(showRecordingDetails ? "Развёрнуто" : "Свёрнуто")
                        if showRecordingDetails {
                            SupportingText("Диктовка и тест микрофона тоже могут запустить запись. Звонки без доступа к микрофону не определяются. Отключение микрофона в приложении может вызвать автостоп. Если вы начали запись вручную до встречи, автостоп включится только после обнаружения звонка.")
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                block("Разрешения macOS", "Нужны для записи вашего голоса и собеседников") {
                    Button { NSWorkspace.shared.open(CapturePermission.microphone.settingsURL) } label: { screenLabel("Микрофон", systemImage: "mic") }.actionButton()
                    Button { NSWorkspace.shared.open(CapturePermission.systemAudio.settingsURL) } label: { screenLabel("Системный звук", systemImage: "speaker.wave.2") }.actionButton()
                }.labelStyle(AlignedIconLabelStyle())
                block("Фоновая расшифровка", "Черновик во время звонка") {
                    screenToggle("Расшифровывать во время записи", isOn: Binding(get: { state.preferences.usesBackgroundTranscription }, set: { state.setBackgroundTranscription($0) }))
                    SupportingText("После остановки обрабатывается оставшийся хвост. Пауза распознавания не останавливает запись.")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func columns<Left: View, Right: View>(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        HStack(alignment: .top, spacing: PisaDesign.Spacing.section) {
            left().frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1)
            right().frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func block<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        FormSection(title, subtitle: subtitle, content: content)
    }
}

private struct StorageSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var weeks = 2
    @State private var usage: LibraryStorageUsage?
    @State private var scanFailed = false
    @State private var refreshID = 0
    @State private var confirmation: AudioCleanupPlan?
    @State private var result: AudioCleanupResult?

    private var cleanupPlan: AudioCleanupPlan? {
        guard let usage, let cutoff = Calendar.current.date(byAdding: .day, value: -7 * weeks, to: .now) else { return nil }
        return state.audioCleanupPlan(olderThan: cutoff, usage: usage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            FormSection("Место на Mac") {
                if let usage {
                    let recordings = state.meetings.count { meeting in
                        meeting.audioFiles.contains { usage.audioFiles[$0] != nil }
                    }
                    storageRow("Аудиозаписи · \(meetingCount(recordings))", bytes: usage.audioBytes)
                    storageRow("Расшифровки и данные встреч", bytes: usage.meetingBytes)
                    storageRow("Модели и другие файлы Pisa", bytes: usage.otherBytes)
                    Divider()
                    storageRow("Всего", bytes: usage.totalBytes)
                } else if scanFailed {
                    SupportingText("Не удалось посчитать размер файлов")
                    screenButton("Повторить") { refreshID += 1 }.actionButton()
                } else {
                    SupportingText("Считаем размер файлов…")
                }
            }
            FormSection("Очистка аудиозаписей", subtitle: "Удаляется звук обработанных встреч. Расшифровки и заметки остаются.") {
                let plan = cleanupPlan
                HStack(spacing: PisaDesign.Spacing.related) {
                    NativeActionMenu {
                        [1, 2, 4, 8, 12].map { value in
                            NativeActionMenuItem(ageLabel(value)) {
                                weeks = value
                                result = nil
                            }
                        }
                    } label: {
                        HStack(spacing: PisaDesign.Spacing.inline) {
                            screenText(ageLabel(weeks))
                            Image(systemName: "chevron.down").font(PisaDesign.Typography.Icon.disclosure)
                        }
                    }
                    .actionButton()
                    .accessibilityLabel("Возраст аудиозаписей")
                    .accessibilityValue(typographicText(ageLabel(weeks)))

                    screenButton("Освободить место") { confirmation = cleanupPlan }
                        .actionButton(.primary)
                        .disabled(plan?.filesByMeeting.isEmpty != false)
                }
                if let result {
                    if result.failedMeetings > 0 {
                        SupportingText("Не удалось полностью очистить аудио. Встреч с ошибками: \(result.failedMeetings). Освобождено \(storageSize(result.bytes)).")
                    } else if result.meetings > 0 {
                        SupportingText("Освобождено \(storageSize(result.bytes)). Встреч очищено: \(result.meetings).")
                    } else {
                        SupportingText("Подходящих аудиозаписей больше нет")
                    }
                } else if let plan {
                    if plan.filesByMeeting.isEmpty {
                        SupportingText("Подходящих аудиозаписей нет")
                    } else {
                        SupportingText("К удалению: \(meetingCount(plan.filesByMeeting.count)) · \(storageSize(plan.bytes))")
                    }
                }
            }
        }
        .sheet(item: $confirmation) { plan in
            ConfirmationSheet(
                title: "Удалить старые аудиозаписи?",
                message: "К удалению: \(meetingCount(plan.filesByMeeting.count)) · \(storageSize(plan.bytes)). Аудио удалится навсегда. Расшифровки и заметки останутся.",
                actionTitle: "Удалить аудио",
                role: .destructive
            ) {
                guard let usage else { return }
                result = state.cleanUpAudio(plan, usage: usage)
                refreshID += 1
            }
        }
        .task(id: refreshID) { await refreshStorage() }
    }

    private func storageRow(_ label: String, bytes: Int64) -> some View {
        HStack(spacing: PisaDesign.Spacing.related) {
            screenText(label)
            Spacer()
            screenText(storageSize(bytes)).fixedSize()
        }.textStyle(PisaDesign.Typography.body)
    }

    private func refreshStorage() async {
        usage = nil
        scanFailed = false
        let library = state.library
        let scan = Task.detached(priority: .utility) { try library.storageUsage() }
        let scanned = try? await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
        guard !Task.isCancelled else { return }
        usage = scanned
        scanFailed = scanned == nil
    }

    private func ageLabel(_ weeks: Int) -> String {
        "Старше \(weeks)\u{00a0}\(weeks == 1 ? "недели" : "недель")"
    }

    private func meetingCount(_ count: Int) -> String {
        let noun: String
        switch (count % 10, count % 100) {
        case (_, 11...14): noun = "встреч"
        case (1, _): noun = "встреча"
        case (2...4, _): noun = "встречи"
        default: noun = "встреч"
        }
        return "\(count)\u{00a0}\(noun)"
    }

    private func storageSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 Б" }
        let unit = bytes >= 1_000_000_000 ? (1_000_000_000.0, "ГБ")
            : bytes >= 1_000_000 ? (1_000_000.0, "МБ") : (1_000.0, "КБ")
        let amount = max(0.1, Double(bytes) / unit.0)
        let formatted = amount.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "ru_RU")))
        return "\(formatted)\u{00a0}\(unit.1)"
    }
}

// Clear only the initial sheet focus. Keyboard Tab navigation remains available.
private struct SettingsInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class FocusView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
        }
    }
}

import SwiftUI
import AppKit

private struct SelectableVoiceName: NSViewRepresentable {
    let name: String
    @Environment(\.appTextScale) private var textScale

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: name)
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.focusRingType = .none
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = name
        field.font = .systemFont(ofSize: PisaDesign.Typography.bodyStrong.size * textScale, weight: .semibold)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.intrinsicContentSize.width
        return nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
    }
}

struct VoiceManager: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale
    let meetingID: UUID
    @State private var selected: UUID?
    @State private var name = ""
    @State private var nameFocused = false
    @State private var showSuggestions = false
    @State private var selectedSuggestion: Int?
    @State private var lastChosenName: String?
    @State private var allMatching = true
    @State private var remember = true
    @State private var assignment: Task<Void, Never>?
    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }
    private var sample: TranscriptSegment? {
        meeting?.segments.first { $0.id == selected && $0.speaker != TranscriptSegment.unidentifiedSpeaker }
    }
    private var canApplyName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var suggestions: [String] {
        guard showSuggestions else { return [] }
        return voiceNameSuggestions(query: name, meetingNames: meeting?.segments.map(\.speaker) ?? [], savedNames: state.voiceProfiles.map(\.name))
    }
    private var automaticSample: TranscriptSegment? {
        guard let meeting, let selected else { return nil }
        return state.voiceSample(for: selected, in: meeting)
    }
    private func select(_ segment: TranscriptSegment) {
        showSuggestions = false
        selectedSuggestion = nil
        name = voiceNameForSelection(currentSpeaker: sample?.speaker, currentName: name, segment: segment)
        lastChosenName = name
        selected = segment.id
    }

    private func chooseSuggestion(_ suggestion: String) {
        lastChosenName = suggestion
        name = suggestion
        showSuggestions = false
        selectedSuggestion = nil
        nameFocused = true
    }

    private func dismissSuggestions() -> Bool {
        guard nameFocused, !suggestions.isEmpty else { return false }
        showSuggestions = false
        selectedSuggestion = nil
        return true
    }

    private func applyName() {
        guard assignment == nil, canApplyName, let selected else { return }
        showSuggestions = false
        selectedSuggestion = nil
        let name = name
        let allMatching = allMatching
        let remember = remember && automaticSample != nil
        assignment = Task {
            await state.assignVoice(meetingID: meetingID, segmentID: selected, name: name,
                                    allMatching: allMatching, remember: remember)
            assignment = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            HStack(spacing: PisaDesign.Spacing.inline) { SectionHeading("Голоса встречи", subtitle: "Послушайте фрагмент, назначьте имя и сохраните образец для следующих встреч", style: .dialog); Spacer(); screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction) }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                        if let meeting {
                            ForEach(voiceGroupAnchors(in: meeting.segments)) { anchor in
                                LazyVStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                                    SelectableVoiceName(name: anchor.speaker)
                                    ForEach(voiceSamples(for: anchor.speaker, in: meeting.segments)) { segment in
                                        fragmentCard(segment, in: meeting)
                                    }
                                }
                            }
                        }
                    }.padding(.trailing, PisaDesign.Spacing.section)
                }.frame(minWidth: 340)
                ScrollView {
                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                        if let sample {
                            let automaticSample = automaticSample
                            VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                                SectionHeading("Кто говорит?", subtitle: "Фрагмент \(timecode(sample.start)) · сейчас «\(sample.speaker)»")
                                nameEditor
                            }
                            VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                                screenToggle("Все реплики «\(sample.speaker)»", isOn: $allMatching)
                                screenToggle("Запомнить голос для будущих встреч", isOn: $remember)
                                    .disabled(automaticSample == nil)
                                if let automaticSample, remember, let meeting {
                                    screenButton("Послушать образец · \(timecode(automaticSample.start))–\(timecode(automaticSample.end))") {
                                        state.preview(automaticSample, in: meeting)
                                    }.actionButton().disabled(state.recording || state.demo)
                                    screenText("Образец берётся из выбранного фрагмента, без отмеченных наложений других голосов. Он и голосовой слепок останутся после удаления аудио встречи.").textStyle(PisaDesign.Typography.caption).foregroundStyle(Color.mutedInk)
                                } else if automaticSample == nil {
                                    screenText("В выбранном фрагменте нет 2 секунд доступного аудио без отмеченных наложений. Имя можно применить без запоминания голоса.").textStyle(PisaDesign.Typography.caption).foregroundStyle(Color.mutedInk)
                                }
                                screenButton(assignment == nil ? "Применить имя" : "Сохраняем…", action: applyName)
                                    .actionButton(.primary).disabled(!canApplyName || assignment != nil)
                            }
                        } else { screenText("Выберите фрагмент слева").foregroundStyle(Color.mutedInk) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.id(selected).textStyle(PisaDesign.Typography.secondary).padding(.leading, PisaDesign.Spacing.section).frame(width: 350 * max(1, textScale))
            }
        }.dialogContent().frame(width: 940, height: 660)
            .background(ClickToUnfocus(onEscape: dismissSuggestions))
            .onDisappear { assignment?.cancel(); state.stopPlayback() }
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
            FormTextField(title: "Имя участника", text: $name, isFocused: $nameFocused,
                          onSubmit: submitName, onCommand: handleNameCommand)
                .onChange(of: name) { _, newName in
                    showSuggestions = nameFocused && newName != lastChosenName
                    selectedSuggestion = nil
                }
                .measuredForInterfaceTest(.voiceName)
            let matchingNames = suggestions
            if !matchingNames.isEmpty {
                suggestionList(matchingNames)
            }
        }
    }

    private func submitName() {
        let matches = suggestions
        if let index = selectedSuggestion, matches.indices.contains(index) {
            chooseSuggestion(matches[index])
        } else {
            applyName()
        }
    }

    private func handleNameCommand(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            let count = suggestions.count
            guard count > 0 else { return false }
            selectedSuggestion = min((selectedSuggestion ?? -1) + 1, count - 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard let index = selectedSuggestion, !suggestions.isEmpty else { return false }
            selectedSuggestion = max(index - 1, 0)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            return dismissSuggestions()
        default:
            return false
        }
    }

    private func suggestionList(_ suggestions: [String]) -> some View {
        let shape = RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.none) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                        VoiceSuggestionRow(name: suggestion, selected: index == selectedSuggestion) {
                            chooseSuggestion(suggestion)
                        }
                        .id(index)
                    }
                }
            }
            .frame(height: min(CGFloat(suggestions.count) * PisaDesign.Metrics.regularHeight, PisaDesign.Metrics.editorHeight))
            .padding(PisaDesign.Spacing.compact)
            .background {
                shape.fill(Color.paper)
                    .shadow(color: Color.ink.opacity(0.12), radius: PisaDesign.Spacing.inline, y: PisaDesign.Spacing.hairline)
            }
            .overlay {
                shape.strokeBorder(PisaDesign.Colors.secondaryAction, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onChange(of: selectedSuggestion) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .background(SlimScrollbars().allowsHitTesting(false))
    }

    private func fragmentCard(_ segment: TranscriptSegment, in meeting: Meeting) -> some View {
        let canPlay = !meeting.audioFiles.isEmpty && !state.recording && !state.demo
        let isPlaying = state.playingSegmentID == segment.id
        let isSelected = selected == segment.id
        let shape = RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)

        return Button {
            select(segment)
            if canPlay { state.preview(segment, in: meeting) }
        } label: {
            HStack(alignment: .top, spacing: PisaDesign.Spacing.related) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(PisaDesign.Typography.Icon.featured)
                    .foregroundStyle(canPlay ? Color.moss : Color.disabledInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                    screenText("\(timecode(segment.start)) · \(timecode(segment.end - segment.start))")
                        .textStyle(PisaDesign.Typography.footnote)
                    screenText(segment.text).textStyle(PisaDesign.Typography.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(PisaDesign.Spacing.related)
            .background(isSelected ? PisaDesign.Colors.selection : PisaDesign.Colors.secondary, in: shape)
            .contentShape(shape)
        }
        .shapeAwarePlainButton()
        .measuredForInterfaceTest(.voiceSample(segment.id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .screenHelp(canPlay ? (isPlaying ? "Остановить фрагмент" : "Прослушать до 8 секунд") : "Выбрать фрагмент")
    }
}

private struct VoiceSuggestionRow: View {
    let name: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    private var fill: Color {
        if selected { return Color.moss.opacity(0.14) }
        return hovered ? PisaDesign.Colors.secondaryHover : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)
        Button(action: choose) {
            screenText(name)
                .lineLimit(1)
                .padding(.horizontal, PisaDesign.Spacing.inline)
                .frame(maxWidth: .infinity, minHeight: PisaDesign.Metrics.regularHeight, alignment: .leading)
                .background(fill, in: shape)
                .contentShape(shape)
        }
        .shapeAwarePlainButton()
        .onHover { hovered = $0 }
        .screenHelp(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

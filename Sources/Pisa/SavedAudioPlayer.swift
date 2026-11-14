import AVFoundation
import Combine
import SwiftUI

struct SavedAudioPlayer: View {
    @EnvironmentObject private var state: AppState
    let sources: [RecordingAudioSource]
    var isInline = false

    @State private var item: AVPlayerItem?
    @State private var duration: TimeInterval = 0
    @State private var position: TimeInterval = 0
    @State private var isPlaying = false
    @State private var playbackSpeed: PlaybackSpeed = .normal
    @State private var playbackReported = false
    @State private var peaks: [Float] = []
    @State private var timeObserver: Any?
    @GestureState private var dragPosition: TimeInterval?

    private var player: AVPlayer { state.savedAudioPlayer }
    private var shownPosition: TimeInterval { dragPosition ?? position }

    var body: some View {
        VStack(spacing: PisaDesign.Spacing.none) {
            if item != nil {
                VStack(spacing: PisaDesign.Spacing.inline) {
                    timeline
                    HStack(spacing: PisaDesign.Spacing.inline) {
                        HStack(spacing: PisaDesign.Spacing.section) {
                            HStack(spacing: PisaDesign.Spacing.inline) {
                                let playLabel = isPlaying ? "Пауза" : "Воспроизвести"
                                Button(action: togglePlayback) {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .textStyle(PisaDesign.Typography.detailMedium)
                                        .frame(width: PisaDesign.Metrics.labelIconWidth)
                                }
                                .actionButton(size: .small)
                                .accessibilityLabel(playLabel)
                                .screenHelp(playLabel)
                                skipButton("Назад на 15 секунд", icon: "gobackward.15", seconds: -15)
                                skipButton("Вперёд на 15 секунд", icon: "goforward.15", seconds: 15)
                            }
                            speedSelector
                        }
                        Spacer(minLength: PisaDesign.Spacing.inline)
                        HStack(spacing: PisaDesign.Spacing.compact) {
                            screenText(verbatim: recordingTimecode(shownPosition)).foregroundStyle(Color.ink)
                            screenText("/")
                            screenText(verbatim: recordingTimecode(duration))
                        }
                        .textStyle(PisaDesign.Typography.code)
                        .foregroundStyle(Color.mutedInk)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, isInline ? PisaDesign.Spacing.none : PisaDesign.Spacing.related)
                .disabled(state.recording || state.starting)
                if !isInline { Divider() }
            }
        }
        .task(id: sources) { await prepare() }
        .onDisappear(perform: reset)
        .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
            isPlaying = item != nil && player.currentItem === item && status != .paused
            if status == .playing, isPlaying, !playbackReported {
                playbackReported = true
                Analytics.feature(.recordingPlayed)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main)) { notification in
            if let item, notification.object as? AVPlayerItem === item { position = duration }
        }
    }

    private var speedSelector: some View {
        HStack(spacing: PisaDesign.Spacing.none) {
            ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                Button {
                    guard speed != playbackSpeed else { return }
                    playbackSpeed = speed
                    Analytics.playbackSpeedChanged(speed)
                    if player.currentItem === item && player.timeControlStatus != .paused {
                        player.rate = speed.rate
                    }
                } label: {
                    screenText(verbatim: speed.rawValue)
                        .textStyle(PisaDesign.Typography.detailMedium)
                        .padding(.horizontal, PisaDesign.Spacing.inline)
                        .frame(minHeight: PisaDesign.Metrics.smallHeight)
                        .background(playbackSpeed == speed ? PisaDesign.Colors.secondaryAction : .clear,
                                    in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                }
                .shapeAwarePlainButton()
                .accessibilityLabel("Скорость воспроизведения \(speed.rawValue)")
                .accessibilityAddTraits(playbackSpeed == speed ? .isSelected : [])
            }
        }
    }

    private var timeline: some View {
        let waveform = peaks
        let fraction = shownPosition / duration
        return GeometryReader { geometry in
            Canvas { context, size in
                Self.drawWaveform(context, size: size, peaks: waveform, fraction: fraction)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragPosition) { value, position, _ in
                    position = time(at: value.location.x, width: geometry.size.width)
                }
                .onEnded { seek(to: time(at: $0.location.x, width: geometry.size.width)) })
        }
        .frame(height: 56)
        .measuredForInterfaceTest(.waveform)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { seek(to: position - 5); return .handled }
        .onKeyPress(.rightArrow) { seek(to: position + 5); return .handled }
        .pointingHandCursor()
        .accessibilityRepresentation {
            Slider(value: Binding(get: { shownPosition }, set: seek(to:)), in: 0...duration) {
                screenText("Позиция воспроизведения")
            }
            .accessibilityValue("\(recordingTimecode(shownPosition)) из \(recordingTimecode(duration))")
        }
    }

    private func skipButton(_ label: String, icon: String, seconds: TimeInterval) -> some View {
        Button { seek(to: position + seconds) } label: {
            Image(systemName: icon)
                .textStyle(PisaDesign.Typography.detailMedium)
                .frame(width: PisaDesign.Metrics.smallHeight, height: PisaDesign.Metrics.smallHeight)
        }
        .shapeAwarePlainButton()
        .accessibilityLabel(label)
        .screenHelp(label)
    }

    private static func drawWaveform(_ context: GraphicsContext, size: CGSize, peaks: [Float], fraction: Double) {
        guard size.width > 0 else { return }
        let center = size.height / 2
        let cursor = min(size.width - 1, max(1, size.width * fraction))
        var played = Path()
        var remaining = Path()
        if peaks.isEmpty {
            played.move(to: CGPoint(x: 0, y: center))
            played.addLine(to: CGPoint(x: cursor, y: center))
            remaining.move(to: CGPoint(x: cursor, y: center))
            remaining.addLine(to: CGPoint(x: size.width, y: center))
        } else {
            let count = min(peaks.count, max(1, Int(size.width / 3)))
            let step = size.width / CGFloat(count)
            for index in 0..<count {
                let bins = (index * peaks.count / count)..<((index + 1) * peaks.count / count)
                let peak = CGFloat(peaks[bins].max() ?? 0)
                let halfHeight = max(1, peak * (center - 5))
                let x = (CGFloat(index) + 0.5) * step
                let start = CGPoint(x: x, y: center - halfHeight)
                let end = CGPoint(x: x, y: center + halfHeight)
                if x <= cursor && fraction > 0 {
                    played.move(to: start)
                    played.addLine(to: end)
                } else {
                    remaining.move(to: start)
                    remaining.addLine(to: end)
                }
            }
        }
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
        context.stroke(remaining, with: .color(Color.mutedInk.opacity(0.36)), style: style)
        context.stroke(played, with: .color(Color.moss), style: style)
        var head = Path()
        head.move(to: CGPoint(x: cursor, y: 2))
        head.addLine(to: CGPoint(x: cursor, y: size.height - 2))
        context.stroke(head, with: .color(Color.moss), style: style)
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(1, max(0, x / width)) * duration
    }

    private func togglePlayback() {
        guard let item, player.currentItem === item, !state.recording, !state.starting else { return }
        if player.timeControlStatus != .paused {
            player.pause()
        } else {
            state.stopPlayback()
            if position >= duration { seek(to: 0) }
            player.playImmediately(atRate: playbackSpeed.rate)
        }
    }

    private func seek(to time: TimeInterval) {
        guard let item, player.currentItem === item, !state.recording, !state.starting else { return }
        position = min(duration, max(0, time))
        player.seek(to: CMTime(seconds: position, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func prepare() async {
        reset()
        guard let recording = await MeetingAudioExport.preparePlayback(sources), !Task.isCancelled else { return }
        let preparedItem = AVPlayerItem(asset: recording.asset)
        duration = recording.duration
        item = preparedItem
        player.replaceCurrentItem(with: preparedItem)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
            MainActor.assumeIsolated {
                guard player.currentItem === preparedItem, time.seconds.isFinite else { return }
                position = min(duration, max(0, time.seconds))
            }
        }
        let waveform = await AudioFileWaveform.load(from: recording.sources, duration: recording.duration)
        if !Task.isCancelled { peaks = waveform }
    }

    private func reset() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let item, player.currentItem === item {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        item = nil
        position = 0
        isPlaying = false
        playbackSpeed = .normal
        playbackReported = false
        peaks = []
    }
}

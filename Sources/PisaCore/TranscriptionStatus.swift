import Foundation

public enum TranscriptionStatus {
    public static func title(fraction: Double?, roundsDown: Bool = false) -> String {
        guard let fraction, fraction.isFinite else { return "Расшифровываю аудио" }
        let percent = (min(max(fraction, 0), 1) * 100).rounded(roundsDown ? .down : .toNearestOrEven)
        if percent < 20 { return "Начинаю расшифровку" }
        if percent < 80 { return "Расшифровываю аудио" }
        return "Завершаю расшифровку"
    }
}

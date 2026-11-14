import XCTest
@testable import PisaCore

final class TranscriptionStatusTests: XCTestCase {
    func testStatusFollowsDisplayedProgress() {
        XCTAssertEqual(TranscriptionStatus.title(fraction: nil), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: .nan), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.04), "Начинаю расшифровку")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.049, roundsDown: true), "Начинаю расшифровку")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.05), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.06), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.8), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.809, roundsDown: true), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.81), "Завершаю расшифровку")
    }
}

import XCTest
@testable import PisaCore

final class TranscriptionStatusTests: XCTestCase {
    func testStatusFollowsDisplayedProgress() {
        XCTAssertEqual(TranscriptionStatus.title(fraction: nil), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: .nan), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.06), "Начинаю расшифровку")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.195), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.199, roundsDown: true), "Начинаю расшифровку")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.2), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.799, roundsDown: true), "Расшифровываю аудио")
        XCTAssertEqual(TranscriptionStatus.title(fraction: 0.8), "Завершаю расшифровку")
    }
}

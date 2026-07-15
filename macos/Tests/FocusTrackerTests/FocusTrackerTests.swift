import Foundation
import XCTest
@testable import FocusTracker

final class ConfigTests: XCTestCase {
    func testLegacyConfigUsesCompatibleDefaults() throws {
        let data = Data(#"{"supabaseUrl":"https://example.invalid","apiKey":"public","categories":["AI"]}"#.utf8)

        let config = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(config.storageBackend, .firebase)
        XCTAssertEqual(config.supabaseUrl, "https://example.invalid")
        XCTAssertEqual(config.apiKey, "public")
        XCTAssertEqual(config.device, "mac")
        XCTAssertEqual(config.sessionMinutes, 30)
    }

    func testConfigRoundTripPreservesSettings() throws {
        let expected = Config(storageBackend: .local,
                              supabaseUrl: "",
                              apiKey: "",
                              device: "test-mac",
                              sessionMinutes: 45)

        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(decoded.storageBackend, .local)
        XCTAssertEqual(decoded.device, "test-mac")
        XCTAssertEqual(decoded.sessionMinutes, 45)
    }
}

final class SessionDescriptionCodecTests: XCTestCase {
    func testStructuredDescriptionRoundTrip() {
        let encoded = SessionDescriptionCodec.encode(
            sessionNames: ["Claude YouTube Channel", "OpenAI YouTube Channel"],
            note: "Compared editing workflows.\nSaved three ideas."
        )

        let decoded = SessionDescriptionCodec.decode(encoded)

        XCTAssertEqual(decoded.sessionNames,
                       ["Claude YouTube Channel", "OpenAI YouTube Channel"])
        XCTAssertEqual(decoded.note, "Compared editing workflows.\nSaved three ideas.")
    }

    func testLegacyDescriptionBecomesSessionNames() {
        let decoded = SessionDescriptionCodec.decode("Claude | OpenAI | Google Cloud Tech")

        XCTAssertEqual(decoded.sessionNames, ["Claude", "OpenAI", "Google Cloud Tech"])
        XCTAssertEqual(decoded.note, "")
    }

    func testEmptyValuesEncodeToEmptyDescription() {
        XCTAssertEqual(SessionDescriptionCodec.encode(sessionNames: [], note: ""), "")
    }
}

final class SessionRecordTests: XCTestCase {
    func testDurationRoundsToNearestMinuteAndPayloadContainsSessionData() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = SessionRecord(start: start,
                                   end: start.addingTimeInterval(90),
                                   category: "AI",
                                   sessionNames: ["Claude"],
                                   description: "Research note")

        XCTAssertEqual(record.durationMin, 2)

        let payload = record.payload(device: "test-mac")
        XCTAssertEqual(payload["category"] as? String, "AI")
        XCTAssertEqual(payload["session_names"] as? [String], ["Claude"])
        XCTAssertEqual(payload["description"] as? String, "Research note")
        XCTAssertEqual(payload["duration_min"] as? Int, 2)
        XCTAssertEqual(payload["device"] as? String, "test-mac")
        XCTAssertNotNil(payload["started_at"] as? String)
        XCTAssertNotNil(payload["ended_at"] as? String)
    }

    func testNegativeDurationIsClampedToZero() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = SessionRecord(start: start,
                                   end: start.addingTimeInterval(-60),
                                   category: "Work",
                                   sessionNames: [],
                                   description: "")

        XCTAssertEqual(record.durationMin, 0)
    }

    func testOlderRecordWithoutNewFieldsStillDecodes() throws {
        let data = Data(#"{"start":0,"end":1800,"category":"Reading"}"#.utf8)

        let record = try JSONDecoder().decode(SessionRecord.self, from: data)

        XCTAssertEqual(record.category, "Reading")
        XCTAssertEqual(record.sessionNames, [])
        XCTAssertEqual(record.description, "")
        XCTAssertEqual(record.durationMin, 30)
    }
}

final class FocusTimerModelTests: XCTestCase {
    func testDurationClampsAndCannotChangeDuringActiveSession() async {
        await MainActor.run {
            let timer = FocusTimerModel(defaultMinutes: 0)
            XCTAssertEqual(timer.durationMinutes, 1)
            XCTAssertEqual(timer.remainingSeconds, 60)

            timer.setDurationMinutes(900)
            XCTAssertEqual(timer.durationMinutes, 720)

            timer.category = "Work"
            timer.startFromWindow()
            timer.setDurationMinutes(25)
            XCTAssertEqual(timer.durationMinutes, 720)

            timer.cancel()
            XCTAssertEqual(timer.phase, .idle)
            XCTAssertEqual(timer.remainingSeconds, 720 * 60)
        }
    }

    func testWindowTimerTransitionsAndProducesTrimmedCompletion() async {
        await MainActor.run {
            let timer = FocusTimerModel(defaultMinutes: 30)
            var completion: FocusTimerCompletion?
            timer.onComplete = { completion = $0 }

            timer.category = "  AI  "
            timer.sessionNames = ["Claude", "OpenAI"]
            timer.note = "  Research summary  "
            timer.startFromWindow()
            XCTAssertEqual(timer.phase, .running)

            timer.pause()
            XCTAssertEqual(timer.phase, .paused)
            timer.startOrResume()
            XCTAssertEqual(timer.phase, .running)
            timer.finishNow()

            XCTAssertEqual(timer.phase, .idle)
            XCTAssertEqual(timer.statusMessage, "Session saved")
            XCTAssertEqual(completion?.category, "AI")
            XCTAssertEqual(completion?.sessionNames, ["Claude", "OpenAI"])
            XCTAssertEqual(completion?.note, "Research summary")
            XCTAssertEqual(completion?.elapsedSeconds, 0)
            XCTAssertEqual(completion?.collectDetailsAfterTimer, false)
            XCTAssertEqual(completion?.reachedZero, false)
        }
    }

    func testMenuTimerResetsDetailsAndRequestsThemOnCompletion() async {
        await MainActor.run {
            let timer = FocusTimerModel(defaultMinutes: 25)
            timer.sessionNames = ["Old session"]
            timer.note = "Old note"
            var completion: FocusTimerCompletion?
            timer.onComplete = { completion = $0 }

            timer.startFromMenu(category: "AI")
            XCTAssertEqual(timer.sessionNames, [])
            XCTAssertEqual(timer.note, "")
            timer.finishNow()

            XCTAssertEqual(completion?.category, "AI")
            XCTAssertEqual(completion?.collectDetailsAfterTimer, true)
        }
    }

    func testBlankCategoryDoesNotStartTimer() async {
        await MainActor.run {
            let timer = FocusTimerModel(defaultMinutes: 30)
            timer.category = "  \n "

            timer.startFromWindow()

            XCTAssertEqual(timer.phase, .idle)
            XCTAssertFalse(timer.isActive)
        }
    }
}

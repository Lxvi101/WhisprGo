import Foundation
import XCTest
@testable import WhisprGo

@MainActor
final class ProLatencyTests: XCTestCase {
    private func input(
        _ transcript: String = "um Tuesday",
        context: AccessibilityContextSnapshot? = nil,
        profile: String = ""
    ) -> ProCleanupDraft.Input {
        .init(transcript: transcript, context: context, profilePrompt: profile)
    }

    func testMatchingDraftReusesOneCleanupRequest() async throws {
        let draft = ProCleanupDraft()
        let calls = CallCounter()
        let value = input()
        draft.start(value) {
            await calls.increment()
            return "Tuesday."
        }
        // Duplicate previews during the same pause must not send again.
        draft.start(value) {
            XCTFail("Duplicate draft requested cleanup")
            return "duplicate"
        }
        let result = try await draft.resolve(value) {
            XCTFail("Matching final transcript requested cleanup again")
            return "unexpected"
        }
        XCTAssertEqual(result.text, "Tuesday.")
        XCTAssertTrue(result.reused)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testChangedTranscriptProfileOrContextRejectsDraft() async throws {
        let context = AccessibilityContextSnapshot(
            applicationName: "Editor", bundleIdentifier: nil, windowTitle: nil,
            documentURL: nil, focusedRole: nil, textBeforeCursor: "Meeting: ",
            selectedText: "", textAfterCursor: "", nearbyText: ""
        )
        for finalInput in [
            input("Tuesday no actually Wednesday"),
            input(profile: "Use bullet points"),
            input(context: context),
        ] {
            let draft = ProCleanupDraft()
            draft.start(input()) { "Tuesday." }
            let result = try await draft.resolve(finalInput) { "fresh final text" }
            XCTAssertFalse(result.reused)
            XCTAssertEqual(result.text, "fresh final text")
        }
    }

    func testFailedDraftGetsNormalFinalAttempt() async throws {
        let draft = ProCleanupDraft()
        let value = input()
        draft.start(value) { throw URLError(.timedOut) }
        let result = try await draft.resolve(value) { "Tuesday." }
        XCTAssertFalse(result.reused)
        XCTAssertEqual(result.text, "Tuesday.")
    }

    func testFinalFailureIsNotHiddenByDraft() async {
        let draft = ProCleanupDraft()
        let value = input()
        draft.start(value) { throw URLError(.timedOut) }
        do {
            _ = try await draft.resolve(value) { throw URLError(.notConnectedToInternet) }
            XCTFail("Final failure should reach the raw-transcript fallback")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testCancelledRecordingCannotReuseItsDraft() async throws {
        let draft = ProCleanupDraft()
        draft.start(input()) { "stale" }
        draft.cancel()
        let result = try await draft.resolve(input()) { "new recording" }
        XCTAssertFalse(result.reused)
        XCTAssertEqual(result.text, "new recording")
    }

    func testCancellingFinalWaitCancelsSpeculativeRequestWithoutRetry() async {
        let draft = ProCleanupDraft()
        let value = input()
        let started = expectation(description: "Speculative cleanup started")
        let cancelled = expectation(description: "Speculative cleanup cancelled")
        draft.start(value) {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(10))
                return "unexpected"
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let final = Task {
            try await draft.resolve(value) {
                XCTFail("Cancelled dictation must not retry cleanup")
                return "unexpected"
            }
        }
        // Let resolve install its cancellation handler.
        await Task.yield()
        final.cancel()
        do {
            _ = try await final.value
            XCTFail("Cancelled dictation returned text")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // Also covers cancellation before resolve begins running.
        draft.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testReplacingDraftCancelsOldCleanup() async throws {
        let draft = ProCleanupDraft()
        let started = expectation(description: "Old draft started")
        let cancelled = expectation(description: "Old draft cancelled")
        draft.start(input()) {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(10))
                return "stale"
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let revised = input("Wednesday")
        draft.start(revised) { "Wednesday." }
        let result = try await draft.resolve(revised) { "unexpected" }
        XCTAssertEqual(result.text, "Wednesday.")
        XCTAssertTrue(result.reused)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testPauseDetectorRequiresSpeechAndDoesNotRepeatSamePause() {
        var detector = ProPauseDetector()
        detector.append(sampleCount: 1_000, rms: 0)
        XCTAssertFalse(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 1_000, rms: 0.02)
        XCTAssertFalse(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 449, rms: 0)
        XCTAssertFalse(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 1, rms: 0)
        XCTAssertTrue(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 4_000, rms: 0)
        XCTAssertFalse(detector.takePause(sampleRate: 1_000))
    }

    func testPauseDetectorBoundsFrequencyAndNumberOfDrafts() {
        var detector = ProPauseDetector()
        detector.append(sampleCount: 1_000, rms: 0.02)
        detector.append(sampleCount: 500, rms: 0)
        XCTAssertTrue(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 500, rms: 0.02)
        detector.append(sampleCount: 500, rms: 0)
        XCTAssertFalse(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 2_000, rms: 0)
        XCTAssertTrue(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 2_000, rms: 0.02)
        detector.append(sampleCount: 1_000, rms: 0)
        XCTAssertTrue(detector.takePause(sampleRate: 1_000))
        detector.append(sampleCount: 2_000, rms: 0.02)
        detector.append(sampleCount: 1_000, rms: 0)
        XCTAssertFalse(detector.takePause(sampleRate: 1_000))
    }

    func testPauseDetectorSkipsLongRecordings() {
        var detector = ProPauseDetector()
        detector.append(sampleCount: 30_000, rms: 0.02)
        detector.append(sampleCount: 500, rms: 0)
        XCTAssertFalse(detector.takePause(sampleRate: 1_000))
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

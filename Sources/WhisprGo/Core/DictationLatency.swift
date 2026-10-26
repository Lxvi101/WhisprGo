import Foundation
import OSLog

struct DictationLatency {
    let total: TimeInterval
    let capture: TimeInterval
    let preparation: TimeInterval
    let transcription: TimeInterval
    let cleanup: TimeInterval
    let insertion: TimeInterval
    let reusedCleanup: Bool

    var detail: String {
        String(
            format: "Capture %.0f ms · Draft wait %.0f ms · Transcription %.0f ms · Cleanup %.0f ms · Insertion %.0f ms%@",
            capture * 1_000, preparation * 1_000, transcription * 1_000,
            cleanup * 1_000, insertion * 1_000,
            reusedCleanup ? " · Prepared cleanup reused" : ""
        )
    }

    func log() {
        // Durations only: transcripts, context, and credentials never enter logs.
        let logger = Logger(subsystem: "com.whisprgo.app", category: "Latency")
        logger.info("Dictation \(total * 1_000, privacy: .public) ms: \(detail, privacy: .public)")
    }
}

struct DictationTranscriptionResult {
    let text: String
    var warning: String? = nil
    var transcriptionDuration: TimeInterval = 0
    var cleanupDuration: TimeInterval = 0
    var reusedCleanup = false
}

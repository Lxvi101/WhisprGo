import Foundation

/// One recording's speculative cleanup. Drafts never reach the editor until
/// the complete audio has been transcribed and every cleanup input matches.
@MainActor
final class ProCleanupDraft {
    struct Input: Equatable, Sendable {
        let transcript: String
        let context: AccessibilityContextSnapshot?
        let profilePrompt: String
    }

    private var input: Input?
    private var task: Task<String, Error>?

    func start(_ input: Input, polish: @escaping @Sendable () async throws -> String) {
        guard !input.transcript.isEmpty, self.input != input else { return }
        cancel()
        self.input = input
        task = Task {
            try Task.checkCancellation()
            return try await polish()
        }
    }

    func resolve(
        _ input: Input,
        polish: @escaping @Sendable () async throws -> String
    ) async throws -> (text: String, reused: Bool) {
        try Task.checkCancellation()
        if self.input == input, let task {
            do {
                let text = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                try Task.checkCancellation()
                return (text, true)
            } catch {
                // A failed speculative call must not suppress the normal
                // final attempt. Cancellation of the dictation still wins.
                try Task.checkCancellation()
            }
        }
        cancel()
        let text = try await polish()
        try Task.checkCancellation()
        return (text, false)
    }

    func cancel() {
        task?.cancel()
        task = nil
        input = nil
    }
}

/// A pause is only a scheduling hint, never an audio cut or proof that the
/// speaker has finished. Quiet words are still included in the final decode.
struct ProPauseDetector {
    static let maximumDrafts = 3
    static let maximumSeconds = 30

    private var sampleCount = 0
    private var lastVoiceEnd = 0
    private var scheduledVoiceEnd = 0
    private var lastScheduledSample = 0
    private var draftCount = 0

    mutating func append(sampleCount: Int, rms: Float) {
        self.sampleCount += sampleCount
        if rms >= 0.0025 { lastVoiceEnd = self.sampleCount }
    }

    mutating func takePause(sampleRate: Int) -> Bool {
        guard draftCount < Self.maximumDrafts,
              sampleCount >= sampleRate,
              sampleCount <= Self.maximumSeconds * sampleRate,
              lastVoiceEnd > scheduledVoiceEnd,
              sampleCount - lastVoiceEnd >= Int(Double(sampleRate) * 0.45),
              draftCount == 0 || sampleCount - lastScheduledSample >= 3 * sampleRate
        else { return false }
        scheduledVoiceEnd = lastVoiceEnd
        lastScheduledSample = sampleCount
        draftCount += 1
        return true
    }
}

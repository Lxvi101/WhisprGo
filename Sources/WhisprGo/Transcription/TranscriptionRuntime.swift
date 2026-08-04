import Foundation
import FluidAudio
import WhisperKit

actor TranscriptionRuntime {
    private enum PreparedBackend {
        case parakeet(AsrManager)
        case whisper(WhisperKit)
        case openAI(RemoteTranscriptionClient, model: String)
    }

    private var desiredModelID: String?
    private var preparedModelID: String?
    private var backend: PreparedBackend?

    func prepare(
        model: TranscriptionModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let progressRelay = DownloadProgressRelay(output: progress)
        desiredModelID = model.id
        preparedModelID = nil
        backend = nil

        let prepared: PreparedBackend
        switch model.backend {
        case .localParakeet:
            let models: AsrModels
            if let cached = ModelCache.cachedFolder(for: model.id),
               AsrModels.modelsExist(at: cached, version: .v3, encoderPrecision: .int8)
            {
                progressRelay.send(1)
                models = try await AsrModels.load(
                    from: cached,
                    version: .v3,
                    encoderPrecision: .int8
                )
            } else {
                let directory = try ModelCache.parakeetDirectory(for: model.id)
                let downloadProgress = SegmentedDownloadProgress(
                    segmentCount: 4,
                    output: { value in progressRelay.send(value) }
                )
                _ = try await AsrModels.download(
                    to: directory,
                    version: .v3,
                    encoderPrecision: .int8,
                    progressHandler: { update in
                        downloadProgress.receive(update)
                    }
                )
                ModelCache.record(folder: directory, for: model.id)
                progressRelay.send(1)
                models = try await AsrModels.load(
                    from: directory,
                    version: .v3,
                    encoderPrecision: .int8
                )
            }
            prepared = .parakeet(AsrManager(
                config: ASRConfig(
                    parallelChunkConcurrency: 1,
                    // FluidAudio documents an encoder-context drift on v3
                    // multilingual audio longer than one model window.
                    melChunkContext: false
                ),
                models: models
            ))

        case let .localWhisper(variant, _):
            let folder: URL
            if let cached = ModelCache.cachedFolder(for: model.id) {
                folder = cached
                progressRelay.send(1)
            } else {
                let root = try ModelCache.downloadRoot(for: model.id)
                folder = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: root,
                    useBackgroundSession: false,
                    progressCallback: { download in
                        progressRelay.send(download.fractionCompleted)
                    }
                )
                ModelCache.record(folder: folder, for: model.id)
            }

            guard desiredModelID == model.id, !Task.isCancelled else {
                throw CancellationError()
            }

            let configuration = WhisperKitConfig(
                modelFolder: folder.path,
                computeOptions: ModelComputeOptions(),
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
            prepared = .whisper(try await WhisperKit(configuration))

        case let .openAI(remoteModel):
            guard let apiKey = KeychainStore.openAIAPIKey(), !apiKey.isEmpty else {
                throw TranscriptionError.missingAPIKey
            }
            prepared = .openAI(RemoteTranscriptionClient(apiKey: apiKey), model: remoteModel)
        }

        guard desiredModelID == model.id, !Task.isCancelled else {
            throw CancellationError()
        }
        backend = prepared
        preparedModelID = model.id
    }

    func transcribe(samples: [Float], modelID: String) async throws -> String {
        guard modelID == preparedModelID, let backend else {
            throw TranscriptionError.modelNotReady
        }

        switch backend {
        case let .parakeet(pipeline):
            let decoderLayers = await pipeline.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await pipeline.transcribe(
                samples,
                decoderState: &decoderState,
                language: Self.preferredParakeetLanguage
            )
            return TextSanitizer.sanitize(result.text)

        case let .whisper(pipeline):
            let options = DecodingOptions(
                verbose: false,
                temperature: 0,
                temperatureFallbackCount: 2,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false,
                concurrentWorkerCount: 1
            )
            let results = try await pipeline.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            return TextSanitizer.sanitize(results.map(\.text).joined(separator: " "))

        case let .openAI(client, remoteModel):
            return try await client.transcribe(samples: samples, model: remoteModel)
        }
    }

    func release() {
        desiredModelID = nil
        preparedModelID = nil
        backend = nil
    }

    /// Parakeet v3 still performs acoustic language recognition. This hint
    /// only rejects tokens from the wrong writing system, preventing a noisy
    /// input from sending the decoder into an unrelated Cyrillic/Greek path.
    private static var preferredParakeetLanguage: Language? {
        guard let preferred = Locale.preferredLanguages.first else { return nil }
        let code = preferred
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)
        return code.flatMap(Language.init(rawValue:))
    }
}

/// FluidAudio reports progress independently for each of Parakeet's four
/// Core ML components. This turns those resets into one monotonic UI value.
private final class SegmentedDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let segmentCount: Int
    private let output: @Sendable (Double) -> Void
    private var completedSegments = 0
    private var previousFraction = 0.0

    init(segmentCount: Int, output: @escaping @Sendable (Double) -> Void) {
        self.segmentCount = segmentCount
        self.output = output
    }

    func receive(_ progress: DownloadProgress) {
        lock.lock()
        if progress.fractionCompleted + 0.01 < previousFraction {
            completedSegments = min(completedSegments + 1, segmentCount - 1)
        }
        previousFraction = progress.fractionCompleted
        let combined = min(
            1,
            (Double(completedSegments) + progress.fractionCompleted) / Double(segmentCount)
        )
        lock.unlock()
        output(combined)
    }
}

/// Network progress can arrive for every response chunk. Publishing at display
/// rates only creates needless view work, so state is capped at ten updates per
/// second while completion is always delivered immediately.
private final class DownloadProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let output: @Sendable (Double) -> Void
    private var lastEmissionTime = 0.0
    private var didEmitCompletion = false

    init(output: @escaping @Sendable (Double) -> Void) {
        self.output = output
    }

    func send(_ value: Double) {
        let clamped = max(0, min(1, value))
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let isNewCompletion = clamped >= 0.999 && !didEmitCompletion
        let shouldEmit = lastEmissionTime == 0
            || now - lastEmissionTime >= 0.1
            || isNewCompletion
        if shouldEmit {
            lastEmissionTime = now
        }
        if isNewCompletion {
            didEmitCompletion = true
        }
        lock.unlock()

        if shouldEmit {
            output(clamped)
        }
    }
}

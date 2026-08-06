import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

enum ProCleanupProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case local

    static let defaultProvider: Self = .openAI

    var id: Self { self }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .local: return "On Device (Beta)"
        }
    }

    var detail: String {
        switch self {
        case .openAI:
            return "GPT-5.6 Luna cleans each transcript in the cloud."
        case .local:
            return "Beta · Gemma 4 E2B cleans transcripts with MLX and keeps their text on this Mac."
        }
    }
}

enum LocalProModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case loading
    case ready
    case downloaded
    case failed(String)
}

enum LocalProModel {
    static let cacheID = "cleanup.gemma4.e2b.mlx.4bit"
    static let repositoryID = "unsloth/gemma-4-E2B-it-UD-MLX-4bit"
    static let sourceURL = URL(
        string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF"
    )!
    static let mlxSourceURL = URL(
        string: "https://huggingface.co/unsloth/gemma-4-E2B-it-UD-MLX-4bit"
    )!
    static let displayName = "Gemma 4 E2B · MLX 4-bit"
    static let diskUsageLabel = "about 4.6 GB"
    static let memoryUsageLabel = "roughly 5–7 GB of unified memory"
    static let unloadDelay: Duration = .seconds(300)
    static let unloadDelayLabel = "5 minutes"

    static var configuration: ModelConfiguration {
        ModelConfiguration(
            id: repositoryID,
            extraEOSTokens: ["<turn|>"]
        )
    }
}

actor LocalProModelRuntime {
    private var container: ModelContainer?

    var isLoaded: Bool { container != nil }

    func prepare(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if container != nil {
            progress(1)
            return
        }

        let tokenizerLoader = WhisprGoTokenizerLoader()
        let loaded: ModelContainer
        if let cached = ModelCache.cachedFolder(for: LocalProModel.cacheID) {
            progress(1)
            loaded = try await LLMModelFactory.shared.loadContainer(
                from: cached,
                using: tokenizerLoader
            )
        } else {
            let cacheRoot = try ModelCache.downloadRoot(for: LocalProModel.cacheID)
            let downloader = WhisprGoHuggingFaceDownloader(
                cacheRoot: cacheRoot,
                modelCacheID: LocalProModel.cacheID
            )
            loaded = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: LocalProModel.configuration,
                useLatest: false,
                progressHandler: { update in
                    progress(update.fractionCompleted)
                }
            )
        }

        guard !Task.isCancelled else { throw CancellationError() }
        container = loaded
    }

    func polish(
        _ rawTranscript: String,
        context: AccessibilityContextSnapshot?,
        profilePrompt: String
    ) async throws -> String {
        guard !rawTranscript.isEmpty else { return rawTranscript }
        guard let container else { throw LocalProModelError.notReady }

        let maxTokens = max(256, min(2_048, rawTranscript.utf8.count / 2 + 256))
        let session = ChatSession(
            container,
            instructions: ProTranscriptionPrompt.instructions(
                profilePrompt: profilePrompt
            ),
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: 8_192,
                kvBits: 8,
                temperature: 0
            ),
            additionalContext: ["enable_thinking": false]
        )
        let output = try await session.respond(
            to: ProTranscriptionPrompt.input(
                rawTranscript: rawTranscript,
                context: context
            )
        )
        let cleaned = ProTranscriptionOutput.clean(output)
        guard !cleaned.isEmpty else { throw LocalProModelError.emptyOutput }
        return cleaned
    }

    func release() {
        container = nil
        Memory.clearCache()
    }
}

private struct WhisprGoHuggingFaceDownloader: Downloader {
    let client: HubClient
    let modelCacheID: String

    init(cacheRoot: URL, modelCacheID: String) {
        client = HubClient(cache: HubCache(cacheDirectory: cacheRoot))
        self.modelCacheID = modelCacheID
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repository = Repo.ID(rawValue: id) else {
            throw LocalProModelError.invalidRepositoryID(id)
        }
        let directory = try await client.downloadSnapshot(
            of: repository,
            revision: revision ?? "main",
            matching: patterns,
            maxConcurrentDownloads: 4,
            progressHandler: { progress in
                progressHandler(progress)
            }
        )
        ModelCache.record(folder: directory, for: modelCacheID)
        return directory
    }
}

private struct WhisprGoTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        WhisprGoTokenizer(
            try await AutoTokenizer.from(modelFolder: directory)
        )
    }
}

private struct WhisprGoTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum LocalProModelError: LocalizedError {
    case invalidRepositoryID(String)
    case notReady
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case let .invalidRepositoryID(id):
            return "Invalid local cleanup model repository: \(id)."
        case .notReady:
            return "The local Pro cleanup model is not loaded yet."
        case .emptyOutput:
            return "The local Pro cleanup model returned no cleaned text."
        }
    }
}

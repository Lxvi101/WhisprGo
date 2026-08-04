import AVFoundation
import Combine
import Foundation

struct DictationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let audioFileName: String
    var transcript: String
    var modelID: String
    var modelName: String
    var latency: TimeInterval?
    var errorMessage: String?
}

struct DictationHistorySnapshot: Sendable {
    let revision: Int
    let entries: [DictationHistoryEntry]
}

actor DictationHistoryPersistence {
    static let maximumEntryCount = 50

    private let rootURL: URL
    private let manifestURL: URL
    private var entries: [DictationHistoryEntry]?
    private var revision = 0

    init(rootURL: URL? = nil) {
        let defaultRoot = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisprGo", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        self.rootURL = rootURL ?? defaultRoot
        manifestURL = self.rootURL.appendingPathComponent("history.json")
    }

    func snapshot() throws -> DictationHistorySnapshot {
        try loadIfNeeded()
        return currentSnapshot()
    }

    func add(
        samples: [Float],
        transcript: String,
        modelID: String,
        modelName: String,
        duration: TimeInterval,
        latency: TimeInterval?,
        errorMessage: String?
    ) throws -> DictationHistorySnapshot {
        try loadIfNeeded()

        let id = UUID()
        let audioFileName = "\(id.uuidString.lowercased()).wav"
        let audioURL = rootURL.appendingPathComponent(audioFileName)
        let audio = WAVEncoder.encode(samples: samples)
        try audio.write(to: audioURL, options: .atomic)

        let entry = DictationHistoryEntry(
            id: id,
            createdAt: Date(),
            duration: duration,
            audioFileName: audioFileName,
            transcript: transcript,
            modelID: modelID,
            modelName: modelName,
            latency: latency,
            errorMessage: errorMessage
        )

        entries?.insert(entry, at: 0)
        let pruned = pruneOverflow()
        do {
            try saveManifest()
            for item in pruned {
                try? FileManager.default.removeItem(
                    at: rootURL.appendingPathComponent(item.audioFileName)
                )
            }
        } catch {
            entries?.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }

        revision &+= 1
        return currentSnapshot()
    }

    func update(
        id: UUID,
        transcript: String?,
        modelID: String?,
        modelName: String?,
        latency: TimeInterval?,
        errorMessage: String?
    ) throws -> DictationHistorySnapshot {
        try loadIfNeeded()
        guard let index = entries?.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if let transcript {
            entries?[index].transcript = transcript
        }
        if let modelID {
            entries?[index].modelID = modelID
        }
        if let modelName {
            entries?[index].modelName = modelName
        }
        entries?[index].latency = latency
        entries?[index].errorMessage = errorMessage
        try saveManifest()
        revision &+= 1
        return currentSnapshot()
    }

    func remove(id: UUID) throws -> DictationHistorySnapshot {
        try loadIfNeeded()
        guard let entry = entries?.first(where: { $0.id == id }) else {
            return currentSnapshot()
        }
        entries?.removeAll { $0.id == id }
        try saveManifest()
        try? FileManager.default.removeItem(
            at: rootURL.appendingPathComponent(entry.audioFileName)
        )
        revision &+= 1
        return currentSnapshot()
    }

    func removeAll() throws -> DictationHistorySnapshot {
        try loadIfNeeded()
        let removed = entries ?? []
        entries = []
        try saveManifest()
        for entry in removed {
            try? FileManager.default.removeItem(
                at: rootURL.appendingPathComponent(entry.audioFileName)
            )
        }
        revision &+= 1
        return currentSnapshot()
    }

    func audioURL(for id: UUID) throws -> URL {
        try loadIfNeeded()
        guard let entry = entries?.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = rootURL.appendingPathComponent(entry.audioFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    func samples(for id: UUID) throws -> [Float] {
        let url = try audioURL(for: id)
        return try WAVDecoder.decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func loadIfNeeded() throws {
        guard entries == nil else { return }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            entries = []
            return
        }

        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let decoded = try JSONDecoder().decode([DictationHistoryEntry].self, from: data)
        entries = decoded
            .filter {
                FileManager.default.fileExists(
                    atPath: rootURL.appendingPathComponent($0.audioFileName).path
                )
            }
            .sorted { $0.createdAt > $1.createdAt }

        let pruned = pruneOverflow()
        if !pruned.isEmpty || entries?.count != decoded.count {
            try saveManifest()
            for item in pruned {
                try? FileManager.default.removeItem(
                    at: rootURL.appendingPathComponent(item.audioFileName)
                )
            }
        }
    }

    private func pruneOverflow() -> [DictationHistoryEntry] {
        guard let count = entries?.count,
              count > Self.maximumEntryCount
        else { return [] }
        let overflow = Array(entries![Self.maximumEntryCount...])
        entries?.removeLast(count - Self.maximumEntryCount)
        return overflow
    }

    private func saveManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries ?? [])
        try data.write(to: manifestURL, options: .atomic)
    }

    private func currentSnapshot() -> DictationHistorySnapshot {
        DictationHistorySnapshot(revision: revision, entries: entries ?? [])
    }
}

@MainActor
final class DictationHistoryStore: ObservableObject {
    static let shared = DictationHistoryStore()

    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var playingEntryID: UUID?
    @Published private(set) var rerunningEntryID: UUID?
    @Published private(set) var lastError: String?

    private let persistence: DictationHistoryPersistence
    private var latestRevision = -1
    private var hasRequestedInitialLoad = false
    private var playbackRequestID: UUID?
    private var player: AVPlayer?
    private var playbackObserver: NSObjectProtocol?

    init(persistence: DictationHistoryPersistence = DictationHistoryPersistence()) {
        self.persistence = persistence
    }

    func loadIfNeeded() {
        guard !hasRequestedInitialLoad else { return }
        hasRequestedInitialLoad = true
        let persistence = persistence
        Task.detached(priority: .utility) { [weak self] in
            do {
                let snapshot = try await persistence.snapshot()
                await self?.apply(snapshot)
            } catch {
                await self?.report(error)
            }
        }
    }

    /// This method performs no encoding or file access before returning. It is
    /// called only after inference and text injection have completed.
    func enqueue(
        samples: [Float],
        transcript: String,
        modelID: String,
        modelName: String,
        duration: TimeInterval,
        latency: TimeInterval?,
        errorMessage: String?
    ) {
        let persistence = persistence
        Task.detached(priority: .utility) { [weak self] in
            do {
                let snapshot = try await persistence.add(
                    samples: samples,
                    transcript: transcript,
                    modelID: modelID,
                    modelName: modelName,
                    duration: duration,
                    latency: latency,
                    errorMessage: errorMessage
                )
                await self?.apply(snapshot)
            } catch {
                await self?.report(error)
            }
        }
    }

    func updateAfterRerun(
        id: UUID,
        transcript: String?,
        modelID: String?,
        modelName: String?,
        latency: TimeInterval?,
        errorMessage: String?
    ) {
        let persistence = persistence
        Task.detached(priority: .utility) { [weak self] in
            do {
                let snapshot = try await persistence.update(
                    id: id,
                    transcript: transcript,
                    modelID: modelID,
                    modelName: modelName,
                    latency: latency,
                    errorMessage: errorMessage
                )
                await self?.apply(snapshot)
            } catch {
                await self?.report(error)
            }
        }
    }

    func samples(for id: UUID) async throws -> [Float] {
        try await persistence.samples(for: id)
    }

    func latestTranscript() async -> String? {
        if let transcript = entries.first(where: { !$0.transcript.isEmpty })?.transcript {
            return transcript
        }
        do {
            let snapshot = try await persistence.snapshot()
            apply(snapshot)
            return snapshot.entries.first(where: { !$0.transcript.isEmpty })?.transcript
        } catch {
            report(error)
            return nil
        }
    }

    func setRerunning(_ id: UUID?) {
        rerunningEntryID = id
    }

    func togglePlayback(_ id: UUID) {
        if playingEntryID == id {
            stopPlayback()
            return
        }

        stopPlayback()
        let requestID = UUID()
        playbackRequestID = requestID
        let persistence = persistence
        Task { [weak self] in
            do {
                let url = try await persistence.audioURL(for: id)
                guard let self, self.playbackRequestID == requestID else { return }
                let item = AVPlayerItem(url: url)
                let player = AVPlayer(playerItem: item)
                self.player = player
                self.playingEntryID = id
                self.playbackObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.stopPlayback() }
                }
                player.play()
            } catch {
                self?.report(error)
            }
        }
    }

    func remove(_ id: UUID) {
        if playingEntryID == id {
            stopPlayback()
        }
        let persistence = persistence
        Task.detached(priority: .utility) { [weak self] in
            do {
                let snapshot = try await persistence.remove(id: id)
                await self?.apply(snapshot)
            } catch {
                await self?.report(error)
            }
        }
    }

    func clear() {
        stopPlayback()
        let persistence = persistence
        Task.detached(priority: .utility) { [weak self] in
            do {
                let snapshot = try await persistence.removeAll()
                await self?.apply(snapshot)
            } catch {
                await self?.report(error)
            }
        }
    }

    func stopPlayback() {
        playbackRequestID = nil
        player?.pause()
        player = nil
        playingEntryID = nil
        if let playbackObserver {
            NotificationCenter.default.removeObserver(playbackObserver)
            self.playbackObserver = nil
        }
    }

    private func apply(_ snapshot: DictationHistorySnapshot) {
        guard snapshot.revision >= latestRevision else { return }
        latestRevision = snapshot.revision
        entries = snapshot.entries
        lastError = nil
    }

    private func report(_ error: Error) {
        lastError = "History could not be updated: \(error.localizedDescription)"
    }
}

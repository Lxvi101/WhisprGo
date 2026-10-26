import CryptoKit
import Foundation
import libzstd
import MLX

/// Downloads a pinned Phonon-2.5 release from Hugging Face, verifies it, and
/// converts it once into the MLX layout WhisprGo loads.
enum PhononInstaller {
    enum InstallError: LocalizedError {
        case download(String)
        case checksum(String)
        case archive(String)

        var errorDescription: String? {
            switch self {
            case let .download(detail):
                return "The Phonon model could not be downloaded: \(detail)"
            case let .checksum(file):
                return "The downloaded \(file) did not match its published checksum. Try again."
            case let .archive(detail):
                return "The Phonon model archive could not be unpacked: \(detail)"
            }
        }
    }

    private static let installedFolderName = "phonon"

    static func installedDirectory(in root: URL) -> URL {
        root.appendingPathComponent(installedFolderName, isDirectory: true)
    }

    /// Returns the converted model directory, installing it first if needed.
    /// `progress` receives 0...1 for the whole installation.
    static func install(
        _ variant: PhononVariant,
        into root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let destination = installedDirectory(in: root)
        if PhononInstalledFiles(directory: destination).isComplete(for: variant) {
            progress(1)
            return destination
        }

        let fileManager = FileManager.default
        let staging = root.appendingPathComponent(
            "staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(variant.archiveName)
        try await PhononDownloader.download(
            variant.archiveURL,
            to: archive,
            expectedBytes: variant.archiveBytes
        ) { fraction in
            progress(0.9 * fraction)
        }
        try Task.checkCancellation()

        guard try sha256(of: archive) == variant.archiveSHA256 else {
            throw InstallError.checksum(variant.archiveName)
        }
        progress(0.92)

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        let digests = try extract(
            archive: archive,
            files: ["config.json", "model.fermion"],
            into: extracted
        )
        try? fileManager.removeItem(at: archive)
        guard digests["model.fermion"] == variant.containerSHA256 else {
            throw InstallError.checksum("model.fermion")
        }
        try Task.checkCancellation()
        progress(0.95)

        let output = staging.appendingPathComponent("converted", isDirectory: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        let files = PhononInstalledFiles(directory: output)
        try autoreleasepool {
            let converted = try PhononContainerConverter.convert(
                container: extracted.appendingPathComponent("model.fermion"),
                configuration: extracted.appendingPathComponent("config.json")
            )
            try save(arrays: converted.weights, url: files.weights)
            try JSONEncoder().encode(converted.vocabulary).write(to: files.vocabulary)
        }
        Memory.clearCache()
        // The manifest is written last: its presence marks a complete model.
        try JSONEncoder().encode(PhononInstalledFiles.Manifest(
            format: PhononInstalledFiles.formatVersion,
            containerSHA256: variant.containerSHA256
        )).write(to: files.manifest)
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: output, to: destination)
        progress(1)
        return destination
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams a zstd-compressed tar archive, writing only the requested
    /// top-level regular files. Returns each written file's SHA-256.
    static func extract(
        archive: URL,
        files wanted: Set<String>,
        into directory: URL
    ) throws -> [String: String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }

        var reader = TarReader(wanted: wanted, directory: directory)
        try ZstdStream.decompress(from: input) { chunk in
            try reader.consume(chunk)
        }
        try reader.finish()
        let missing = wanted.subtracting(reader.digests.keys)
        guard missing.isEmpty else {
            throw InstallError.archive("missing \(missing.sorted().joined(separator: ", "))")
        }
        return reader.digests
    }
}

private enum ZstdStream {
    static func decompress(
        from input: FileHandle,
        output: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard let stream = ZSTD_createDStream() else {
            throw PhononInstaller.InstallError.archive("zstd is unavailable")
        }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        let outputCapacity = ZSTD_DStreamOutSize()
        let outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: outputCapacity, alignment: 16)
        defer { outputBuffer.deallocate() }

        var lastResult = 0
        while let chunk = try input.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty {
            try chunk.withUnsafeBytes { raw in
                var inBuffer = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
                var outputWasFull = false
                // A full output buffer may leave decoded data inside zstd, so
                // keep draining until the input is consumed and output drains.
                repeat {
                    var outBuffer = ZSTD_outBuffer(dst: outputBuffer, size: outputCapacity, pos: 0)
                    let result = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    if ZSTD_isError(result) != 0 {
                        throw PhononInstaller.InstallError.archive(
                            String(cString: ZSTD_getErrorName(result))
                        )
                    }
                    lastResult = result
                    if outBuffer.pos > 0 {
                        try output(UnsafeRawBufferPointer(start: outputBuffer, count: outBuffer.pos))
                    }
                    outputWasFull = outBuffer.pos == outputCapacity
                } while inBuffer.pos < inBuffer.size || outputWasFull
            }
            try Task.checkCancellation()
        }
        // zstd reports 0 only once a frame is fully decoded and flushed.
        guard lastResult == 0 else {
            throw PhononInstaller.InstallError.archive("the archive ended early")
        }
    }
}

/// A minimal streaming ustar reader. Entries are written only when their
/// exact name is requested, so archive paths can never escape `directory`.
private struct TarReader {
    let wanted: Set<String>
    let directory: URL
    private(set) var digests: [String: String] = [:]

    private var header = Data()
    private var remaining = 0
    private var padding = 0
    private var current: (name: String, handle: FileHandle, hasher: SHA256)?
    private var finished = false

    init(wanted: Set<String>, directory: URL) {
        self.wanted = wanted
        self.directory = directory
    }

    mutating func consume(_ chunk: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < chunk.count {
            if finished { return }
            if remaining > 0 {
                let count = min(remaining, chunk.count - offset)
                if var entry = current {
                    let slice = UnsafeRawBufferPointer(rebasing: chunk[offset..<(offset + count)])
                    entry.hasher.update(bufferPointer: slice)
                    try entry.handle.write(contentsOf: Data(slice))
                    current = entry
                }
                remaining -= count
                offset += count
                if remaining == 0 {
                    try closeCurrent()
                }
            } else if padding > 0 {
                let count = min(padding, chunk.count - offset)
                padding -= count
                offset += count
            } else {
                let count = min(512 - header.count, chunk.count - offset)
                header.append(contentsOf: UnsafeRawBufferPointer(
                    rebasing: chunk[offset..<(offset + count)]
                ))
                offset += count
                if header.count == 512 {
                    try beginEntry(header)
                    header.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    mutating func finish() throws {
        guard remaining == 0, current == nil else {
            throw PhononInstaller.InstallError.archive("the archive ended inside a file")
        }
    }

    private mutating func beginEntry(_ block: Data) throws {
        if block.allSatisfy({ $0 == 0 }) {
            finished = true
            return
        }
        let bytes = [UInt8](block)
        func field(_ start: Int, _ length: Int) -> String {
            let slice = bytes[start..<(start + length)].prefix { $0 != 0 }
            return String(decoding: slice, as: UTF8.self)
        }
        let storedChecksum = Int(field(148, 8).trimmingCharacters(in: .whitespaces), radix: 8)
        let computedChecksum = bytes.enumerated().reduce(0) { sum, element in
            sum + ((148..<156).contains(element.offset) ? 32 : Int(element.element))
        }
        guard storedChecksum == computedChecksum else {
            throw PhononInstaller.InstallError.archive("corrupt tar header")
        }
        guard let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) else {
            throw PhononInstaller.InstallError.archive("invalid tar entry size")
        }
        var name = field(0, 100)
        let prefix = field(345, 155)
        if !prefix.isEmpty { name = prefix + "/" + name }
        if name.hasPrefix("./") { name.removeFirst(2) }
        let type = bytes[156]

        remaining = size
        padding = (512 - size % 512) % 512
        let isRegularFile = type == 0 || type == UInt8(ascii: "0")
        guard isRegularFile, wanted.contains(name), digests[name] == nil else {
            if remaining == 0 { try closeCurrent() }
            return
        }

        let url = directory.appendingPathComponent(name, isDirectory: false)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        current = (name, try FileHandle(forWritingTo: url), SHA256())
        if remaining == 0 { try closeCurrent() }
    }

    private mutating func closeCurrent() throws {
        guard let entry = current else { return }
        try entry.handle.close()
        digests[entry.name] = entry.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        current = nil
    }
}

/// A file download with progress and cooperative cancellation.
private final class PhononDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    private init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    static func download(
        _ url: URL,
        to destination: URL,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = PhononDownloader(
            destination: destination,
            expectedBytes: expectedBytes,
            progress: progress
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func resume(with result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        progress(min(1, Double(totalBytesWritten) / Double(max(total, 1))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode)
            {
                throw PhononInstaller.InstallError.download("HTTP \(response.statusCode)")
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard size == expectedBytes else {
                throw PhononInstaller.InstallError.download("received \(size) of \(expectedBytes) bytes")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            resume(with: .success(()))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            resume(with: .failure(CancellationError()))
        } else {
            resume(with: .failure(PhononInstaller.InstallError.download(error.localizedDescription)))
        }
    }
}

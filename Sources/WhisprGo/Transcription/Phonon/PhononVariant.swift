import Foundation

/// A published Phonon-2.5 release, pinned to an exact Hugging Face revision
/// and verified by SHA-256 at every stage of installation.
struct PhononVariant: Hashable, Sendable {
    let repository: String
    let revision: String
    let archiveName: String
    let archiveSHA256: String
    let archiveBytes: Int64
    let containerSHA256: String
    /// Leading digital silence Fermion decodes each window with.
    let leadPadSeconds: Double
    let writesFinalSigma: Bool

    var archiveURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(archiveName)")!
    }

    static let multilingual = PhononVariant(
        repository: "FermionResearch/Phonon-2.5",
        revision: "2673618ad8636c8dfd20fe57e94d1f67f75bdeaa",
        archiveName: "phonon-2.5.bps.tar.zst",
        archiveSHA256: "1faa04053a472cabab3bc31d07f30c23f22906f71044ca10eb1f0de36d1f19a9",
        archiveBytes: 162_587_031,
        containerSHA256: "17cb62d08e751a41819eb779db089aa7ac4eb2bab433ba5c2991d8cbd3cfefb9",
        leadPadSeconds: 0.25,
        writesFinalSigma: true
    )

    static let english = PhononVariant(
        repository: "FermionResearch/Phonon-2.5-English",
        revision: "cea043a0a125d6535d473645ad5fa90847a6b001",
        archiveName: "phonon-2.5-en.bps.tar.zst",
        archiveSHA256: "6bd8119ac5a637e5ece0666f5c1e43dbcd99e1c36b3d0ef3ec5f9b58260a9dd4",
        archiveBytes: 163_693_770,
        containerSHA256: "c57119c0f04756932acc1d60d90506346e3708d69f00e654084acc7fe507fe27",
        leadPadSeconds: 0,
        writesFinalSigma: false
    )
}

/// The converted model WhisprGo keeps on disk.
struct PhononInstalledFiles {
    /// Bump when the converted layout changes so old conversions are redone.
    static let formatVersion = 1

    let directory: URL

    var weights: URL { directory.appendingPathComponent("model.safetensors") }
    var vocabulary: URL { directory.appendingPathComponent("vocabulary.json") }
    var manifest: URL { directory.appendingPathComponent("whisprgo-phonon.json") }

    struct Manifest: Codable, Equatable {
        let format: Int
        let containerSHA256: String
    }

    func isComplete(for variant: PhononVariant) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: weights.path),
              fileManager.fileExists(atPath: vocabulary.path),
              let data = try? Data(contentsOf: manifest),
              let stored = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return false }
        return stored == Manifest(
            format: Self.formatVersion,
            containerSHA256: variant.containerSHA256
        )
    }
}

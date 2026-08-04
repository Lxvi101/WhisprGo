import AtomicSupport

/// A single lock-free value shared by the real-time audio callback and the
/// display-synced overlay. Intermediate values may be dropped intentionally:
/// the UI only needs the newest meter reading.
final class AudioLevelMeter: @unchecked Sendable {
    private let storage: OpaquePointer

    init() {
        guard let storage = WhisprAtomicLevelCreate() else {
            fatalError("Unable to allocate the audio level meter")
        }
        self.storage = storage
    }

    deinit {
        WhisprAtomicLevelDestroy(storage)
    }

    func store(_ level: Float) {
        WhisprAtomicLevelStore(storage, level)
    }

    func load() -> Float {
        WhisprAtomicLevelLoad(storage)
    }

    func reset() {
        store(0)
    }
}

import AtomicSupport

/// A lock-free gate checked before the real-time callback performs any audio
/// conversion. This makes an always-running input graph nearly free while idle.
final class AtomicFlag: @unchecked Sendable {
    private let storage: OpaquePointer

    init(_ value: Bool = false) {
        guard let storage = WhisprAtomicFlagCreate() else {
            fatalError("Unable to allocate the audio callback gate")
        }
        self.storage = storage
        WhisprAtomicFlagStore(storage, value)
    }

    deinit {
        WhisprAtomicFlagDestroy(storage)
    }

    func store(_ value: Bool) {
        WhisprAtomicFlagStore(storage, value)
    }

    func load() -> Bool {
        WhisprAtomicFlagLoad(storage)
    }
}

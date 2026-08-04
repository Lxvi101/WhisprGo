import Foundation

enum WAVEncoder {
    static let sampleRate = 16_000

    static func encode(samples: [Float]) -> Data {
        let bytesPerSample = 2
        let audioByteCount = samples.count * bytesPerSample
        var data = Data(count: 44 + audioByteCount)

        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let bytes = rawBuffer.bindMemory(to: UInt8.self)

            writeASCII("RIFF", to: bytes, at: 0)
            store(UInt32(36 + audioByteCount), at: 4, in: base)
            writeASCII("WAVE", to: bytes, at: 8)
            writeASCII("fmt ", to: bytes, at: 12)
            store(UInt32(16), at: 16, in: base)
            store(UInt16(1), at: 20, in: base)
            store(UInt16(1), at: 22, in: base)
            store(UInt32(sampleRate), at: 24, in: base)
            store(UInt32(sampleRate * bytesPerSample), at: 28, in: base)
            store(UInt16(bytesPerSample), at: 32, in: base)
            store(UInt16(16), at: 34, in: base)
            writeASCII("data", to: bytes, at: 36)
            store(UInt32(audioByteCount), at: 40, in: base)

            let output = base.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let scaled = (max(-1, min(1, sample)) * 32_767).rounded()
                output[index] = Int16(scaled).littleEndian
            }
        }
        return data
    }

    private static func writeASCII(
        _ value: StaticString,
        to bytes: UnsafeMutableBufferPointer<UInt8>,
        at offset: Int
    ) {
        value.withUTF8Buffer { source in
            for index in source.indices {
                bytes[offset + index] = source[index]
            }
        }
    }

    private static func store<T: FixedWidthInteger>(
        _ value: T,
        at offset: Int,
        in base: UnsafeMutableRawPointer
    ) {
        base.advanced(by: offset).storeBytes(of: value.littleEndian, as: T.self)
    }
}

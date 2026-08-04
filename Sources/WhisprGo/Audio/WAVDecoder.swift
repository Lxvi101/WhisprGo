import Foundation

enum WAVDecoder {
    enum DecodingError: LocalizedError {
        case invalidFile
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "The saved recording is incomplete or damaged."
            case .unsupportedFormat:
                return "The saved recording uses an unsupported audio format."
            }
        }
    }

    static func decode(_ data: Data) throws -> [Float] {
        guard data.count >= 44,
              ascii(in: data, range: 0..<4) == "RIFF",
              ascii(in: data, range: 8..<12) == "WAVE",
              ascii(in: data, range: 36..<40) == "data"
        else {
            throw DecodingError.invalidFile
        }

        let format = uint16(in: data, at: 20)
        let channels = uint16(in: data, at: 22)
        let sampleRate = uint32(in: data, at: 24)
        let bitsPerSample = uint16(in: data, at: 34)
        guard format == 1,
              channels == 1,
              sampleRate == UInt32(WAVEncoder.sampleRate),
              bitsPerSample == 16
        else {
            throw DecodingError.unsupportedFormat
        }

        let declaredByteCount = Int(uint32(in: data, at: 40))
        guard declaredByteCount >= 0,
              declaredByteCount.isMultiple(of: 2),
              44 + declaredByteCount <= data.count
        else {
            throw DecodingError.invalidFile
        }

        let sampleCount = declaredByteCount / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            for index in 0..<sampleCount {
                let offset = 44 + index * 2
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                samples[index] = Float(Int16(bitPattern: bits)) / 32_767
            }
        }
        return samples
    }

    private static func ascii(in data: Data, range: Range<Int>) -> String? {
        String(data: data[range], encoding: .ascii)
    }

    private static func uint16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

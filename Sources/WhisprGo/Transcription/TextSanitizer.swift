import Foundation

enum TextSanitizer {
    private static let nonSpeech = try! NSRegularExpression(
        pattern: #"(?:\[[^\]]*\]|\([^)]*\)|<\|[^|]*\|>|\*[^*]*\*)"#
    )
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    static func sanitize(_ text: String) -> String {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutNonSpeech = nonSpeech.stringByReplacingMatches(
            in: text,
            range: fullRange,
            withTemplate: " "
        )
        let whitespaceRange = NSRange(
            withoutNonSpeech.startIndex..<withoutNonSpeech.endIndex,
            in: withoutNonSpeech
        )
        return whitespace.stringByReplacingMatches(
            in: withoutNonSpeech,
            range: whitespaceRange,
            withTemplate: " "
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

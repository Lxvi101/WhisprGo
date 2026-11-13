import Foundation

enum DictationMode: String, CaseIterable, Identifiable, Sendable {
    case fast
    case pro
    case chatGPT

    var id: Self { self }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .pro: return "Pro"
        case .chatGPT: return "ChatGPT"
        }
    }

    var detail: String {
        switch self {
        case .fast:
            return "Types the transcription immediately. No cleanup model or context reading."
        case .pro:
            return "Polishes dictation with the Pro engine selected in Settings."
        case .chatGPT:
            return "Sends the recording to ChatGPT with your ChatGPT sign-in. No API key or local model."
        }
    }

    /// The mode the switch shortcut moves to next.
    var next: Self {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum ProModeEngine: String, CaseIterable, Identifiable, Sendable {
    case instruct
    case geminiTranscribe

    var id: Self { self }

    static let defaultEngine: Self = .instruct

    var title: String {
        switch self {
        case .instruct: return "Instruct Pro"
        case .geminiTranscribe: return "Gemini 3.5 Transcribe"
        }
    }

    var shortTitle: String {
        switch self {
        case .instruct: return "Instruct"
        case .geminiTranscribe: return "Gemini 3.5"
        }
    }

    var detail: String {
        switch self {
        case .instruct:
            return "Transcribes with the selected Fast model, then GPT-5.6 Luna removes fillers and false starts using your profile and nearby text."
        case .geminiTranscribe:
            return "Sends the audio directly to Gemini Smart transcription in one pass, with names and technical terms supplied as vocabulary hints."
        }
    }
}

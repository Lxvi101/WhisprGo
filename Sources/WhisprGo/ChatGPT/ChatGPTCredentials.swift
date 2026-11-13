import Foundation

/// A ChatGPT sign-in owned by WhisprGo. It is independent of any Codex CLI
/// session, so renewing it never rotates a refresh token another app relies on.
struct ChatGPTCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var accountID: String
    var email: String?
    var planType: String?
    /// Expiry of `accessToken`, read from its JWT `exp` claim.
    var expiresAt: Date?

    func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < interval
    }

    /// Builds credentials from an OAuth token response. A refresh response may
    /// omit the refresh or ID token, in which case the previous ones are kept.
    static func make(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        previous: ChatGPTCredentials? = nil
    ) -> ChatGPTCredentials? {
        guard let refreshToken = refreshToken ?? previous?.refreshToken,
              !accessToken.isEmpty,
              !refreshToken.isEmpty
        else { return nil }

        let idToken = idToken ?? previous?.idToken
        let accessClaims = ChatGPTJWT.claims(accessToken)
        let idClaims = idToken.flatMap(ChatGPTJWT.claims)
        let accessAuth = accessClaims?[ChatGPTJWT.authClaim] as? [String: Any]
        let idAuth = idClaims?[ChatGPTJWT.authClaim] as? [String: Any]

        guard let accountID = (idAuth?["chatgpt_account_id"] as? String)
            ?? (accessAuth?["chatgpt_account_id"] as? String)
            ?? previous?.accountID,
            !accountID.isEmpty
        else { return nil }

        let profile = accessClaims?[ChatGPTJWT.profileClaim] as? [String: Any]
        let email = (idClaims?["email"] as? String)
            ?? (profile?["email"] as? String)
            ?? previous?.email
        let plan = (accessAuth?["chatgpt_plan_type"] as? String)
            ?? (idAuth?["chatgpt_plan_type"] as? String)
            ?? previous?.planType
        let expiry = (accessClaims?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))

        return ChatGPTCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            email: email,
            planType: plan,
            expiresAt: expiry
        )
    }
}

/// What the interface shows about the signed-in account. Never contains tokens.
struct ChatGPTAccountSummary: Equatable, Sendable {
    let email: String?
    let planType: String?

    init(_ credentials: ChatGPTCredentials) {
        email = credentials.email
        planType = credentials.planType
    }

    init(email: String?, planType: String?) {
        self.email = email
        self.planType = planType
    }

    var planTitle: String? {
        guard let planType, !planType.isEmpty else { return nil }
        switch planType.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite", "pro_lite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        default: return planType.capitalized
        }
    }
}

enum ChatGPTJWT {
    static let authClaim = "https://api.openai.com/auth"
    static let profileClaim = "https://api.openai.com/profile"

    /// Decodes a JWT payload without verifying it. The token is only used to
    /// read display data and expiry; the server remains the authority.
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum ChatGPTError: LocalizedError, Equatable {
    case signInRequired
    case sessionExpired
    case signInFailed(String)
    case callbackPortInUse
    case service(Int)
    case unreachable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in with ChatGPT in Settings to use ChatGPT Mode."
        case .sessionExpired:
            return "Your ChatGPT sign-in expired. Sign in again in Settings."
        case let .signInFailed(reason):
            return "ChatGPT sign-in did not finish. \(reason)"
        case .callbackPortInUse:
            return "Another sign-in is already waiting on this Mac (port 1455). Finish or close it, then try again."
        case .service(401):
            return "ChatGPT rejected the sign-in. Sign in again in Settings."
        case .service(403):
            return "ChatGPT denied this dictation request for your account."
        case .service(413):
            return "This recording is too large for ChatGPT."
        case .service(429):
            return "ChatGPT reached its dictation limit. Try again shortly."
        case let .service(code) where code >= 500:
            return "ChatGPT could not transcribe right now (HTTP \(code)). The recording is in History for Retry."
        case let .service(code):
            return "ChatGPT could not transcribe this recording (HTTP \(code))."
        case .unreachable:
            return "ChatGPT could not be reached. Check your connection; the recording is in History for Retry."
        case .invalidResponse:
            return "ChatGPT returned an unreadable transcript."
        }
    }
}

import Combine
import Foundation

struct AppUpdate: Equatable, Sendable {
    let version: String
    let releaseURL: URL
    let downloadURL: URL
}

struct AppVersion: Comparable, Equatable {
    private let components: [Int]

    init?(_ value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
            .split(separator: "-", maxSplits: 1)[0]
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        components = parts.compactMap { Int($0) }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

enum GitHubReleaseUpdateParser {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    static func availableUpdate(from data: Data, currentVersion: String) throws -> AppUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let current = AppVersion(currentVersion),
              let latest = AppVersion(release.tagName),
              latest > current else {
            return nil
        }

        let dmg = release.assets.first {
            $0.name.lowercased().hasSuffix(".dmg")
        }
        return AppUpdate(
            version: release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            releaseURL: release.htmlURL,
            downloadURL: dmg?.browserDownloadURL ?? release.htmlURL
        )
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var availableUpdate: AppUpdate?

    private let session: URLSession
    private let currentVersion: String
    private var checkTask: Task<Void, Never>?

    init(
        session: URLSession = .shared,
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
    ) {
        self.session = session
        self.currentVersion = currentVersion
    }

    func checkOnLaunch() {
        guard checkTask == nil else { return }
        checkTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { checkTask = nil }

            do {
                var request = URLRequest(
                    url: URL(string: "https://api.github.com/repos/Lxvi101/WhisprGo/releases/latest")!,
                    cachePolicy: .reloadRevalidatingCacheData,
                    timeoutInterval: 6
                )
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("WhisprGo/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    return
                }
                availableUpdate = try GitHubReleaseUpdateParser.availableUpdate(
                    from: data,
                    currentVersion: currentVersion
                )
            } catch is CancellationError {
                return
            } catch {
                // Update checks are best-effort and never interrupt dictation.
            }
        }
    }
}

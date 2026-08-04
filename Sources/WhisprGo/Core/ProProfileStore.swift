import Combine
import Foundation

struct ProProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var prompt: String
}

@MainActor
final class ProProfileStore: ObservableObject {
    static let shared = ProProfileStore()

    @Published private(set) var profiles: [ProProfile]
    @Published private(set) var selectedProfileID: UUID

    private static let profilesKey = "proProfiles"
    private static let selectedProfileKey = "selectedProProfileID"
    private static let standardProfile = ProProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Standard",
        prompt: ""
    )

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decodedProfiles = defaults.data(forKey: Self.profilesKey)
            .flatMap { try? JSONDecoder().decode([ProProfile].self, from: $0) }
            .map { $0.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        let loadedProfiles = decodedProfiles?.isEmpty == false
            ? decodedProfiles!
            : [Self.standardProfile]
        profiles = loadedProfiles

        let savedID = defaults.string(forKey: Self.selectedProfileKey)
            .flatMap(UUID.init(uuidString:))
        selectedProfileID = loadedProfiles.contains { $0.id == savedID }
            ? savedID!
            : loadedProfiles[0].id
    }

    var selectedProfile: ProProfile {
        profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }), selectedProfileID != id else {
            return
        }
        selectedProfileID = id
        defaults.set(id.uuidString, forKey: Self.selectedProfileKey)
    }

    @discardableResult
    func create() -> ProProfile {
        let profile = ProProfile(id: UUID(), name: uniqueNewProfileName(), prompt: "")
        profiles.append(profile)
        selectedProfileID = profile.id
        persist()
        return profile
    }

    func update(id: UUID, name: String, prompt: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        profiles[index].name = String(cleanName.prefix(48))
        profiles[index].prompt = String(prompt.prefix(12_000))
        persist()
    }

    func remove(_ id: UUID) {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return }
        profiles.remove(at: index)
        if selectedProfileID == id {
            selectedProfileID = profiles[min(index, profiles.count - 1)].id
        }
        persist()
    }

    @discardableResult
    func selectNext() -> ProProfile {
        let currentIndex = profiles.firstIndex { $0.id == selectedProfileID } ?? 0
        let next = profiles[(currentIndex + 1) % profiles.count]
        select(next.id)
        return next
    }

    private func uniqueNewProfileName() -> String {
        let names = Set(profiles.map(\.name))
        guard names.contains("New Profile") else { return "New Profile" }
        var suffix = 2
        while names.contains("New Profile \(suffix)") {
            suffix += 1
        }
        return "New Profile \(suffix)"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
        defaults.set(selectedProfileID.uuidString, forKey: Self.selectedProfileKey)
    }
}

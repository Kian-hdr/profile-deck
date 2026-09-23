import Foundation

struct PortableProfile: Identifiable, Codable, Sendable {
    var id: UUID; var name: String; var authMode: AuthMode; var color: String; var favorite: Bool
}
struct PortableIntegration: Identifiable, Codable, Sendable {
    var id: String; var name: String; var kind: IntegrationKind; var source: String; var version: String?; var enabled: Bool
}
struct PortableConfiguration: Codable, Sendable {
    var schemaVersion = 1
    var profiles: [PortableProfile]
    var integrations: [PortableIntegration]
    var preferences: DeckSettings
    init(state: PersistedDeck) {
        profiles = state.profiles.map { PortableProfile(id: $0.id, name: $0.name, authMode: $0.authMode, color: $0.color, favorite: $0.favorite) }
        integrations = state.integrations.filter { $0.profileID == nil }.map { PortableIntegration(id: $0.id, name: $0.name, kind: $0.kind, source: "", version: $0.version, enabled: $0.desiredEnabled) }
        preferences = state.settings
        preferences.launchAtLogin = false; preferences.notificationsEnabled = false
        preferences.launchAtLoginInitialized = true
    }
    func validate() throws {
        guard schemaVersion == 1, profiles.count <= 1000, integrations.count <= 2000,
              Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 100 }),
              integrations.allSatisfy({ $0.name.count <= 256 && $0.id.count <= 512 }) else { throw DeckError.message("This export is invalid or uses an unsupported format.") }
    }
}

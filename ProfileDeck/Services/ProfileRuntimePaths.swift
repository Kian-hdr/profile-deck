import Foundation

/// ChatGPT's per-profile IPC socket uses a Unix-domain path. macOS limits that
/// path to a little over 100 bytes, so nested managed profile folders can
/// exceed the limit even though the folders themselves are valid.
/// Persisted folders remain authoritative; short symlink aliases are exposed
/// only to the provider process and its helper processes.
enum ProfileRuntimePaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".profile-deck-runtime", isDirectory: true)

    static func prepare(_ profile: Profile) throws -> (home: String, data: String) {
        let directory = root.appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let data = directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try link(home, to: profile.canonicalHome)
        try link(data, to: profile.canonicalData)
        return (home.path, data.path)
    }

    private static func link(_ alias: URL, to target: String) throws {
        let files = FileManager.default
        if files.fileExists(atPath: alias.path) {
            guard (try? files.destinationOfSymbolicLink(atPath: alias.path)) == target else {
                throw DeckError.message("The short runtime alias for this profile points somewhere else. Existing profile folders were not changed.")
            }
            return
        }
        try files.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: target))
    }
}

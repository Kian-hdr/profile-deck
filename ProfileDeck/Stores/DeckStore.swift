import Foundation
import SQLite3

actor DeckStore {
    private let directory: URL
    private var recoveryURL: URL { directory.appendingPathComponent("deck-state-last-good.json") }
    private var latestRevision: UInt64 = 0
    init(directory: URL) { self.directory = directory }
    private func connection() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        let path = directory.appendingPathComponent("deck.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw DeckError.message("Profile Deck could not open its local database. Your native profiles have not been changed.")
        }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS deck_state (id INTEGER PRIMARY KEY CHECK(id=1), schema_version INTEGER NOT NULL, payload BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); throw DeckError.message("The manager database needs recovery. Existing native profiles remain intact.")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return db
    }
    func load() throws -> PersistedDeck? {
        let db = try connection(); defer { sqlite3_close(db) }
        let recovery = try FileManager.default.fileExists(atPath: recoveryURL.path)
            ? JSONDecoder().decode(PersistedDeck.self, from: Data(contentsOf: recoveryURL)) : nil
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT schema_version,payload FROM deck_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw DeckError.message("Cannot read the manager database.") }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return recovery }
        guard result == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1, let bytes = sqlite3_column_blob(statement, 1) else { throw DeckError.message("Unsupported or damaged manager database. Restore a compatible manager backup before continuing.") }
        let databaseState = try JSONDecoder().decode(PersistedDeck.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
        let databaseIDs = Set(databaseState.profiles.map(\.id))
        let recoveryIDs = Set(recovery?.profiles.map(\.id) ?? [])
        let state = recoveryIDs.isSuperset(of: databaseIDs) ? (recovery ?? databaseState) : databaseState
        if state.profiles.count > 0 && !recoveryIDs.isSuperset(of: databaseIDs) {
            try writeRecovery(try JSONEncoder().encode(state))
        }
        try writeManifest(state)
        return state
    }
    func save(_ state: PersistedDeck, revision: UInt64, allowedRemovedProfileIDs: Set<UUID> = []) throws {
        guard revision >= latestRevision else { return }
        let data = try JSONEncoder().encode(state)
        let db = try connection(); defer { sqlite3_close(db) }
        let recovery = try FileManager.default.fileExists(atPath: recoveryURL.path)
            ? JSONDecoder().decode(PersistedDeck.self, from: Data(contentsOf: recoveryURL)) : nil
        var previousStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM deck_state WHERE id=1", -1, &previousStatement, nil) == SQLITE_OK else {
            throw DeckError.message("Cannot inspect the saved profile registry before writing.")
        }
        defer { sqlite3_finalize(previousStatement) }
        var savedIDs = Set(recovery?.profiles.map(\.id) ?? [])
        if sqlite3_step(previousStatement) == SQLITE_ROW, let bytes = sqlite3_column_blob(previousStatement, 0) {
            let previous = try JSONDecoder().decode(PersistedDeck.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(previousStatement, 0))))
            savedIDs.formUnion(previous.profiles.map(\.id))
        }
        let proposedIDs = Set(state.profiles.map(\.id))
        guard savedIDs.subtracting(proposedIDs).isSubset(of: allowedRemovedProfileIDs) else {
            throw DeckError.message("Profile Deck stopped a save that would discard registered profiles. Reopen the manager and recover the saved registry before making changes.")
        }
        if proposedIDs.isEmpty && allowedRemovedProfileIDs.isEmpty {
            let managedProfiles = directory.appendingPathComponent("Profiles", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: managedProfiles, includingPropertiesForKeys: nil)) ?? []
            guard entries.isEmpty else {
                throw DeckError.message("Profile Deck stopped an empty startup state from replacing existing profile folders. Restore the saved registry before continuing.")
            }
        }
        try writeRecovery(data)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO deck_state(id,schema_version,payload) VALUES(1,1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw DeckError.message("Cannot prepare manager save.") }
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw DeckError.message("The manager could not save changes. Check available disk space.") }
        latestRevision = revision
        try writeManifest(state)
    }
    private func writeRecovery(_ data: Data) throws {
        try data.write(to: recoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
    }
    // A rebuildable view of the database, never a second configuration authority.
    private func writeManifest(_ state: PersistedDeck) throws {
        struct Manifest: Encodable {
            var schemaVersion = 1
            var sharedWorld: SharedWorld
            var desiredIntegrations: [PortableIntegration]
        }
        let portable = PortableConfiguration(state: state)
        let value = Manifest(sharedWorld: state.world, desiredIntegrations: portable.integrations)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent("shared-world.json")
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

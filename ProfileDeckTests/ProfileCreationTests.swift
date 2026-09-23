import XCTest
@testable import ProfileDeck

final class ProfileCreationTests: XCTestCase {
    @MainActor func testRegistrationReturnsSavedProfileWithoutProviderPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(directory: root.appendingPathComponent("manager"), demo: false)
        model.deck.world.sourceHome = root.appendingPathComponent("unavailable-source").path
        model.search = "old search"
        model.section = .settings
        let profile = try await model.addProfile(name: "  New account  ", authMode: .subscription,
            homePath: root.appendingPathComponent("home").path,
            dataPath: root.appendingPathComponent("data").path, adoptExisting: false, startAtLogin: true)
        XCTAssertEqual(profile.name, "New account")
        XCTAssertTrue(profile.startAtLogin)
        XCTAssertTrue(profile.createdByDeck)
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertEqual(model.section, .profiles)
        XCTAssertEqual(model.visibleProfiles.map(\.id), [profile.id])
        XCTAssertTrue(model.deck.transactions.isEmpty, "Registration must not wait for provider configuration")
        XCTAssertTrue(model.runtime.isEmpty, "Registration must not wait for a global refresh")
        let saved = try await DeckStore(directory: root.appendingPathComponent("manager")).load()
        XCTAssertEqual(saved?.profiles, [profile])
        let marker = URL(fileURLWithPath: profile.homePath).appendingPathComponent(".profile-deck-owner")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), profile.id.uuidString)
        do {
            try await model.addProfile(name: "Duplicate", authMode: .subscription,
                homePath: profile.homePath, dataPath: profile.dataPath, adoptExisting: false)
            XCTFail("The same folders cannot be registered twice")
        } catch { XCTAssertEqual(model.deck.profiles.count, 1) }
    }

    @MainActor func testAdoptionPreservesExistingFolderContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let sentinel = home.appendingPathComponent("existing.txt")
        try "preserve".write(to: sentinel, atomically: true, encoding: .utf8)
        let model = AppModel(directory: root.appendingPathComponent("manager"), demo: false)
        let profile = try await model.addProfile(name: "Adopted", authMode: .subscription,
            homePath: home.path, dataPath: data.path, adoptExisting: true)
        XCTAssertFalse(profile.createdByDeck)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".profile-deck-owner").path))
    }
}

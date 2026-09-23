import XCTest
@testable import ProfileDeck

final class LoginItemServiceTests: XCTestCase {
    func testOnlyFreshRealInstallRegistersDefault() {
        XCTAssertTrue(shouldRegister())
        XCTAssertTrue(shouldRegister(status: .notFound))
        XCTAssertFalse(shouldRegister(isDemo: true))
        XCTAssertFalse(shouldRegister(isNewInstallation: false))
        XCTAssertFalse(shouldRegister(initializationRecorded: true))
        XCTAssertFalse(shouldRegister(requestedEnabled: false))
        for status in [LoginItemStatus.enabled, .requiresApproval, .unknown] {
            XCTAssertFalse(shouldRegister(status: status))
        }
    }

    func testExistingOptOutAndSystemDisableNeverAutoRegister() {
        XCTAssertFalse(shouldRegister(isNewInstallation: false, requestedEnabled: false))
        XCTAssertFalse(shouldRegister(isNewInstallation: false, status: .notRegistered))
        XCTAssertFalse(shouldRegister(isNewInstallation: false, status: .requiresApproval))
        XCTAssertFalse(shouldRegister(initializationRecorded: true, status: .notRegistered))
        XCTAssertFalse(shouldRegister(initializationRecorded: true, status: .requiresApproval))
    }

    @MainActor func testRegistrationReportsApprovalInsteadOfClaimingEnabled() throws {
        let service = FakeLoginItemService()
        service.registrationResult = .requiresApproval
        XCTAssertEqual(try service.setEnabled(true), .requiresApproval)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(try service.setEnabled(true), .requiresApproval)
        XCTAssertEqual(service.registrations, 1)
    }

    @MainActor func testEnabledRegistrationIsIdempotent() throws {
        let service = FakeLoginItemService()
        XCTAssertEqual(try service.setEnabled(true), .enabled)
        XCTAssertEqual(try service.setEnabled(true), .enabled)
        XCTAssertEqual(service.registrations, 1)
    }

    @MainActor func testDisableCancelsPendingApprovalAndIsIdempotent() throws {
        let service = FakeLoginItemService()
        service.status = .requiresApproval
        XCTAssertEqual(try service.setEnabled(false), .notRegistered)
        XCTAssertEqual(try service.setEnabled(false), .notRegistered)
        XCTAssertEqual(service.unregistrations, 1)
    }

    @MainActor func testRegistrationFailureRemainsVisibleAndDoesNotInventState() {
        let service = FakeLoginItemService()
        service.mutationError = .operationFailed
        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertEqual(error as? FakeLoginItemService.Failure, .operationFailed)
        }
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertEqual(service.registrations, 1)
    }

    @MainActor func testUnregistrationFailurePreservesObservedEnabledState() {
        let service = FakeLoginItemService()
        service.status = .enabled
        service.mutationError = .operationFailed
        XCTAssertThrowsError(try service.setEnabled(false))
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(service.unregistrations, 1)
    }

    @MainActor func testFreshInstallRegistersOnceAndPreservesLaterSystemDisable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeLoginItemService()
        let model = AppModel(directory: directory, demo: false, loginItemService: service)
        await model.initializeLoginItem(isNewInstallation: true)
        await model.initializeLoginItem(isNewInstallation: true)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(model.loginItemStatus, .enabled)
        XCTAssertEqual(model.deck.settings.launchAtLoginInitialized, true)
        try await model.flushForExit()

        let loaded = try await DeckStore(directory: directory).load()
        let stored = try XCTUnwrap(loaded)
        XCTAssertTrue(stored.settings.launchAtLogin)
        XCTAssertEqual(stored.settings.launchAtLoginInitialized, true)
        service.status = .notRegistered
        let nextLaunch = AppModel(directory: directory, demo: false, loginItemService: service)
        nextLaunch.deck = stored
        await nextLaunch.initializeLoginItem(isNewInstallation: false)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(nextLaunch.loginItemStatus, .notRegistered)
        XCTAssertFalse(nextLaunch.deck.settings.launchAtLogin)
        try await nextLaunch.flushForExit()
    }

    @MainActor func testExistingOptOutStaysOffDuringMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeLoginItemService()
        let model = AppModel(directory: directory, demo: false, loginItemService: service)
        model.deck.settings.launchAtLogin = false
        await model.initializeLoginItem(isNewInstallation: false)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertFalse(model.deck.settings.launchAtLogin)
        XCTAssertEqual(model.deck.settings.launchAtLoginInitialized, true)
        try await model.flushForExit()
        let loaded = try await DeckStore(directory: directory).load()
        let stored = try XCTUnwrap(loaded)
        XCTAssertFalse(stored.settings.launchAtLogin)
        XCTAssertEqual(stored.settings.launchAtLoginInitialized, true)
    }

    @MainActor func testDemoNeverChangesLoginItemsOrCreatesStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = FakeLoginItemService()
        let model = AppModel(directory: directory, demo: true, loginItemService: service)
        await model.initializeLoginItem(isNewInstallation: true)
        model.setLaunchAtLogin(true)
        model.setLaunchAtLogin(false)
        model.refreshLoginItemStatus()
        try await model.flushForExit()
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertNil(model.deck.settings.launchAtLoginInitialized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLegacySettingsKeepOptOutWhileNewSettingsDefaultOn() throws {
        XCTAssertTrue(DeckSettings().launchAtLogin)
        var legacy = DeckSettings()
        legacy.launchAtLogin = false
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "launchAtLoginInitialized")
        let decoded = try JSONDecoder().decode(DeckSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.launchAtLogin)
        XCTAssertNil(decoded.launchAtLoginInitialized)
    }

    @MainActor func testSettingsStatusRefreshBeforeInitializationCannotSaveDefaultDeck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeLoginItemService()
        let model = AppModel(directory: directory, demo: false, loginItemService: service)
        model.refreshLoginItemStatus()
        XCTAssertTrue(model.deck.settings.launchAtLogin)
        XCTAssertNil(model.deck.settings.launchAtLoginInitialized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try await model.flushForExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        await model.initializeLoginItem(isNewInstallation: true)
        XCTAssertEqual(service.registrations, 1)
        try await model.flushForExit()
    }

    private func shouldRegister(
        isDemo: Bool = false,
        isNewInstallation: Bool = true,
        initializationRecorded: Bool = false,
        requestedEnabled: Bool = true,
        status: LoginItemStatus = .notRegistered
    ) -> Bool {
        LoginItemPolicy.shouldRegisterByDefault(
            isDemo: isDemo,
            isNewInstallation: isNewInstallation,
            initializationRecorded: initializationRecorded,
            requestedEnabled: requestedEnabled,
            status: status
        )
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    enum Failure: Error, Equatable { case operationFailed }
    var status: LoginItemStatus = .notRegistered
    var registrationResult: LoginItemStatus = .enabled
    var mutationError: Failure?
    private(set) var registrations = 0
    private(set) var unregistrations = 0

    func register() throws {
        registrations += 1
        if let mutationError { throw mutationError }
        status = registrationResult
    }

    func unregister() throws {
        unregistrations += 1
        if let mutationError { throw mutationError }
        status = .notRegistered
    }

    func openSystemSettings() {}
}

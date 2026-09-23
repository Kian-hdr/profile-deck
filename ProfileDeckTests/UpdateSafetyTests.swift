import XCTest
@testable import ProfileDeck

final class UpdateSafetyTests: XCTestCase {
    @MainActor func testOverlappingCompanionOperationsWaitForEveryCompletion() {
        let model = AppModel(demo: true)
        XCTAssertFalse(model.hasActiveUpdateWork)
        model.beginUpdateWork()
        model.beginUpdateWork()
        XCTAssertTrue(model.hasActiveUpdateWork)
        model.endUpdateWork()
        XCTAssertTrue(model.hasActiveUpdateWork)
        model.endUpdateWork()
        XCTAssertFalse(model.hasActiveUpdateWork)
        model.isLoading = true
        XCTAssertTrue(model.hasActiveUpdateWork)
        model.isLoading = false
        XCTAssertFalse(model.hasActiveUpdateWork)
    }

    @MainActor func testRunningNativeTaskDoesNotBlockCompanionUpdate() {
        let model = AppModel(demo: true)
        let id = UUID()
        model.deck.tasks = [TaskObservation(id: "fixture", profileID: id, turnID: "turn", title: "Independent native task", state: .running)]
        model.runtime[id] = RuntimeSnapshot(profileID: id, state: .open)
        XCTAssertFalse(model.hasActiveUpdateWork)
        XCTAssertEqual(model.deck.tasks.first?.state, .running)
        XCTAssertEqual(model.runtime[id]?.state, .open)
    }

    @MainActor func testQueuedSaveBlocksBeforeTaskStartsThenClearsAfterSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, demo: false)
        model.saveHandoff(Handoff(title: "Saved before update"))
        // No suspension has occurred: a quit request on the next event sees busy.
        XCTAssertTrue(model.hasActiveUpdateWork)
        try await waitUntilIdle(model)
        let saved = try await DeckStore(directory: directory).load()
        XCTAssertEqual(saved?.handoffs.first?.title, "Saved before update")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testFailedQueuedSaveClearsBusyAndKeepsError() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let blockedDirectory = parent.appendingPathComponent("file-not-directory")
        try Data("fixture".utf8).write(to: blockedDirectory)
        let model = AppModel(directory: blockedDirectory, demo: false)
        model.saveHandoff(Handoff(title: "Retained in memory"))
        XCTAssertTrue(model.hasActiveUpdateWork)
        try await waitUntilIdle(model)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.deck.handoffs.first?.title, "Retained in memory")
        XCTAssertEqual(try Data(contentsOf: blockedDirectory), Data("fixture".utf8))
    }

    @MainActor func testAsyncMutationValidationFailureDoesNotLeaveBusy() async {
        let model = AppModel(demo: true)
        do {
            try await model.saveInstructions(text: "Fixture", expectedHash: "fixture")
            XCTFail("Demo writes must fail")
        } catch {}
        XCTAssertFalse(model.hasActiveUpdateWork)
        do {
            try await model.addProfile(name: "Fixture", authMode: .subscription, homePath: "", dataPath: "", adoptExisting: false)
            XCTFail("Demo creation must fail")
        } catch {}
        XCTAssertFalse(model.hasActiveUpdateWork)
    }

    @MainActor func testExportFailureClearsBusyWithoutChangingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(demo: true)
        do {
            try await model.exportConfiguration(to: directory)
            XCTFail("An existing directory cannot be replaced by an export")
        } catch {}
        XCTAssertFalse(model.hasActiveUpdateWork)
        XCTAssertTrue(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @MainActor private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.hasActiveUpdateWork, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.hasActiveUpdateWork, "Companion operation did not finish")
    }
}

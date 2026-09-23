import XCTest
@testable import ProfileDeck

@MainActor
final class ProfileActivationTests: XCTestCase {
    func testRunningAccountFailureOffersPermissionRecoveryWithoutCreationCopy() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(directory: root, demo: true)
        model.reportOpenFailure(WindowAccessibilityError(), profileName: "Example One", isRunning: true)
        XCTAssertTrue(model.errorOffersAccessibility)
        XCTAssertTrue(model.errorMessage?.contains("Could not bring Example One's window forward") == true)
        XCTAssertFalse(model.errorMessage?.contains("registration") == true)
        XCTAssertFalse(model.errorMessage?.contains("Could not open") == true)
        model.errorMessage = nil
        XCTAssertFalse(model.errorOffersAccessibility)
    }

    func testUnrelatedFailureClearsPermissionRecovery() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(directory: root, demo: true)
        model.reportOpenFailure(WindowAccessibilityError(), profileName: "Example One", isRunning: true)
        model.report(DeckError.message("Other failure"))
        XCTAssertFalse(model.errorOffersAccessibility)
        XCTAssertEqual(model.errorMessage, "Other failure")
    }

    func testClosedAccountFailureUsesOpenRetryCopy() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(directory: root, demo: true)
        model.reportOpenFailure(DeckError.message("Client unavailable"), profileName: "Example One", isRunning: false)
        XCTAssertTrue(model.errorMessage?.contains("Could not open Example One") == true)
        XCTAssertFalse(model.errorOffersAccessibility)
    }

    func testNewSelectionCancelsOlderFocusWithoutCancellingTheNewOne() async throws {
        let requests = LatestFocusRequest()
        var firstStarted = false
        var secondCompleted = false
        let first = Task {
            try await requests.run {
                firstStarted = true
                try await Task.sleep(for: .seconds(30))
                XCTFail("Superseded focus must not finish or report a stale error")
            }
        }
        while !firstStarted { await Task.yield() }
        try await requests.run { secondCompleted = true }
        do { try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(secondCompleted)
    }
    func testAlreadyActiveDoesNotBecomeFalseFailure() async throws {
        var requests = 0
        try await ProfileActivation.confirm(observe: { .active }, request: { _ in requests += 1; return false }, attempts: 0)
        XCTAssertEqual(requests, 0)
    }

    func testDelayedActivationIsConfirmedEvenIfRequestReturnsFalse() async throws {
        var state = ProfileActivation.State.inactive
        var requests = 0
        var waits = 0
        try await ProfileActivation.confirm(observe: { state }, request: { _ in requests += 1; return false }, attempts: 3, wait: {
            waits += 1
            if waits == 2 { state = .active }
        })
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(waits, 2)
    }

    func testAcceptedRequestWithoutForegroundEvidenceFails() async {
        var waits = 0
        do {
            try await ProfileActivation.confirm(observe: { .inactive }, request: { _ in true }, attempts: 2, wait: { waits += 1 })
            XCTFail("Accepted request is not evidence of activation")
        } catch {
            XCTAssertEqual(error as? ProfileActivation.Failure, .notActivated)
        }
        XCTAssertEqual(waits, 2)
    }

    func testFailedHandoffRetriesOnceAndConfirmsEvidence() async throws {
        var active = false
        var requests: [Bool] = []
        try await ProfileActivation.confirm(observe: { active ? .active : .inactive }, request: { retry in
            requests.append(retry)
            if retry { active = true }
            return true
        }, attempts: 3, retryAt: 1, wait: {})
        XCTAssertEqual(requests, [false, true])
    }

    func testRetryRemainsBoundedWithoutEvidence() async {
        var requests: [Bool] = []
        do {
            try await ProfileActivation.confirm(observe: { .inactive }, request: { retry in requests.append(retry); return true }, attempts: 5, retryAt: 1, wait: {})
            XCTFail("Request acceptance alone must not count as success")
        } catch { XCTAssertEqual(error as? ProfileActivation.Failure, .notActivated) }
        XCTAssertEqual(requests, [false, true])
    }

    func testCancelledWaitDoesNotRetry() async {
        var requests = 0
        do {
            try await ProfileActivation.confirm(observe: { .inactive }, request: { retry in
                requests += 1
                XCTAssertFalse(retry)
                return true
            }, retryAt: 1, wait: { throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 1)
    }

    func testDoesNotSendUnobservableRetryAtDeadline() async {
        var requests = 0
        do {
            try await ProfileActivation.confirm(observe: { .inactive }, request: { _ in requests += 1; return true }, attempts: 1, retryAt: 1, wait: {})
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? ProfileActivation.Failure, .notActivated) }
        XCTAssertEqual(requests, 1)
    }

    func testChangedIdentityPreventsRequest() async {
        var requests = 0
        do {
            try await ProfileActivation.confirm(observe: { .invalid }, request: { _ in requests += 1; return true })
            XCTFail("Invalid identity must fail closed")
        } catch { XCTAssertEqual(error as? ProfileActivation.Failure, .identityChanged) }
        XCTAssertEqual(requests, 0)
    }

    func testIdentityChangeDuringActivationStopsWithoutRetry() async {
        var state = ProfileActivation.State.inactive
        var requests = 0
        do {
            try await ProfileActivation.confirm(observe: { state }, request: { _ in requests += 1; return true }, wait: { state = .invalid })
            XCTFail("Reused or exited process must fail closed")
        } catch { XCTAssertEqual(error as? ProfileActivation.Failure, .identityChanged) }
        XCTAssertEqual(requests, 1)
    }
}

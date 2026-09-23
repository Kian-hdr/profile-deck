import XCTest
@testable import ProfileDeck

final class ProcessActivationBridgeTests: XCTestCase {
    func testUnknownProcessCannotResolve() {
        var reference = PDProcessReference()
        XCTAssertNotEqual(PDResolveProcess(-1, &reference), 0)
    }

    func testProcessReferenceCannotActivateDifferentPID() {
        var reference = PDProcessReference()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(PDResolveProcess(currentPID, &reference), 0)
        // Wrong PID must fail before activation. Never activate a real app in tests.
        XCTAssertNotEqual(PDActivateProcess(reference, -1, true), 0)
    }
}

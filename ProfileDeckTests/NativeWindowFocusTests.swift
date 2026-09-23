import XCTest
import CoreGraphics
@testable import ProfileDeck

final class NativeWindowFocusTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private func entry(_ id: UInt32, pid: Int32 = 42, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }
    func testFullScreenArrivalRequiresTheSelectedWindow() {
        let target = WindowFocusTarget(windowID: 7, fullScreen: true, accessibilityAvailable: true)
        XCTAssertFalse(NativeWindowFocus.visible(pid: 42, target: target, entries: [entry(8)]))
        XCTAssertTrue(NativeWindowFocus.visible(pid: 42, target: target, entries: [entry(7)]))
    }
    func testAmbiguousFullScreenIdentityDoesNotClaimArrival() {
        let target = WindowFocusTarget(fullScreen: true, accessibilityAvailable: true)
        XCTAssertFalse(NativeWindowFocus.visible(pid: 42, target: target, entries: [entry(7), entry(8)]))
        XCTAssertNil(NativeWindowFocus.matchingWindowID(pid: 42, bounds: bounds, entries: [entry(7), entry(8)]))
    }
    func testAnotherProfileOrOverlayDoesNotCount() {
        let target = WindowFocusTarget(fullScreen: false, accessibilityAvailable: false)
        XCTAssertFalse(NativeWindowFocus.visible(pid: 42, target: target, entries: [entry(7, pid: 99), entry(8, layer: 3)]))
        XCTAssertFalse(NativeWindowFocus.visible(pid: 42, target: target, entries: [entry(7, alpha: 0)]))
    }
    func testUniqueFrameMatchesOnlyTheVerifiedProcess() {
        XCTAssertEqual(NativeWindowFocus.matchingWindowID(pid: 42, bounds: bounds, entries: [entry(7), entry(8, pid: 99)]), 7)
    }
    func testWindowOnAnotherSpaceDoesNotCountAsVisible() {
        let target = WindowFocusTarget(windowID: 7, fullScreen: true, accessibilityAvailable: true)
        XCTAssertFalse(NativeWindowFocus.visible(pid: 42, target: target, entries: []))
    }
    func testWithoutPermissionOneWindowCanBeVerifiedButMultipleCannot() {
        let single = NativeWindowFocus.withoutAccessibility(pid: 42, entries: [entry(7), entry(9, pid: 99)])
        XCTAssertEqual(single.windowID, 7)
        XCTAssertTrue(NativeWindowFocus.visible(pid: 42, target: single, entries: [entry(7)]))
        let multiple = NativeWindowFocus.withoutAccessibility(pid: 42, entries: [entry(7), entry(8)])
        XCTAssertFalse(NativeWindowFocus.visible(pid: 42, target: multiple, entries: [entry(8)]))
    }
}

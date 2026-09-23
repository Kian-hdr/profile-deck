import AppKit
import SwiftUI
import XCTest
@testable import ProfileDeck

final class MenuPopoverTests: XCTestCase {
    func testMenuCardHeightFollowsThatCardOnly() {
        let noUsage = MenuProfileCardLayout.minimumHeight(meterRows: 0)
        let oneMeter = MenuProfileCardLayout.minimumHeight(meterRows: 1)
        let twoMeters = MenuProfileCardLayout.minimumHeight(meterRows: 2)
        let earnedCredit = MenuProfileCardLayout.minimumHeight(meterRows: 1, hasResetCredit: true)
        XCTAssertLessThan(noUsage, oneMeter)
        XCTAssertEqual(twoMeters - oneMeter, MenuProfileCardLayout.meterHeight)
        XCTAssertEqual(earnedCredit - oneMeter, MenuProfileCardLayout.resetCreditHeight)
        XCTAssertEqual(MenuProfileCardLayout.meterRows(showsUsage: true, hasAPISpend: true, windowCount: 0), 1)
        XCTAssertEqual(MenuProfileCardLayout.meterRows(showsUsage: true, hasAPISpend: false, windowCount: 2), 2)
        XCTAssertEqual(MenuProfileCardLayout.meterRows(showsUsage: false, hasAPISpend: false, windowCount: 3), 0)
    }
    func testFewProfilesUseTheirFullHeight() {
        for count in [1, 2, 3, 5] {
            let natural = MenuPopoverLayout.rowsHeight(count: count, rowHeight: 60)
            XCTAssertEqual(MenuPopoverLayout.listHeight(naturalHeight: natural, screenHeight: 800, chromeHeight: 145), natural)
        }
    }
    func testScrollingStartsOnlyAtScreenLimit() {
        let available: CGFloat = 800 - 145 - 24
        XCTAssertEqual(MenuPopoverLayout.listHeight(naturalHeight: available, screenHeight: 800, chromeHeight: 145), available)
        XCTAssertEqual(MenuPopoverLayout.listHeight(naturalHeight: available + 1, screenHeight: 800, chromeHeight: 145), available)
        let fifty = MenuPopoverLayout.rowsHeight(count: 50, rowHeight: 60)
        XCTAssertEqual(MenuPopoverLayout.listHeight(naturalHeight: fifty, screenHeight: 800, chromeHeight: 145), available)
    }
    func testCurrentScreenAndLargerRowsChangeCapacity() {
        let natural = MenuPopoverLayout.rowsHeight(count: 10, rowHeight: 80)
        let small = MenuPopoverLayout.listHeight(naturalHeight: natural, screenHeight: 700, chromeHeight: 180)
        let large = MenuPopoverLayout.listHeight(naturalHeight: natural, screenHeight: 1200, chromeHeight: 180)
        XCTAssertEqual(small, 496)
        XCTAssertEqual(large, natural)
        XCTAssertEqual(MenuPopoverLayout.listHeight(naturalHeight: natural, screenHeight: 100, chromeHeight: 180), 0)
    }
    @MainActor func testTwoProfilesRenderWithoutScrollView() async throws {
        let model = AppModel(demo: true)
        await model.bootstrap()
        model.deck.profiles = Array(model.deck.profiles.prefix(2))
        let host = NSHostingView(rootView: MenuContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSScrollView }.isEmpty, "Two profiles must not be placed in a scroll view")
        XCTAssertGreaterThan(host.fittingSize.height, 240, "Both complete account rows and controls must contribute to fitting height")
        XCTAssertLessThan(host.fittingSize.height, 380, "Two-account popup should remain compact")
    }
    @MainActor func testMultipleQuotaWindowsFitWithoutScrollingOrInventedLimits() async throws {
        let model = AppModel(demo: true)
        await model.bootstrap()
        model.deck.profiles = Array(model.deck.profiles.prefix(2))
        let windows = [
            UsageWindow(id: "codex:primary", usedPercent: 50, durationMinutes: 10080),
            UsageWindow(id: "spark:primary", usedPercent: 85, durationMinutes: 300, bucketName: "Example Spark"),
            UsageWindow(id: "spark:secondary", usedPercent: 96, durationMinutes: 10080, bucketName: "Example Spark")
        ]
        let snapshot = UsageSnapshot(profileID: model.deck.profiles[0].id, windows: windows, observedAuthMode: .subscription)
        model.deck.usage = [snapshot]
        XCTAssertEqual(snapshot.displayWindows.map(\.id), windows.map(\.id))
        XCTAssertEqual(snapshot.displayWindows.filter { $0.durationMinutes == 300 }.count, 1)
        var api = snapshot; api.observedAuthMode = .apiKey
        XCTAssertTrue(api.displayWindows.isEmpty)
        let host = NSHostingView(rootView: MenuContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSScrollView }.isEmpty)
        XCTAssertLessThan(host.fittingSize.height, 520)
        XCTAssertGreaterThan(host.fittingSize.height, 350)
        let allVisibleHeight = host.fittingSize.height
        model.deck.profiles[0].hiddenMenuUsageWindowIDs = ["spark:primary", "spark:secondary"]
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let oneVisibleHeight = host.fittingSize.height
        XCTAssertLessThan(oneVisibleHeight, allVisibleHeight - 40)
        model.deck.profiles[0].showMenuUsage = false
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, oneVisibleHeight - 20, "Hiding this profile's preview must shrink only its card")
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSScrollView }.isEmpty)
    }
    @MainActor func testAPIBudgetBarFitsAndRespectsPreviewToggle() async throws {
        let model = AppModel(demo: true)
        await model.bootstrap()
        model.deck.profiles = Array(model.deck.profiles.prefix(1))
        model.deck.profiles[0].authMode = .apiKey
        let spend = APISpendSnapshot(sourceID: "fixture", sourceName: "Example API", todayUSD: 2, monthUSD: 25,
            fetchedAt: Date(), currentDayAvailable: true, budgetAmountUSD: 100, budgetUsedUSD: 25, budgetKind: "creditBalance", budgetAsOf: Date())
        model.deck.usage = [UsageSnapshot(profileID: model.deck.profiles[0].id, observedAuthMode: .apiKey, apiSpend: spend)]
        let host = NSHostingView(rootView: MenuContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 350), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let visibleHeight = host.fittingSize.height
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSScrollView }.isEmpty)
        XCTAssertGreaterThan(visibleHeight, 220)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeck-API-menu-fixture.png"))
            }
        }
        model.deck.profiles[0].showMenuUsage = false
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.height, visibleHeight - 30)
    }
    @MainActor func testOpeningFailureCanBringManagerForward() async {
        let model = AppModel(demo: true)
        await model.bootstrap()
        var surfaced = false
        model.open(model.deck.profiles[0], onFailure: { surfaced = true })
        XCTAssertTrue(surfaced)
        XCTAssertNotNil(model.errorMessage)
    }
    @MainActor func testFiftyProfilesScrollWithinScreen() async throws {
        let model = AppModel(demo: true)
        await model.bootstrap()
        model.deck.profiles = (1...50).map { Profile(name: "Example \($0)", homePath: "/demo/\($0)/home", dataPath: "/demo/\($0)/data", manualOrder: $0) }
        let host = NSHostingView(rootView: MenuContentView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrolls.count, 1, "Only the account list should scroll")
        XCTAssertLessThanOrEqual(host.fittingSize.height, (window.screen ?? NSScreen.main)!.visibleFrame.height - 23)
        XCTAssertGreaterThan(scrolls.first?.documentView?.frame.height ?? 0, 3000, "All fifty rows remain reachable")
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

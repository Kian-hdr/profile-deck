import AppKit
import XCTest
@testable import ProfileDeck

@MainActor
final class ProfileDetailsInteractionTests: XCTestCase {
    func testInspectorContentReservesSpaceForBothScrollbarStyles() {
        let clearance = ProfileInspectorLayout.scrollerClearance
        for style in [NSScroller.Style.overlay, .legacy] {
            XCTAssertGreaterThan(clearance, NSScroller.scrollerWidth(for: .regular, scrollerStyle: style))
        }
        XCTAssertLessThan(clearance, 24, "Keep the gutter modest in the 240-point inspector")
    }

    func testFirstPointerSelectionKeepsGeometryStableUntilSingleClickIsConfirmed() async throws {
        let interaction = ProfileDetailsInteraction()
        var reveals = 0
        interaction.deferPointerReveal(delay: .milliseconds(60)) { reveals += 1 }
        XCTAssertTrue(interaction.pointerSelectionPending)
        XCTAssertFalse(interaction.shouldRevealForSelection(isKeyboard: false), "Native first-click selection must not shrink the table before a possible second click")
        XCTAssertEqual(reveals, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reveals, 1)
        XCTAssertFalse(interaction.pointerSelectionPending)
    }

    func testNativePrimaryActionCancelsDelayedSingleClickReveal() async throws {
        let interaction = ProfileDetailsInteraction()
        var delayedReveals = 0
        interaction.deferPointerReveal(delay: .milliseconds(40)) { delayedReveals += 1 }
        XCTAssertFalse(interaction.shouldRevealForSelection(isKeyboard: false))
        // The native primaryAction owns opening; cancelling the first-click timer
        // prevents a second presentation after focus moves to the native account.
        interaction.cancelPendingReveal()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(delayedReveals, 0)
        XCTAssertFalse(interaction.pointerSelectionPending)
    }

    func testKeyboardSelectionIsImmediateAndCancelsPointerTimer() async throws {
        let interaction = ProfileDetailsInteraction()
        var delayedReveals = 0
        interaction.deferPointerReveal(delay: .milliseconds(40)) { delayedReveals += 1 }
        XCTAssertTrue(interaction.shouldRevealForSelection(isKeyboard: true))
        XCTAssertFalse(interaction.pointerSelectionPending)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(delayedReveals, 0)
    }

    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Account \(row)" }
    }

    func testSelectedRowCanBeClickedAgainWithoutConsumingNativeDoubleClick() async throws {
        let rows = Rows()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let table = NSTableView(frame: content.bounds)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.dataSource = rows
        table.rowHeight = 30
        table.reloadData()
        content.addSubview(table)
        let observer = ProfileTableClickView(frame: content.bounds)
        content.addSubview(observer)
        window.contentView = content
        defer { observer.stopObserving(); window.close() }
        var clicked: [Int] = []
        observer.onRowClick = { clicked.append($0) }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let point = table.convert(NSPoint(x: 20, y: table.rect(ofRow: 1).midY), to: nil)
        func event(_ count: Int, point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        let first = try event(1, point: point)
        XCTAssertTrue(observer.observe(first) === first)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(clicked, [1])
        // Hiding details does not change table selection. A later single click
        // must still notify the view; the double-click's second event must pass on.
        let secondSingle = try event(1, point: point)
        _ = observer.observe(secondSingle)
        let double = try event(2, point: point)
        XCTAssertTrue(observer.observe(double) === double)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(clicked, [1, 1])
        XCTAssertEqual(table.selectedRow, 1)
        let empty = try event(1, point: table.convert(NSPoint(x: 20, y: 250), to: nil))
        _ = observer.observe(empty)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(clicked, [1, 1], "Empty table space must not reopen details")
        XCTAssertNil(observer.hitTest(.zero), "The observer must not intercept native table input")
    }
}

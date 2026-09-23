import XCTest
import AppKit
import SwiftUI
@testable import ProfileDeck

final class FloatingTabsLayoutTests: XCTestCase {
    func testRuntimePresentationKeepsClosedTabsReadableAndHonest() {
        let closed = FloatingTabPresentation(state: .closed)
        XCTAssertEqual(closed.action, "Open")
        XCTAssertTrue(closed.allowsActivation)
        XCTAssertLessThan(closed.opacity, 1)
        XCTAssertTrue(closed.detail.contains("Confirmed closed"))

        let running = FloatingTabPresentation(state: .open)
        XCTAssertEqual(running.action, "Focus")
        XCTAssertTrue(running.allowsActivation)
        XCTAssertEqual(running.opacity, 1)

        for state in [ProcessState.launching, .unknown, .unresponsive] {
            XCTAssertFalse(FloatingTabPresentation(state: state).allowsActivation)
        }
    }
    func testFiveAndTenProfilesFitOneRowAtPreferredWidth() {
        for count in [5, 10] {
            let width = FloatingTabsLayout.preferredWidth(count: count, maximumWidth: 1600)
            let layout = FloatingTabsLayout(width: width, count: count)
            XCTAssertEqual(layout.visibleCount, count)
            XCTAssertEqual(layout.overflowCount, 0)
            XCTAssertGreaterThanOrEqual(layout.tabWidth, FloatingTabsLayout.minimumTabWidth)
            XCTAssertEqual(FloatingTabsLayout.panelHeight, 46)
            XCTAssertLessThanOrEqual(width, 1600)
            assertRegionsFit(layout, width: width)
        }
    }
    func testNarrowDisplayUsesExplicitOverflowWithoutShrinkingTargets() {
        let width = FloatingTabsLayout.preferredWidth(count: 10, maximumWidth: 360)
        let layout = FloatingTabsLayout(width: width, count: 10)
        XCTAssertEqual(width, 360)
        XCTAssertGreaterThan(layout.overflowCount, 0)
        XCTAssertEqual(layout.visibleCount + layout.overflowCount, 10)
        XCTAssertGreaterThanOrEqual(layout.tabWidth, FloatingTabsLayout.minimumTabWidth)
        assertRegionsFit(layout, width: width)
    }
    func testLargeSetStaysBoundedAndEveryProfileIsReachable() {
        for count in [20, 50, 100] {
            let width = FloatingTabsLayout.preferredWidth(count: count, maximumWidth: 1440)
            let layout = FloatingTabsLayout(width: width, count: count)
            XCTAssertEqual(width, 1440)
            XCTAssertEqual(layout.visibleCount + layout.overflowCount, count)
            XCTAssertGreaterThan(layout.overflowCount, 0)
            XCTAssertGreaterThanOrEqual(layout.tabWidth, FloatingTabsLayout.minimumTabWidth)
            assertRegionsFit(layout, width: width)
        }
    }
    @MainActor func testLongSimilarNamesStayInFixedRowWithoutScrollViews() async throws {
        let model = AppModel(demo: true)
        await model.bootstrap()
        model.deck.profiles = (1...10).map {
            Profile(name: "Exlumina Research and Development Account \($0)", homePath: "/demo/\($0)/home", dataPath: "/demo/\($0)/data", manualOrder: $0)
        }
        for width: CGFloat in [360, 744, 1404] {
            let host = NSHostingView(rootView: FloatingTabsView(model: model, maximumWidth: width))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: FloatingTabsLayout.panelHeight), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.height, FloatingTabsLayout.panelHeight, accuracy: 0.5)
            XCTAssertEqual(host.bounds.width, width, accuracy: 0.5)
            XCTAssertTrue(descendants(host).compactMap { $0 as? NSScrollView }.isEmpty)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeck-floating-tabs-\(Int(width)).png"))
                }
            }
            window.close()
        }
    }
    @MainActor func testClosingTabsClearsVisibilityAndSamePanelReopens() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("FloatingTabsClose-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:directory) }
        let model=AppModel(directory:directory,demo:true)
        await model.bootstrap()
        let tabVisibility=model.deck.profiles.map(\.tabVisible)
        let controller=PanelController(model:model)
        model.deck.settings.showFloatingTabs=true
        let panel=try XCTUnwrap(controller.applyFloatingTabsVisibility())
        XCTAssertTrue(panel.isVisible)
        panel.close()
        XCTAssertFalse(model.deck.settings.showFloatingTabs)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(model.deck.profiles.map(\.tabVisible), tabVisibility)
        model.deck.settings.showFloatingTabs=true
        let reopened=try XCTUnwrap(controller.applyFloatingTabsVisibility())
        XCTAssertTrue(reopened === panel)
        XCTAssertTrue(reopened.isVisible)
        NotificationCenter.default.post(name:.deckHideTabs,object:nil)
        XCTAssertFalse(model.deck.settings.showFloatingTabs)
        XCTAssertFalse(panel.isVisible)
        NotificationCenter.default.post(name:.deckHideTabs,object:nil)
        XCTAssertFalse(model.deck.settings.showFloatingTabs, "Hide must not toggle the strip back on")
        XCTAssertEqual(model.deck.profiles.map(\.tabVisible), tabVisibility)
        panel.close()
    }
    func testPointerMovementThresholdPreservesClicksAndSuppressesDrags() {
        var gesture=FloatingTabsPointerGesture()
        gesture.begin(at:CGPoint(x:10,y:20))
        XCTAssertFalse(gesture.move(to:CGPoint(x:14,y:20)))
        XCTAssertTrue(gesture.end())
        gesture.begin(at:CGPoint(x:10,y:20))
        XCTAssertTrue(gesture.move(to:CGPoint(x:13,y:24)))
        XCTAssertTrue(gesture.move(to:CGPoint(x:10,y:20)), "Returning to the origin must not reactivate a click")
        XCTAssertFalse(gesture.end())
        gesture.begin(at:.zero); gesture.cancel()
        XCTAssertFalse(gesture.end())
        XCTAssertFalse(gesture.move(to:CGPoint(x:100,y:100)))
    }
    @MainActor func testFloatingPanelDeliversClickOnlyAfterRelease() async throws {
        final class Receiver: NSObject {
            var clicks=0
            @objc func clicked(_ sender: Any?) { clicks += 1 }
        }
        let receiver=Receiver()
        let panel=FloatingTabsPanel(contentRect:NSRect(x:0,y:0,width:300,height:46),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false
        let button=NSButton(title:"Example account",target:receiver,action:#selector(Receiver.clicked(_:)))
        button.frame=NSRect(x:0,y:0,width:200,height:46)
        let content=NSView(frame:NSRect(x:0,y:0,width:300,height:46)); content.addSubview(button); panel.contentView=content
        panel.orderFront(nil)
        defer { panel.close() }
        let down=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:NSPoint(x:50,y:20),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
        let up=try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:NSPoint(x:50,y:20),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime+0.01,windowNumber:panel.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0))
        panel.sendEvent(down)
        XCTAssertEqual(receiver.clicks,0)
        panel.sendEvent(up)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(receiver.clicks,1)
    }
    private func assertRegionsFit(_ layout: FloatingTabsLayout, width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layout.tabsWidth + layout.controlWidth + FloatingTabsLayout.gap + FloatingTabsLayout.padding * 2, width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(CGFloat(layout.visibleCount) * layout.tabWidth + CGFloat(max(0, layout.visibleCount - 1)) * FloatingTabsLayout.gap, layout.tabsWidth, accuracy: 0.01, file: file, line: line)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

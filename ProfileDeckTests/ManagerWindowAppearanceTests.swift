import AppKit
import XCTest
@testable import ProfileDeck

final class ManagerWindowAppearanceTests: XCTestCase {
    @MainActor func testOptInRestoresInheritedAppearanceWithoutChangingOtherWindows() {
        let originalAppAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppAppearance }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let manager = NSWindow(contentRect: NSRect(x:0,y:0,width:800,height:560),styleMask:[.titled],backing:.buffered,defer:false)
            let popover = NSWindow(contentRect: NSRect(x:0,y:0,width:360,height:500),styleMask:[.borderless],backing:.buffered,defer:false)
            manager.isReleasedWhenClosed = false; popover.isReleasedWhenClosed = false
            let originalBackground = manager.backgroundColor
            let originalTitlebar = manager.titlebarAppearsTransparent
            let originalOpaque = manager.isOpaque
            let otherBackground = popover.backgroundColor
            let controller = ManagerWindowAppearanceController()
            controller.apply(to: manager, enabled: true)
            XCTAssertEqual(manager.appearance?.name, .darkAqua)
            XCTAssertEqual(manager.backgroundColor, .black)
            XCTAssertTrue(manager.titlebarAppearsTransparent)
            XCTAssertNil(popover.appearance)
            XCTAssertEqual(popover.backgroundColor, otherBackground)
            XCTAssertEqual(NSApp.appearance?.name, appearance)
            controller.apply(to: manager, enabled: false)
            XCTAssertNil(manager.appearance)
            XCTAssertEqual(manager.backgroundColor, originalBackground)
            XCTAssertEqual(manager.titlebarAppearsTransparent, originalTitlebar)
            XCTAssertEqual(manager.isOpaque, originalOpaque)
            manager.close(); popover.close()
        }
    }
    @MainActor func testMovingThemeToAnotherWindowRestoresOriginal() {
        let first = NSWindow(contentRect:.zero,styleMask:[],backing:.buffered,defer:false)
        let second = NSWindow(contentRect:.zero,styleMask:[],backing:.buffered,defer:false)
        first.isReleasedWhenClosed=false; second.isReleasedWhenClosed=false
        first.appearance=NSAppearance(named:.aqua)
        let controller=ManagerWindowAppearanceController()
        controller.apply(to:first,enabled:true)
        controller.apply(to:second,enabled:true)
        XCTAssertEqual(first.appearance?.name,.aqua)
        XCTAssertEqual(second.appearance?.name,.darkAqua)
        controller.restore()
        XCTAssertNil(second.appearance)
        first.close();second.close()
    }
}

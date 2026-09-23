import AppKit
import SwiftUI
import XCTest
@testable import ProfileDeck

final class NavigationLayoutTests: XCTestCase {
    @MainActor func testInspectorScrollbarStylesAtNarrowWidths() async throws {
        let model = AppModel(demo: true)
        await model.bootstrap()
        let profile = try XCTUnwrap(model.deck.profiles.first)
        model.deck.usage = [UsageSnapshot(profileID: profile.id, windows: [
            UsageWindow(id: "codex:weekly", usedPercent: 64, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(86400))
        ], source: "Synthetic visual test", observedAuthMode: .subscription, planName: "Self_Serve_Business_Prolite")]
        let output = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProfileDeck/Inspector-Visual-QA", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 740),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        // Ordering this private test window lets AppKit complete rendering before
        // sampling pixels. It does not change any macOS preference or profile.
        window.orderFront(nil)
        defer { window.close(); model.stopMonitoring() }
        for width: CGFloat in [240, 280, 360] {
            window.setContentSize(NSSize(width: width, height: 740))
            for (name, style) in [("overlay", NSScroller.Style.overlay), ("legacy", .legacy)] {
                let host = NSHostingView(rootView: ProfileInspector(model: model, profile: profile, edit: {}, quit: {}, login: {}))
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 740)
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                let scrollViews = descendants(host).compactMap { $0 as? NSScrollView }
                XCTAssertFalse(scrollViews.isEmpty, "Expected a native inspector scroll view")
                for scroll in scrollViews {
                    scroll.scrollerStyle = style
                    scroll.hasVerticalScroller = true
                    scroll.autohidesScrollers = false
                    scroll.tile()
                    scroll.flashScrollers()
                }
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                for view in descendants(host) { view.needsDisplay = true }
                host.needsDisplay = true
                host.displayIfNeeded()
                XCTAssertEqual(host.bounds.width, width, accuracy: 1)
                for scroll in scrollViews {
                    XCTAssertEqual(scroll.scrollerStyle, style)
                    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(clip.minX, -1)
                    XCTAssertLessThanOrEqual(clip.maxX, width + 1)
                    // Check real AppKit controls where SwiftUI uses them. Other
                    // rendered SwiftUI controls are covered by the PNG review.
                    let controls = descendants(scroll).compactMap { $0 as? NSControl }.filter { !($0 is NSScroller) && !$0.isHiddenOrHasHiddenAncestor }
                    for control in controls {
                        let rect = control.convert(control.bounds, to: host)
                        guard rect.intersects(clip) else { continue }
                        XCTAssertGreaterThanOrEqual(rect.minX, clip.minX - 1)
                        let reserved = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
                        XCTAssertLessThanOrEqual(rect.maxX, clip.maxX - reserved + 1, "A clickable control must stay clear of the trailing scroller")
                    }
                    print("Inspector QA width=\(width) style=\(name) nativeControls=\(controls.count) clip=\(clip)")
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                var paintedSamples = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                        if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { paintedSamples += 1 }
                    }
                }
                XCTAssertGreaterThan(paintedSamples, 100, "A blank offscreen capture cannot establish visual QA")
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let url = output.appendingPathComponent("inspector-\(Int(width))-\(name).png")
                try png.write(to: url)
                print("Inspector QA image: \(url.path)")
            }
        }
    }

    @MainActor func testPageSwitchesKeepSplitViewInsideViewport() async throws {
        let model = AppModel(demo: true)
        await model.bootstrap()
        let host = NSHostingView(rootView: RootView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); model.stopMonitoring() }
        window.orderFront(nil)
        // This host checks layout only; scene restoration is exercised in the app.
        try await Task.sleep(for: .milliseconds(100))
        for size in [NSSize(width: 1100, height: 740), NSSize(width: 800, height: 560), NSSize(width: 1400, height: 800)] {
            window.setContentSize(size)
            // WindowServer can clamp the requested size to a smaller CI display.
            // Compare each destination against the actual size before switching.
            let initialContentSize = window.contentView!.bounds.size
            for section in [AppSection.diagnostics, .handoffs, .integrations, .activity, .world, .profiles, .settings, .profiles, .settings] {
                model.section = section
                try await Task.sleep(for: .milliseconds(60))
                host.layoutSubtreeIfNeeded()
                let splits = descendants(host).compactMap { $0 as? NSSplitView }
                XCTAssertFalse(splits.isEmpty, "Expected the native navigation split view")
                for split in splits where !split.isHidden {
                    let rect = split.convert(split.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(rect.minY, -1, "\(section): split above viewport")
                    XCTAssertLessThanOrEqual(rect.maxY, host.bounds.maxY + 1, "\(section): split exceeds viewport")
                    XCTAssertGreaterThanOrEqual(rect.minX, -1, "\(section): split left of viewport")
                    XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX + 1, "\(section): split exceeds width")
                }
                if section == .profiles, size.width <= 1100 {
                    for table in descendants(host).compactMap({ $0 as? NSTableView }) where !table.isHiddenOrHasHiddenAncestor {
                        guard let clip = table.enclosingScrollView?.contentView else { continue }
                        let columnsWidth = table.tableColumns.reduce(CGFloat.zero) { $0 + $1.width }
                        XCTAssertLessThanOrEqual(columnsWidth, clip.bounds.width + 1, "Compact profile columns must fit when details are visible")
                    }
                }
                // A destination's ideal height must not resize the enclosing window.
                XCTAssertEqual(window.contentView!.bounds.width, initialContentSize.width, accuracy: 1)
                XCTAssertEqual(window.contentView!.bounds.height, initialContentSize.height, accuracy: 1)
            }
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

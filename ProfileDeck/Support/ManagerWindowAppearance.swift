import AppKit
import SwiftUI

/// Applies the opt-in theme only to the manager's native window, never NSApp.
@MainActor final class ManagerWindowAppearanceController {
    private struct Baseline {
        var appearance: NSAppearance?
        var background: NSColor
        var transparentTitlebar: Bool
        var opaque: Bool
    }
    private weak var window: NSWindow?
    private var baseline: Baseline?

    func apply(to target: NSWindow?, enabled: Bool) {
        if window !== target { restore(); window = target }
        guard let target else { return }
        guard enabled else { restore(); window = target; return }
        if baseline == nil {
            baseline = Baseline(appearance: target.appearance, background: target.backgroundColor,
                                transparentTitlebar: target.titlebarAppearsTransparent, opaque: target.isOpaque)
        }
        target.appearance = NSAppearance(named: .darkAqua)
        // Vercel Dark chromeTheme.surface is #000000; raised content uses palette layers.
        target.backgroundColor = .black
        target.titlebarAppearsTransparent = true
        target.isOpaque = true
    }

    func restore() {
        if let window, let baseline {
            window.appearance = baseline.appearance
            window.backgroundColor = baseline.background
            window.titlebarAppearsTransparent = baseline.transparentTitlebar
            window.isOpaque = baseline.opaque
        }
        baseline = nil
    }
}

struct ManagerWindowAppearance: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }
    func updateNSView(_ view: AppearanceView, context: Context) {
        view.enabled = enabled
        view.controller.apply(to: view.window, enabled: enabled)
    }
    static func dismantleNSView(_ view: AppearanceView, coordinator: ()) { view.controller.restore() }

    final class AppearanceView: NSView {
        var enabled = false
        let controller = ManagerWindowAppearanceController()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.apply(to: window, enabled: enabled)
        }
    }
}

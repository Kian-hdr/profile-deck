import AppKit
import SwiftUI

/// Uses the screen containing the actual status-item window, not the manager's screen.
nonisolated enum MenuPopoverLayout {
    static let rowSpacing: CGFloat = 4
    static let outerPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static func rowsHeight(count: Int, rowHeight: CGFloat) -> CGFloat {
        guard count > 0 else { return 64 }
        return CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing
    }
    static func listHeight(naturalHeight: CGFloat, screenHeight: CGFloat, chromeHeight: CGFloat) -> CGFloat {
        min(naturalHeight, max(0, screenHeight - chromeHeight - 24))
    }
}

@MainActor final class MenuWindowContext {
    weak var window: NSWindow?
    func dismiss() { window?.orderOut(nil) }
}

struct MenuScreenReader: NSViewRepresentable {
    var context: MenuWindowContext
    var onScreenHeight: (CGFloat) -> Void
    var onPresent: () -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.onWindow = { window in self.context.window = window }
        view.onScreenHeight = onScreenHeight
        view.onPresent = onPresent
        view.scheduleScreenUpdate()
    }
    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        var onScreenHeight: ((CGFloat) -> Void)?
        var onPresent: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            onWindow?(window)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(presented), name: NSWindow.didBecomeKeyNotification, object: window)
            scheduleScreenUpdate()
        }
        @objc private func screenChanged() { scheduleScreenUpdate() }
        @objc private func presented() {
            scheduleScreenUpdate()
            DispatchQueue.main.async { [weak self] in self?.onPresent?() }
        }
        func scheduleScreenUpdate() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onWindow?(window)
                let screen = window?.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                if let screen { onScreenHeight?(screen.visibleFrame.height) }
            }
        }
    }
}

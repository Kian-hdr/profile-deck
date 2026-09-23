import ApplicationServices
import Foundation

struct WindowAccessibilityError: LocalizedError, Sendable {
    var errorDescription: String? {
        "The account is running, but Profile Deck cannot identify its selected window without Accessibility access. Open Accessibility Settings and enable Profile Deck, then select the account again. If it is already enabled, quit and reopen Profile Deck to recheck access."
    }
}

struct WindowFocusTarget: Sendable {
    var windowID: CGWindowID?
    var fullScreen: Bool
    var accessibilityAvailable: Bool
    var requiresExactWindow = false
}

/// Accessibility calls stay off the UI actor and have bounded IPC timeouts.
actor NativeWindowFocus {
    static let shared = NativeWindowFocus()

    func prepare(identity: NativeProcessIdentity) throws -> WindowFocusTarget {
        guard NativeAdapter.readIdentity(pid: identity.pid) == identity else { throw ProfileActivation.Failure.identityChanged }
        guard AXIsProcessTrusted() else {
            return Self.withoutAccessibility(pid: identity.pid, entries: Self.windowEntries(onScreen: false))
        }
        let application = AXUIElementCreateApplication(identity.pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let focused = element(application, kAXFocusedWindowAttribute)
        let main = element(application, kAXMainWindowAttribute)
        // Follow the most recently focused/main window, including its Space.
        // Do not bypass a dialog or pick an arbitrary older full-screen window.
        // Some clients have no focused/main attribute while inactive or starting.
        // A single AX window is unambiguous; multiple windows still fail closed.
        let windows = value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = focused ?? main ?? (windows.count == 1 ? windows.first : nil) else {
            return WindowFocusTarget(fullScreen: false, accessibilityAvailable: true, requiresExactWindow: true)
        }
        AXUIElementSetMessagingTimeout(window, 0.15)
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == identity.pid,
              NativeAdapter.readIdentity(pid: identity.pid) == identity else { throw ProfileActivation.Failure.identityChanged }
        let fullScreen = bool(window, "AXFullScreen")
        let bounds = frame(window)
        let targetID = bounds.flatMap { Self.uniqueWindowID(pid: identity.pid, bounds: $0) }
        func validate() throws {
            try Task.checkCancellation()
            guard NativeAdapter.readIdentity(pid: identity.pid) == identity else { throw ProfileActivation.Failure.identityChanged }
        }
        // Never toggle full screen, move a window, or alter the global Spaces preference.
        if bool(window, kAXMinimizedAttribute) {
            try validate()
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        try validate()
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        try validate()
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return WindowFocusTarget(windowID: targetID, fullScreen: fullScreen, accessibilityAvailable: true, requiresExactWindow: true)
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool { (value(element, attribute) as? Bool) == true }
    private func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = value(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    nonisolated static func windowEntries(onScreen: Bool) -> [[String: Any]] {
        CGWindowListCopyWindowInfo([onScreen ? .optionOnScreenOnly : .optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }
    nonisolated static func uniqueWindowID(pid: Int32, bounds: CGRect) -> CGWindowID? {
        matchingWindowID(pid: pid, bounds: bounds, entries: windowEntries(onScreen: false))
    }
    nonisolated static func withoutAccessibility(pid: Int32, entries: [[String: Any]]) -> WindowFocusTarget {
        let ids = entries.compactMap { entry -> CGWindowID? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return WindowFocusTarget(windowID: ids.count == 1 ? ids[0] : nil, fullScreen: false,
                                 accessibilityAvailable: false, requiresExactWindow: true)
    }
    nonisolated static func matchingWindowID(pid: Int32, bounds: CGRect, entries: [[String: Any]]) -> CGWindowID? {
        let matches = entries.filter {
            guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = $0[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary) else { return false }
            return abs(frame.minX - bounds.minX) < 2 && abs(frame.minY - bounds.minY) < 2
                && abs(frame.width - bounds.width) < 2 && abs(frame.height - bounds.height) < 2
        }
        guard matches.count == 1 else { return nil }
        return (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
    nonisolated static func isVisible(pid: Int32, target: WindowFocusTarget) -> Bool {
        visible(pid: pid, target: target, entries: windowEntries(onScreen: true))
    }
    nonisolated static func visible(pid: Int32, target: WindowFocusTarget, entries: [[String: Any]]) -> Bool {
        // An unrelated desktop window cannot establish arrival in a full-screen Space.
        if (target.fullScreen || target.requiresExactWindow) && target.windowID == nil { return false }
        return entries.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && (target.windowID == nil || ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID)
                && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
        }
    }
}

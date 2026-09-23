import AppKit
import ApplicationServices
import OSLog

/// Activation is asynchronous. A request's return value is not foreground evidence.
@MainActor
enum ProfileActivation {
    enum State { case invalid, inactive, active }
    enum Failure: Error { case identityChanged, notActivated, windowNotVisible, accessibilityRequired, windowSelectionUnavailable }
    private static let logger = Logger(subsystem: "space.exlumina.profiledeck", category: "Activation")
    private static let requests = LatestFocusRequest()

    static func focus(identity: NativeProcessIdentity, userInitiated: Bool) async throws {
        try await requests.run { try await performFocus(identity: identity, userInitiated: userInitiated) }
    }

    private static func application(for identity: NativeProcessIdentity) throws -> NSRunningApplication {
        try Task.checkCancellation()
        guard NativeAdapter.readIdentity(pid: identity.pid) == identity,
              let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated else {
            throw Failure.identityChanged
        }
        return app
    }

    private static func performFocus(identity: NativeProcessIdentity, userInitiated: Bool) async throws {
        _ = try application(for: identity)
        // AX preparation can yield and raise a window. Do it before acquiring the
        // activation donor, so it cannot invalidate a handoff already in progress.
        var target = try await NativeWindowFocus.shared.prepare(identity: identity)
        logger.info("Window target; accessibility=\(target.accessibilityAvailable), fullScreen=\(target.fullScreen), identified=\(target.windowID != nil)")
        try await confirm(observe: {
            guard let app = try? application(for: identity) else { return .invalid }
            return app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.pid ? .active : .inactive
        }, request: { retry in
            let app = try application(for: identity)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(50))
                    _ = try application(for: identity)
                    if app.isActive { return true }
                    if NSApp.isActive { break }
                }
            }
            _ = try application(for: identity)
            logger.info("Activation request; retry=\(retry), donor active=\(NSApp.isActive)")
            if NSApp.isActive && !retry {
                NSApp.yieldActivation(to: app)
                return app.activate(from: .current, options: [])
            }
            // Public exact-process activation is independent of the cooperative
            // donor. Never reopen by bundle ID, which could select another account.
            if app.activate(options: []) { return true }
            // macOS can reject both AppKit requests for concurrently running
            // instances of the same client. This public, deprecated compatibility
            // API addresses an exact process, and is used only after rejection.
            var serial = PDProcessReference()
            guard PDResolveProcess(identity.pid, &serial) == noErr else { return false }
            _ = try application(for: identity)
            let status = PDActivateProcess(serial, identity.pid, userInitiated)
            logger.info("Exact-process compatibility activation; status=\(status)")
            return status == noErr
        })
        // The client may publish its focused window only after activation. Recheck
        // once instead of polling an unidentified target that can never succeed.
        // Never replace an already selected window with a different one.
        if target.windowID == nil {
            target = try await NativeWindowFocus.shared.prepare(identity: identity)
        }
        // Activation and arrival at the selected window are separate evidence.
        // Allow a Space transition to finish without sending more activation requests.
        do {
            try await confirm(observe: {
                guard let app = try? application(for: identity) else { return .invalid }
                return app.isActive && NativeWindowFocus.isVisible(pid: identity.pid, target: target) ? .active : .inactive
            }, request: { _ in false }, attempts: 60, retryAt: nil)
        } catch Failure.notActivated {
            if !(try application(for: identity)).isActive { throw Failure.notActivated }
            if target.accessibilityAvailable && target.windowID == nil { throw Failure.windowSelectionUnavailable }
            if !target.accessibilityAvailable && target.windowID == nil { throw Failure.accessibilityRequired }
            throw Failure.windowNotVisible
        }
    }

    static func confirm(
        observe: () -> State,
        request: (_ retry: Bool) async throws -> Bool,
        attempts: Int = 40,
        retryAt: Int? = 10,
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }
    ) async throws {
        try Task.checkCancellation()
        switch observe() {
        case .invalid: throw Failure.identityChanged
        case .active: return
        case .inactive: break
        }
        let accepted = try await request(false)
        logger.info("Activation requested; accepted=\(accepted)")
        for index in 0...attempts {
            try Task.checkCancellation()
            switch observe() {
            case .invalid: throw Failure.identityChanged
            case .active:
                logger.info("Activation confirmed for the verified profile process")
                return
            case .inactive: break
            }
            if index == retryAt && index < attempts {
                let retried = try await request(true)
                logger.info("Activation retried; accepted=\(retried)")
            }
            if index < attempts { try await wait() }
        }
        logger.error("Activation could not be confirmed within the deadline")
        throw Failure.notActivated
    }
}

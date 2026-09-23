import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

@MainActor
protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

extension LoginItemServicing {
    /// Return the system's result, which can require approval even after registration succeeds.
    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> LoginItemStatus {
        let current = status
        if enabled {
            if current != .enabled && current != .requiresApproval { try register() }
        } else if current != .notRegistered {
            try unregister()
        }
        return status
    }
}

@MainActor
final class SystemLoginItemService: LoginItemServicing {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws {
        try requireLiveApplication()
        try service.register()
    }

    func unregister() throws {
        try requireLiveApplication()
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func requireLiveApplication() throws {
        let arguments = CommandLine.arguments
        let environment = ProcessInfo.processInfo.environment
        guard !arguments.contains("--demo"), !arguments.contains("--demo-scale"),
              environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil,
              NSClassFromString("XCTestCase") == nil else {
            throw LoginItemServiceError.demoOrTestProcess
        }
    }
}

enum LoginItemServiceError: LocalizedError {
    case demoOrTestProcess

    var errorDescription: String? {
        "Login items cannot be changed in demo or test mode."
    }
}

enum LoginItemPolicy {
    /// The caller must persist its initialization marker before attempting registration.
    /// Existing preferences and a later change in System Settings never trigger automatic repair.
    static func shouldRegisterByDefault(
        isDemo: Bool,
        isNewInstallation: Bool,
        initializationRecorded: Bool,
        requestedEnabled: Bool,
        status: LoginItemStatus
    ) -> Bool {
        !isDemo && isNewInstallation && !initializationRecorded && requestedEnabled
            && (status == .notRegistered || status == .notFound)
    }
}

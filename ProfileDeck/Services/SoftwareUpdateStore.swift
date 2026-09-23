import AppKit
import Combine
import Observation
import Sparkle

struct UpdateConfiguration {
    static let stableFeed = "https://raw.githubusercontent.com/Kian-hdr/profile-deck/updates/stable/appcast.xml"
    static let testingFeed = "https://raw.githubusercontent.com/Kian-hdr/profile-deck/updates/testing/appcast.xml"
    let feedURL: URL

    init?(info: [String: Any]) {
        guard let feed = info["SUFeedURL"] as? String,
              [Self.stableFeed, Self.testingFeed].contains(feed),
              let url = URL(string: feed),
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0 else { return nil }
        feedURL = url
    }
}

@MainActor @Observable
final class SoftwareUpdateStore: NSObject, SPUUpdaterDelegate {
    static let shared = SoftwareUpdateStore()
    private(set) var isConfigured = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticChecks = false
    private(set) var automaticDownloads = false
    private(set) var lastCheck: Date?
    private(set) var status: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var configuration: UpdateConfiguration?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var deferredInstall: Task<Void, Never>?

    func configure(model: AppModel) {
        guard controller == nil, !model.isDemo,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        self.model = model
        guard let config = UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) else {
            status = "Signed updates are unavailable in this build."
            return
        }
        configuration = config
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.clearFeedURLFromUserDefaults()
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticChecks = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] in self?.automaticDownloads = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] in self?.lastCheck = $0 }.store(in: &subscriptions)
        do { try updater.start(); isConfigured = true }
        catch { status = "Could not start software updates: \(error.localizedDescription)" }
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller?.updater.automaticallyDownloadsUpdates = enabled }
    func checkForUpdates() {
        guard isConfigured, canCheckForUpdates else { return }
        status = nil
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    static func hasOpenEditor() -> Bool { NSApp.windows.contains { $0.attachedSheet != nil } }

    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        deferredInstall?.cancel()
        status = "Update ready. Finish any open editors and saves before restarting."
        deferredInstall = Task { [weak self] in
            guard let self else { return }
            await UpdateRelaunchGate.run(
                isBusy: { self.model?.hasActiveUpdateWork != false || Self.hasOpenEditor() },
                flush: { try await self.model?.flushForExit() },
                reportError: { self.status = "Update is waiting because changes could not be saved: \($0.localizedDescription)" },
                install: { self.status = nil; installHandler() })
        }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        deferredInstall?.cancel(); deferredInstall = nil
        status = error.localizedDescription
    }
}

@MainActor enum UpdateRelaunchGate {
    /// Keep Sparkle's one-shot continuation alive across temporary save failures.
    static func run(isBusy: () -> Bool, flush: () async throws -> Void,
                    reportError: (Error) -> Void, install: () -> Void,
                    retryDelay: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            if !isBusy() {
                do {
                    try await flush()
                    if !Task.isCancelled, !isBusy() { install(); return }
                } catch { reportError(error) }
            }
            do { try await Task.sleep(for: retryDelay) } catch { return }
        }
    }
}

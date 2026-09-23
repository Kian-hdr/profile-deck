import Foundation
import AppKit
import Observation

@MainActor @Observable final class AppModel {
    var deck = PersistedDeck()
    var section: AppSection = .profiles
    var selectedProfileID: UUID? {
        didSet {
            guard bootstrapped, !isLoading, selectedProfileID != oldValue else { return }
            deck.lastSelectedProfileID = selectedProfileID
            if activeUpdateOperations == 0 { persist() }
        }
    }
    var search = ""
    var order: ProfileOrder = .manual
    var showHidden = false
    var isLoading = false
    var errorMessage: String? { didSet { errorOffersAccessibility = false } }
    var errorOffersAccessibility = false
    var runtime: [UUID:RuntimeSnapshot] = [:]
    var sharing: [UUID:SharedInspection] = [:]
    var candidates: [Profile] = []
    var shortcutError: String?
    var loginItemStatus: LoginItemStatus = .notRegistered
    var loginItemError: String?
    let isDemo: Bool
    @ObservationIgnored private var managerLock: ManagerInstanceLock?
    @ObservationIgnored private let storageDirectory: URL
    private(set) var storageFailure: String?
    @ObservationIgnored private let store: DeckStore
    @ObservationIgnored private let loginItemService: any LoginItemServicing
    @ObservationIgnored private var loginItemReady = false
    @ObservationIgnored private let native = NativeAdapter()
    @ObservationIgnored private let shared = SharingService()
    @ObservationIgnored private let integrations = IntegrationService()
    @ObservationIgnored private var monitor: Task<Void,Never>?
    @ObservationIgnored private var startup: Task<Void,Never>?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var usageChecks: [UUID: (next: Date, failures: Int)] = [:]
    private(set) var opening: Set<UUID> = []
    private var activeUpdateOperations = 0
    @ObservationIgnored private var deliveringNotifications: Set<String> = []
    @ObservationIgnored let notifications = NotificationService()
    var visibleProfiles: [Profile] { DeckLogic.sorted(deck.profiles, query: search, order: order, showHidden: showHidden, tasks: deck.tasks, usage: deck.usage) }
    var selectedProfile: Profile? { deck.profiles.first { $0.id == selectedProfileID } }
    var storageAvailable: Bool { canSave }
    // Only companion-owned operations block replacement. Native provider tasks
    // continue independently and must never prevent or be stopped by an update.
    var hasActiveUpdateWork: Bool { isLoading || !opening.isEmpty || activeUpdateOperations > 0 }
    func beginUpdateWork() { activeUpdateOperations += 1 }
    func endUpdateWork() {
        precondition(activeUpdateOperations > 0, "Unbalanced update operation")
        activeUpdateOperations -= 1
    }
    init(directory: URL? = nil, demo: Bool = CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }) || CommandLine.arguments.contains(where: { $0.contains(".xctest") }), loginItemService: (any LoginItemServicing)? = nil) {
        isDemo = demo
        self.loginItemService = loginItemService ?? SystemLoginItemService()
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(demo ? "Profile Deck Demo" : "Profile Deck")
        storageDirectory = base
        store = DeckStore(directory: base)
    }
    func bootstrap() async {
        guard !bootstrapped else { return }; bootstrapped = true; isLoading = true
        defer { isLoading = false }
        if isDemo { deck = DemoData.make(); deck.settings.launchAtLogin = false; selectedProfileID = deck.profiles.first?.id; for p in deck.profiles { runtime[p.id] = RuntimeSnapshot(profileID: p.id, state: .closed, appVersion: "Demo", detail: "Illustrative profile; no native account connected") }; return }
        do { try acquireManagerStorage() }
        catch { report(error); return }
        guard canSave else { return }
        var isNewInstallation = true
        do { if let saved = try await store.load() { deck = saved; isNewInstallation = false } }
        catch { canSave = false; storageFailure = error.localizedDescription; report(error); return }
        await initializeLoginItem(isNewInstallation: isNewInstallation)
        candidates = await native.discoverKnownProfiles()
        if !deck.onboardingComplete {
            for profile in candidates {
                runtime[profile.id] = await native.inspect(profile: profile)
                sharing[profile.id] = await shared.inspect(profile: profile, world: deck.world)
            }
            if deck.world.workspacePaths.isEmpty {
                let source = deck.world.sourceHome
                deck.world.workspacePaths = await Task.detached {
                    let url = URL(fileURLWithPath:source).appendingPathComponent(".codex-global-state.json")
                    guard let data = try? Data(contentsOf:url), data.count < 10_000_000,
                          let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return [String]() }
                    let roots = object["electron-saved-workspace-roots"] as? [String] ?? []
                    return roots.filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath:$0) }
                }.value
            }
        }
        selectedProfileID = deck.profiles.first(where: { $0.id == deck.lastSelectedProfileID })?.id ?? deck.profiles.first?.id
        await refresh()
        // Explicit opt-in starts native windows only. No model task is submitted.
        if deck.onboardingComplete {
            startup = Task { [weak self] in
                guard let self else { return }
                let ids = deck.profiles.filter(\.startAtLogin).map(\.id)
                for id in ids {
                    guard !Task.isCancelled else { return }
                    guard let profile = deck.profiles.first(where: { $0.id == id }), profile.startAtLogin, runtime[id]?.state == .closed else { continue }
                    open(profile, userInitiated: false)
                    while opening.contains(profile.id) { do { try await Task.sleep(for: .milliseconds(100)) } catch { return } }
                }
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = max(30, self?.deck.settings.refreshSeconds ?? 60)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }
    func refresh() async {
        guard !refreshing, !isDemo else { return }; refreshing = true
        defer { refreshing = false }
        for profile in deck.profiles {
            guard !Task.isCancelled else { return }
            let result = await native.inspect(profile: profile)
            runtime[profile.id] = result
            sharing[profile.id] = await shared.inspect(profile: profile, world: deck.world)
            // Short-lived account readers never observe or resume native tasks.
            if usageChecks[profile.id].map({ $0.next <= Date() }) ?? true {
                let value = await native.usage(profile: profile)
                // A profile can be edited or unregistered while the read is suspended.
                guard let profileIndex = deck.profiles.firstIndex(where: { $0.id == profile.id }),
                      deck.profiles[profileIndex].canonicalHome == profile.canonicalHome,
                      deck.profiles[profileIndex].canonicalData == profile.canonicalData,
                      deck.profiles[profileIndex].appPath == profile.appPath,
                      deck.profiles[profileIndex].billingSourceID == profile.billingSourceID else { continue }
                let failures = value.error == nil ? 0 : min(4, (usageChecks[profile.id]?.failures ?? 0) + 1)
                let retryDelay = min(900, 60 * pow(2, Double(failures)))
                // Closed accounts can be read through the short-lived account helper.
                // Poll them less often so keeping the deck open does not spawn a helper every minute.
                usageChecks[profile.id] = (Date().addingTimeInterval(result.state == .open ? retryDelay : max(300, retryDelay)), failures)
                if let mode = value.observedAuthMode {
                    deck.profiles[profileIndex].verifiedAuthMode = mode
                    deck.profiles[profileIndex].observedAccount = value.accountLabel
                    deck.profiles[profileIndex].identityCheckedAt = value.observedAt
                }
                if let index = deck.usage.firstIndex(where: { $0.profileID == profile.id }) {
                    // Keep the last successful reading dated when offline, never relabel it as fresh.
                    let previous = deck.usage[index]
                    if value.error != nil, value.windows.isEmpty, value.apiSpend == nil,
                       (profile.hasLinkedAPIBilling || (value.observedAuthMode == previous.observedAuthMode &&
                       value.accountLabel == previous.accountLabel)),
                       previous.apiSpend?.sourceID == profile.billingSourceID {
                        var cached = previous; cached.error = value.error
                        deck.usage[index] = cached
                    } else { deck.usage[index] = value }
                } else { deck.usage.append(value) }
            }
            if let value = deck.usage.first(where: { $0.profileID == profile.id }),
               let index = runtime[profile.id]?.capabilities.firstIndex(where: { $0.id == "usage" }) {
                runtime[profile.id]?.capabilities[index] = Capability(id: "usage",
                    available: value.isFresh() || (value.apiSpend != nil && value.error == nil),
                    detail: value.error ?? (value.apiSpend != nil ? "Organization costs from the selected Prompt Balance cache. Native task observation is separate." : "Account quota read from OpenAI. Native task observation is separate."))
            }
        }
        processNotifications()
        persist()
    }
    func refreshAfterClockChange() async {
        usageChecks.removeAll()
        await refresh()
    }
    func billingSources() async throws -> [BillingSource] {
        guard !isDemo else { return [] }
        return try await PromptBalanceUsage().sources()
    }
    func setBillingSource(_ sourceID: String?, for profileID: UUID) {
        guard let index = deck.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        deck.profiles[index].billingSourceID = sourceID
        deck.usage.removeAll { $0.profileID == profileID }
        usageChecks[profileID] = nil
        persist()
        Task {
            while refreshing { do { try await Task.sleep(for: .milliseconds(100)) } catch { return } }
            await refresh()
        }
    }
    func refreshIntegrations() async {
        guard !isDemo else { return }
        let found = await integrations.inventory(profiles: deck.profiles, world: deck.world)
        let desired = deck.integrations.filter { $0.profileID == nil }
        deck.integrations = desired + found.filter { item in !desired.contains(where: { $0.id == item.id && item.profileID == nil }) }
        persist()
    }
    func discoverSkills() async -> [SharedResource] {
        if isDemo { return [SharedResource(id:"demo-writing",name:"Writing",sourcePath:"/Example/Shared/skills/writing/SKILL.md",targetPath:"",state:.shared,detail:"Illustrative shared skill.")] }
        return await shared.discoverSkills(world:deck.world)
    }
    func inspectCandidates(world:SharedWorld) async -> [UUID:SharedInspection] {
        var results:[UUID:SharedInspection]=[:]
        for profile in candidates { if Task.isCancelled { return results }; results[profile.id] = await shared.inspect(profile:profile,world:world) }
        return results
    }
    func stopMonitoring() { monitor?.cancel(); startup?.cancel(); monitor=nil; startup=nil }
    func flushForExit() async throws {
        guard canSave, !isDemo, loginItemReady else { return }
        defer { managerLock = nil }
        try acquireManagerStorage()
        revision += 1
        try await store.save(deck,revision:revision)
    }
    func open(_ profile: Profile, userInitiated: Bool = true, onFailure: (@MainActor () -> Void)? = nil) {
        guard storageAvailable else { errorMessage = "Restore the manager database before opening profiles. Existing native instances remain available independently."; onFailure?(); return }
        guard !isDemo else { errorMessage = "Demo profiles are illustrative. Open the regular app to adopt native profiles."; onFailure?(); return }
        guard !opening.contains(profile.id) else { return }; opening.insert(profile.id)
        Task { defer { opening.remove(profile.id) }
            do {
                if profile.createdByDeck, (await native.inspect(profile: profile)).state != .open {
                    try await Self.prepareOwnedDirectories(profile)
                    if let bootstrap = try await shared.prepareNewProfileSources(profile: profile, world: deck.world) {
                        deck.transactions.append(bootstrap); persist()
                        guard bootstrap.state == .applied else { throw DeckError.message(bootstrap.detail) }
                    }
                    let transaction = try await shared.apply(profile: profile, world: deck.world, allProfiles: deck.profiles)
                    deck.transactions.append(transaction); persist()
                    guard transaction.safeToLaunch == true else { throw DeckError.message(transaction.detail) }
                }
                guard let current = deck.profiles.first(where: { $0.id == profile.id }), current.canonicalHome == profile.canonicalHome, current.canonicalData == profile.canonicalData else { throw DeckError.message("The profile changed while preparing it. Open the current profile again.") }
                runtime[profile.id] = try await native.open(profile: current, userInitiated: userInitiated)
                if let index = deck.profiles.firstIndex(where: { $0.id == profile.id }) { deck.profiles[index].lastFocused = Date(); persist() }
                selectedProfileID = profile.id
                record("Profiles", "Opened selected profile.")
            } catch is CancellationError {
                // A newer tab selection owns focus. Do not surface an obsolete
                // failure or reopen the manager over that destination.
            } catch {
                let snapshot = await native.inspect(profile: profile)
                runtime[profile.id] = snapshot
                reportOpenFailure(error, profileName: profile.name, isRunning: snapshot.state == .open)
                onFailure?()
            }
        }
    }
    func activateFloatingTab(_ profile: Profile) {
        guard storageAvailable, !isDemo else { return }
        guard !opening.contains(profile.id) else { return }
        selectedProfileID = profile.id
        guard let current = deck.profiles.first(where: { $0.id == profile.id }) else { return }
        let state = runtime[profile.id]?.state
        if state == .closed || state == nil {
            open(current)
            return
        }
        guard state == .open else { return }
        Task {
            do {
                try await native.focus(profile: current, userInitiated: true)
                runtime[current.id] = await native.inspect(profile: current)
            } catch is CancellationError {
                // A newer tab selection owns focus.
            } catch is WindowAccessibilityError {
                // The exact window cannot be identified, but the verified process
                // activation has already been requested. Keep the tab interaction
                // quiet; the manager exposes the explicit permission recovery.
                runtime[current.id] = await native.inspect(profile: current)
                record("Profiles", "Selected a running profile; exact window arrival remains unavailable without Accessibility.")
            } catch {
                let snapshot = await native.inspect(profile: current)
                runtime[current.id] = snapshot
                reportOpenFailure(error, profileName: current.name, isRunning: snapshot.state == .open)
            }
        }
    }
    func reportOpenFailure(_ error: Error, profileName: String, isRunning: Bool) {
        let action = isRunning ? "Could not bring \(profileName)'s window forward." : "Could not open \(profileName). Select it and choose Open profile to retry."
        report(error)
        errorMessage = "\(action) \(error.localizedDescription)"
        errorOffersAccessibility = error is WindowAccessibilityError
    }
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        errorMessage = nil
        if !NSWorkspace.shared.open(url) {
            errorMessage = "Open System Settings → Privacy & Security → Accessibility and enable Profile Deck, then select the account again."
        }
    }
    func focus(_ profile: Profile, windowID: Int) { guard allowLiveOperation() else { return }; Task { do { try await native.focus(profile: profile, windowID: windowID, userInitiated: true) } catch { report(error) } } }
    func requestQuit(_ profile: Profile) { guard !isDemo else { return }; Task { do { try await native.quit(profile: profile); await refresh() } catch { report(error) } } }
    @discardableResult func addProfile(name: String, authMode: AuthMode, homePath: String, dataPath: String, adoptExisting: Bool, color: String = "blue", startAtLogin: Bool = false) async throws -> Profile {
        beginUpdateWork(); defer { endUpdateWork() }
        try requireLiveOperation()
        let managerRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Profile Deck/Profiles")
        let id = UUID()
        var profile = Profile(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), authMode: authMode,
                              homePath: homePath.isEmpty ? managerRoot.appendingPathComponent(id.uuidString + "/home").path : homePath,
                              dataPath: dataPath.isEmpty ? managerRoot.appendingPathComponent(id.uuidString + "/data").path : dataPath)
        profile.color = color; profile.createdByDeck = !adoptExisting; profile.manualOrder = deck.profiles.count
        profile.startAtLogin = startAtLogin
        try DeckLogic.validateProfile(profile, against: deck.profiles)
        if !adoptExisting {
            guard !FileManager.default.fileExists(atPath: profile.homePath), !FileManager.default.fileExists(atPath: profile.dataPath) else { throw DeckError.message("A selected folder already exists. Use Adopt existing to preserve its contents.") }
            try await Self.prepareOwnedDirectories(profile)
        } else {
            guard FileManager.default.fileExists(atPath: profile.homePath), FileManager.default.fileExists(atPath: profile.dataPath) else { throw DeckError.message("Both existing profile folders must be available.") }
        }
        // Registration must finish independently of provider setup and quota reads.
        // Opening owns preparation and reports any failure against this saved profile.
        deck.profiles.append(profile)
        selectedProfileID = profile.id
        section = .profiles
        search = ""
        revision += 1
        do { try await store.save(deck, revision: revision) }
        catch {
            canSave = false
            storageFailure = "Could not finish saving \(profile.name). Its folders are preserved at \(profile.homePath). Check available disk space and reopen Profile Deck. If it is absent from the list, use Adopt existing folders to recover it. \(error.localizedDescription)"
            throw DeckError.message(storageFailure!)
        }
        return profile
    }

    func adopt(_ profiles: [Profile], world: SharedWorld) async throws {
        beginUpdateWork(); defer { endUpdateWork() }
        var proposed = deck.profiles
        for var profile in profiles {
            if proposed.contains(where: { $0.canonicalHome == profile.canonicalHome && $0.canonicalData == profile.canonicalData }) { continue }
            try DeckLogic.validateProfile(profile, against: proposed)
            profile.manualOrder = proposed.count; proposed.append(profile)
        }
        deck.profiles = proposed; deck.world = world
        if deck.world.memoryOwnerID == nil { deck.world.memoryOwnerID = proposed.first(where: { $0.canonicalHome == URL(fileURLWithPath: world.sourceHome).resolvingSymlinksInPath().path })?.id }
        deck.onboardingComplete = true; selectedProfileID = proposed.first?.id; persist(); await refresh(); await refreshIntegrations()
    }
    func update(_ profile: Profile) {
        if opening.contains(profile.id), let current = deck.profiles.first(where: { $0.id == profile.id }), (current.homePath != profile.homePath || current.dataPath != profile.dataPath || current.authMode != profile.authMode) { errorMessage = "Wait for this profile to finish opening before changing its configuration."; return }
        do {
            try DeckLogic.validateProfile(profile, against: deck.profiles)
            if let i = deck.profiles.firstIndex(where: { $0.id == profile.id }) {
                let previous = deck.profiles[i]
                var updated = profile
                if previous.canonicalHome != profile.canonicalHome || previous.canonicalData != profile.canonicalData || previous.appPath != profile.appPath {
                    updated.observedAccount = nil; updated.verifiedAuthMode = nil; updated.identityCheckedAt = nil
                    // Organization association was reviewed for the old runtime only.
                    updated.billingSourceID = nil
                    deck.usage.removeAll { $0.profileID == profile.id }
                    usageChecks[profile.id] = nil; runtime[profile.id] = nil; sharing[profile.id] = nil
                }
                deck.profiles[i] = updated
                persist()
            }
        } catch { report(error) }
    }
    func remove(_ profile: Profile) {
        guard !opening.contains(profile.id) else { errorMessage = "Wait for this profile to finish opening before removing it."; return }
        guard deck.world.memoryOwnerID != profile.id else { errorMessage = "This profile owns shared memory generation. Keep it registered until an explicit memory-owner handover is supported."; return }
        beginUpdateWork(); defer { endUpdateWork() }
        deck.profiles.removeAll { $0.id == profile.id }; runtime[profile.id] = nil; sharing[profile.id] = nil
        deck.usage.removeAll { $0.profileID == profile.id }; deck.tasks.removeAll { $0.profileID == profile.id }
        deck.integrations.removeAll { $0.profileID == profile.id }; if selectedProfileID == profile.id { selectedProfileID = deck.profiles.first?.id }
        if deck.world.memoryOwnerID == profile.id { deck.world.memoryOwnerID = nil }
        deck.diagnostics.append(DiagnosticEvent(category: "Profiles", message: "Unregistered profile; native files preserved."))
        persist(allowedRemovedProfileIDs: [profile.id])
    }
    func move(_ profile: Profile, offset: Int) {
        guard order == .manual else {
            errorMessage = "Choose Manual order before reordering profiles. Temporary sorts do not change the saved order."
            return
        }
        var items = DeckLogic.manuallyOrdered(deck.profiles)
        guard let i = items.firstIndex(where: { $0.id == profile.id }) else { return }
        let j = max(0, min(items.count - 1, i + offset)); items.swapAt(i,j)
        for k in items.indices { items[k].manualOrder = k }; deck.profiles = items; persist()
    }
    func reorderManually(moving movingID: UUID, before beforeID: UUID?, visibleIDs: [UUID]) {
        guard order == .manual else {
            errorMessage = "Choose Manual order before dragging profiles. Temporary sorts do not change the saved order."
            return
        }
        guard let reordered = DeckLogic.manualReordering(deck.profiles, moving: movingID, before: beforeID, visibleIDs: visibleIDs) else {
            errorMessage = "That profile order changed before the drag completed. Refresh the list and try again."
            return
        }
        deck.profiles = reordered
        persist()
    }
    func saveWorld(_ world: SharedWorld) {
        guard opening.isEmpty else { errorMessage = "Wait for profiles to finish opening before changing shared sources."; return }
        guard URL(fileURLWithPath: world.sourceHome).resolvingSymlinksInPath().path == URL(fileURLWithPath: deck.world.sourceHome).resolvingSymlinksInPath().path else { errorMessage = "Changing the canonical source requires a verified memory-owner handover. The current shared source is preserved."; return }
        // Ownership changes require a dedicated validated handover; this UI edits paths only.
        var updated = world; updated.memoryOwnerID = deck.world.memoryOwnerID
        updated.revision = UUID().uuidString; updated.updatedAt = Date(); deck.world = updated; persist()
        Task { await refresh() }
    }
    func previewSharing(_ profile:Profile) async throws -> SharingService.ConfigurationPreview {
        if isDemo { return SharingService.ConfigurationPreview(resources:[],token:nil,detail:"Demo preview. No native configuration will be changed.") }
        return try await shared.preview(profile:profile,world:deck.world,allProfiles:deck.profiles)
    }
    func applySharing(_ profile: Profile, expectedPreviewToken:String? = nil) { guard allowLiveOperation() else { return }; beginUpdateWork(); Task { defer { endUpdateWork() }; do { let tx = try await shared.apply(profile: profile, world: deck.world, allProfiles: deck.profiles,expectedPreviewToken:expectedPreviewToken); deck.transactions.append(tx); persist(); await refresh() } catch { report(error) } } }
    func readInstructions() async throws -> (String,String) { if isDemo { return ("# Shared instructions\n\nOne canonical instruction source for every profile.", "demo") }; return try await shared.readInstructions(world: deck.world) }
    func saveInstructions(text: String, expectedHash: String) async throws { beginUpdateWork(); defer { endUpdateWork() }; try requireLiveOperation(); let tx = try await shared.saveInstructions(world: deck.world, text: text, expectedHash: expectedHash); deck.transactions.append(tx); deck.world.revision = UUID().uuidString; persist(); await refresh() }
    func restore(_ transaction: ConfigurationTransaction) { guard allowLiveOperation() else { return }; beginUpdateWork(); Task { defer { endUpdateWork() }; do { try await shared.restore(transaction: transaction); if let i = deck.transactions.firstIndex(where: { $0.id == transaction.id }) { deck.transactions[i].state = .restored }; persist(); await refresh() } catch { report(error) } } }
    func performIntegration(action: String, integration: IntegrationStatus) { guard allowLiveOperation() else { return }; beginUpdateWork(); Task { defer { endUpdateWork() }; do { let result = try await integrations.perform(action: action, integration: integration, profiles: deck.profiles, world: deck.world); deck.transactions.append(contentsOf: result); persist(); await refreshIntegrations() } catch { report(error) } } }
    func openMCPBrowser(profileID: UUID?, copiedLink: Bool = false) {
        guard allowLiveOperation() else { return }
        guard let profile = deck.profiles.first(where: { $0.id == profileID }) else {
            errorMessage = "Select the Codex account that started the MCP sign-in, then open its account browser."
            return
        }
        let link = copiedLink ? NSPasteboard.general.string(forType: .string) ?? "" : nil
        Task {
            do { try await MCPBrowserService.open(profile: profile, copiedAuthorizationLink: link) }
            catch { report(error) }
        }
    }
    func copyMCPLoginCommand(profileID: UUID, serverName: String) {
        guard let profile = deck.profiles.first(where: { $0.id == profileID }) else {
            errorMessage = "Select the account that owns this MCP server before copying its sign-in command."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPBrowserService.loginCommand(profile: profile, serverName: serverName), forType: .string)
    }
    @discardableResult func saveIntegration(_ integration: IntegrationStatus) -> Bool {
        var desired = integration; desired.profileID = nil
        if desired.kind == .plugin, !desired.source.isEmpty {
            do { try IntegrationService.validatePluginSelector(desired.source) }
            catch { report(error); return false }
        } else if desired.kind != .plugin { desired.source = "" }
        desired.id = integration.kind.rawValue + ":" + integration.name.lowercased()
        if let i = deck.integrations.firstIndex(where: { $0.id == desired.id && $0.profileID == nil }) { deck.integrations[i] = desired } else { deck.integrations.append(desired) }
        persist(); return true
    }
    func saveHandoff(_ handoff: Handoff) { var h = handoff; h.updatedAt = Date(); if let i = deck.handoffs.firstIndex(where: { $0.id == h.id }) { deck.handoffs[i] = h } else { deck.handoffs.append(h) }; persist() }
    func removeHandoff(_ id: UUID) { if let handoff = deck.handoffs.first(where: { $0.id == id }) { deck.archivedHandoffs.append(handoff) }; deck.handoffs.removeAll { $0.id == id }; persist() }
    func restoreHandoff(_ id: UUID) { if let handoff = deck.archivedHandoffs.first(where: { $0.id == id }) { deck.archivedHandoffs.removeAll { $0.id == id }; saveHandoff(handoff) } }
    func copyAndOpen(_ handoff: Handoff) {
        guard handoff.ownershipReleased, !handoff.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let profile = deck.profiles.first(where: { $0.id == handoff.destinationProfileID }),
              FileManager.default.fileExists(atPath: handoff.workspacePath) else { errorMessage = "Choose an available workspace and destination, enter the objective, and release source ownership before continuing."; return }
        guard handoff.canTransferSourceContext else {
            errorMessage = "A private or unsupported conversation link cannot transfer to another profile. Replace it with a ChatGPT shared-conversation link, or capture the context in the reviewed brief."
            return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(handoff.rendered, forType: .string)
        var copied = handoff; copied.state = .ready; saveHandoff(copied)
        open(profile)
        record("Handoffs", "Copied reviewed handoff. It was not submitted to the destination.")
    }
    func acknowledgeHandoff(_ id: UUID) { if let i = deck.handoffs.firstIndex(where: { $0.id == id }) { deck.handoffs[i].state = .acknowledged; persist() } }
    func markRead(_ task: TaskObservation) { if let i = deck.tasks.firstIndex(where: { $0.id == task.id && $0.profileID == task.profileID }) { deck.tasks[i].unread = false; persist() } }
    func updateSettings(_ settings: DeckSettings) {
        var proposed = settings
        proposed.refreshSeconds = min(900,max(30,settings.refreshSeconds))
        proposed.warningThreshold = min(98,max(1,settings.warningThreshold)); proposed.criticalThreshold = min(99,max(proposed.warningThreshold+1,settings.criticalThreshold))
        if isDemo { proposed.launchAtLogin = false; proposed.notificationsEnabled = false }
        if !isDemo, proposed.launchAtLogin != deck.settings.launchAtLogin {
            setLaunchAtLogin(proposed.launchAtLogin)
            proposed.launchAtLogin = deck.settings.launchAtLogin
            proposed.launchAtLoginInitialized = deck.settings.launchAtLoginInitialized
        }
        deck.settings = proposed; persist()
        NotificationCenter.default.post(name: .deckSettingsChanged, object: nil)
    }
    func initializeLoginItem(isNewInstallation: Bool) async {
        beginUpdateWork(); defer { endUpdateWork() }
        guard !isDemo, canSave else { return }
        let registerDefault = LoginItemPolicy.shouldRegisterByDefault(
            isDemo: isDemo, isNewInstallation: isNewInstallation,
            initializationRecorded: deck.settings.launchAtLoginInitialized == true,
            requestedEnabled: deck.settings.launchAtLogin, status: loginItemService.status)
        if deck.settings.launchAtLoginInitialized != true {
            deck.settings.launchAtLoginInitialized = true
            // Record the one-shot decision before touching system registration.
            revision += 1
            do { try await store.save(deck, revision: revision) }
            catch { canSave = false; storageFailure = error.localizedDescription; report(error); return }
        }
        loginItemReady = true
        if registerDefault { setLaunchAtLogin(true) }
        else { refreshLoginItemStatus() }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo, canSave, loginItemReady else { return }
        loginItemError = nil
        deck.settings.launchAtLoginInitialized = true
        do { loginItemStatus = try loginItemService.setEnabled(enabled) }
        catch { loginItemError = error.localizedDescription; loginItemStatus = loginItemService.status }
        deck.settings.launchAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        persist()
    }
    func refreshLoginItemStatus() {
        guard !isDemo, canSave, loginItemReady else { return }
        loginItemStatus = loginItemService.status
        let registered = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        if deck.settings.launchAtLogin != registered {
            deck.settings.launchAtLogin = registered
            persist()
        }
    }
    func openLoginItemSettings() { guard !isDemo else { return }; loginItemService.openSystemSettings() }
    func enableNotifications() async { beginUpdateWork(); defer { endUpdateWork() }; guard allowLiveOperation() else { return }; do { deck.settings.notificationsEnabled = try await notifications.requestPermission(); persist() } catch { report(error) } }
    func loginAPI(_ profile: Profile, key: String) { guard allowLiveOperation() else { return }; beginUpdateWork(); Task { defer { endUpdateWork() }; do { try await native.loginAPI(profile: profile, key: key); let identity = try await native.verifyAccount(profile: profile); var p=profile; p.observedAccount=identity.0; p.verifiedAuthMode=identity.1; p.identityCheckedAt=Date(); update(p) } catch { report(error) } } }
    func verifyIdentity(_ profile:Profile) { guard allowLiveOperation() else { return }; beginUpdateWork(); Task { defer { endUpdateWork() }; do { let result = try await native.verifyAccount(profile:profile); var p=profile; p.observedAccount=result.0; p.verifiedAuthMode=result.1; p.identityCheckedAt=Date(); update(p) } catch { report(error) } } }
    func report(_ error: Error) { errorMessage = error.localizedDescription; record("Error", "An operation failed. Review the current error message.") }
    func exportConfiguration(to url:URL) async throws { beginUpdateWork(); defer { endUpdateWork() }; let value = PortableConfiguration(state:deck); try await Task.detached { let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; try encoder.encode(value).write(to:url,options:.atomic) }.value }
    func importPreview(from url:URL) async throws -> PortableConfiguration { try await Task.detached { let values = try url.resourceValues(forKeys:[.fileSizeKey]); guard (values.fileSize ?? 0) < 5_000_000 else { throw DeckError.message("The import is too large.") }; let config = try JSONDecoder().decode(PortableConfiguration.self,from:Data(contentsOf:url)); try config.validate(); return config }.value }
    func importConfiguration(_ config:PortableConfiguration,homeRoot:String,dataRoot:String) async throws {
        beginUpdateWork(); defer { endUpdateWork() }
        try config.validate()
        guard homeRoot.hasPrefix("/"), dataRoot.hasPrefix("/") else { throw DeckError.message("Choose absolute destination folders.") }
        var proposed=deck.profiles
        for entry in config.profiles {
            let id=UUID()
            var p=Profile(id:id,name:entry.name,color:entry.color,authMode:entry.authMode,homePath:URL(fileURLWithPath:homeRoot).appendingPathComponent(id.uuidString).path,dataPath:URL(fileURLWithPath:dataRoot).appendingPathComponent(id.uuidString).path,favorite:entry.favorite)
            p.manualOrder=proposed.count; p.createdByDeck=true; try DeckLogic.validateProfile(p,against:proposed); proposed.append(p)
        }
        // Import creates registrations only. User explicitly prepares/opens each profile later.
        let imported = proposed.filter { candidate in !deck.profiles.contains(where: { $0.id == candidate.id }) }
        deck.profiles=proposed
        for entry in config.integrations where !deck.integrations.contains(where:{$0.id==entry.id && $0.profileID==nil}) { deck.integrations.append(IntegrationStatus(id:entry.id,name:entry.name,kind:entry.kind,version:entry.version,desiredEnabled:entry.enabled,detail:"Imported desired selection; setup and authorization not applied.")) }
        for p in imported { deck.transactions.append(ConfigurationTransaction(profileID:p.id,title:"Prepare imported profile",detail:"Shared sources must be prepared before first open.")) }
        persist()
    }
    func exportDiagnostics(to url:URL) async throws {
        beginUpdateWork(); defer { endUpdateWork() }
        let text = "Profile Deck 0.1.0\nProfiles: \(deck.profiles.count)\nShared sources: \(deck.world.workspacePaths.count) workspace(s)\nTask observation: unavailable unless verified per native instance\n\n" + runtime.values.map { "Client \($0.appVersion ?? "unknown"): \($0.state.rawValue)" }.sorted().joined(separator:"\n") + "\n\n" + deck.diagnostics.map { "\($0.date.ISO8601Format()) [\($0.category)] \($0.message)" }.joined(separator:"\n")
        try await Task.detached { try text.write(to:url,atomically:true,encoding:.utf8) }.value
    }
    private func acquireManagerStorage() throws {
        guard !isDemo, managerLock == nil else { return }
        do { managerLock = try ManagerInstanceLock(directory: storageDirectory) }
        catch { canSave = false; storageFailure = error.localizedDescription; throw error }
    }
    private func requireLiveOperation() throws {
        try acquireManagerStorage()
        if !canSave { throw DeckError.message("Restore the manager database before making changes. Existing native profile data is intact.") }
        if isDemo { throw DeckError.message("Demo mode cannot modify native profiles or authenticate accounts. Open the regular app to configure your profiles.") }
    }
    private func allowLiveOperation() -> Bool { do { try requireLiveOperation(); return true } catch { report(error); return false } }
    private nonisolated static func prepareOwnedDirectories(_ profile:Profile) async throws {
        try await Task.detached {
            let manager = FileManager.default
            for path in [profile.homePath, profile.dataPath] {
                let directory = URL(fileURLWithPath:path)
                let marker = directory.appendingPathComponent(".profile-deck-owner")
                if manager.fileExists(atPath:path) {
                    guard (try? String(contentsOf:marker,encoding:.utf8)) == profile.id.uuidString else { throw DeckError.message("The selected folder already contains unmanaged data. Adopt it explicitly instead of preparing it as a new profile.") }
                } else {
                    try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    try profile.id.uuidString.write(to:marker,atomically:true,encoding:.utf8)
                }
            }
        }.value
    }
    private func processNotifications() {
        guard deck.settings.notificationsEnabled else { return }
        for usage in deck.usage {
            guard let profile=deck.profiles.first(where:{$0.id==usage.profileID}), !profile.muted, (profile.snoozedUntil ?? .distantPast) < Date(), deck.settings.usageAlerts else { continue }
            let keys=DeckLogic.notificationKeys(snapshot:usage,settings:deck.settings)
            let unseen=keys.filter { !deck.notifications.contains($0.0) }
            guard let highest=unseen.max(by:{$0.1 < $1.1}) else { continue }
            deliverNotification(id:highest.0,keys:keys.map(\.0),title:"Usage alert",body:"\(profile.name) has reached \(highest.1)% in a reported usage window.",profileID:profile.id)
        }
        for task in deck.tasks {
            guard let p=deck.profiles.first(where:{$0.id==task.profileID}), !p.muted, (p.snoozedUntil ?? .distantPast)<Date() else { continue }
            let enabled = task.state == .completed ? deck.settings.completionAlerts : task.state == .input ? deck.settings.inputAlerts : task.state == .failed ? deck.settings.failureAlerts : false
            let key="task|\(p.id)|\(task.id)|\(task.turnID)|\(task.state.rawValue)"
            if enabled && !deck.notifications.contains(key) { deliverNotification(id:key,keys:[key],title:task.state.rawValue,body:p.name,profileID:p.id) }
        }
    }
    private func deliverNotification(id:String,keys:[String],title:String,body:String,profileID:UUID) {
        guard !deliveringNotifications.contains(id) else { return }
        deliveringNotifications.insert(id)
        Task {
            defer { deliveringNotifications.remove(id) }
            do {
                try await notifications.send(id:id,title:title,body:body,profileID:profileID,sound:deck.settings.sound)
                deck.notifications.formUnion(keys); persist()
            } catch { record("Notifications","A notification could not be delivered. Check notification permission in Settings.") }
        }
    }
    private func record(_ category:String,_ message:String) {
        deck.diagnostics.append(DiagnosticEvent(category:category,message:message))
        let limit=Date().addingTimeInterval(-7*86400); deck.diagnostics=Array(deck.diagnostics.filter{$0.date>limit}.suffix(2000)); persist()
    }
    private func persist(allowedRemovedProfileIDs: Set<UUID> = []) {
        guard canSave, !isDemo else { return }
        beginUpdateWork()
        // Queue every save attempt before resolving its storage dependency. This
        // keeps quit/update coordination truthful even when storage is already
        // unavailable, and preserves the in-memory change with an actionable
        // error instead of silently dropping the attempted save.
        Task {
            defer { endUpdateWork() }
            do {
                try acquireManagerStorage()
                revision += 1
                try await store.save(deck, revision: revision, allowedRemovedProfileIDs: allowedRemovedProfileIDs)
            } catch {
                errorMessage = error.localizedDescription
                canSave = false
                storageFailure = error.localizedDescription
            }
        }
    }
}

import Foundation
import Darwin

actor IntegrationService {
    typealias CLIRun = @Sendable (Profile, [String]) async throws -> Data
    private let sharing: SharingService
    private let runtime: SharingService.RuntimeCheck
    private let cli: CLIRun
    private var packageMutationInProgress = false

    init(sharing: SharingService = SharingService(),
         runtime: @escaping SharingService.RuntimeCheck = { await NativeAdapter().snapshot(profile: $0) },
         cli: @escaping CLIRun = { profile, arguments in
             guard await NativeAdapter().snapshot(profile: profile).state == .closed else { throw DeckError.message("Close the profile before running an integration command.") }
             try await NativeAdapter.validateClient(profile: profile)
             let runtime = try ProfileRuntimePaths.prepare(profile)
             let environment = ProcessRunner.profileEnvironment(home: runtime.home)
             let result = try await ProcessRunner.run(executable: profile.appPath + "/Contents/Resources/codex", arguments: arguments, environment: environment, timeout: 45)
             guard result.exitCode == 0, !result.truncated else { throw DeckError.message("The provider integration command failed. Open the native client's integration settings for details.") }
             return result.stdout
         }) {
        self.sharing = sharing; self.runtime = runtime; self.cli = cli
    }

    func inventory(profiles: [Profile], world: SharedWorld) async -> [IntegrationStatus] {
        var results: [IntegrationStatus] = []
        for profile in profiles {
            let closed = await runtime(profile).state == .closed
            var plugins: [IntegrationStatus] = []
            if closed {
                do {
                    let profileLock = try ProfileOperationLock(home: profile.canonicalHome)
                    defer { withExtendedLifetime(profileLock) {} }
                    let data = try await cli(profile, ["plugin", "list", "--json"])
                    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
                    plugins = Self.decodePlugins(decoded, profile: profile)
                    if plugins.isEmpty {
                        plugins = [IntegrationStatus(id: "plugin-empty:\(profile.id)", name: "Plugin catalogue", kind: .plugin, profileID: profile.id, installed: .unchecked, detail: "Provider returned no installed entries. Tool discovery and authenticated use have not been tested.")]
                    }
                } catch {
                    plugins = [IntegrationStatus(id: "plugin-error:\(profile.id)", name: "Plugin catalogue", kind: .plugin, profileID: profile.id, installed: .error, detail: "Could not read the provider plugin inventory. Existing files were not changed.")]
                }
            } else {
                plugins = [IntegrationStatus(id: "plugin-live:\(profile.id)", name: "Shared plugin packages", kind: .plugin, source: URL(fileURLWithPath: world.sourceHome).appendingPathComponent("plugins/cache").path, profileID: profile.id, installed: .unchecked, refresh: .pending, detail: "Close this instance for a bounded provider inventory. Package presence alone does not establish enabled, connected or loaded tools.")]
            }
            results += plugins
            var mcpNames = Set(world.managedMCPNames)
            var config: SharingService.ConfigurationSnapshot?
            if closed { config = try? await sharing.readConfiguration(profile) }
            mcpNames.formUnion(config?.values["mcp_servers"]?.object?.keys.map { $0 } ?? [])
            for name in mcpNames.sorted() {
                let definition = config?.values["mcp_servers"]?.object?[name]
                let managed = world.managedMCPNames.contains(name)
                let directHTTP = MCPBrowserService.supportsDirectLogin(definition: definition)
                results.append(IntegrationStatus(id: "mcp:\(profile.id):\(name)", name: name, kind: .mcp, source: managed ? "Shared desired definition" : "Profile-owned definition", desiredEnabled: definition?.object?["enabled"]?.bool ?? true, profileID: profile.id, installed: definition == nil ? .unchecked : .shared, discovery: .unchecked, authorization: directHTTP ? .unchecked : .unavailable, compatibility: .unchecked, functional: .unchecked, refresh: closed ? .unchecked : .pending, detail: managed ? "Managed definition. Account authorization, discovered tools and safe functional use are separate checks." : "Profile-owned MCP. Profile Deck will not overwrite or remove it."))
            }
            results.append(IntegrationStatus(id: "connectors:\(profile.id)", name: "ChatGPT account connectors", kind: .connector, source: "Native account settings", profileID: profile.id, installed: .unchecked, discovery: .unavailable, authorization: .unchecked, compatibility: .unavailable, functional: .unchecked, refresh: .unchecked, detail: profile.authMode == .apiKey ? "Equivalent hosted ChatGPT connector access has not been established for API-key profiles. Configure supported standalone integrations individually." : "Manage account-linked connectors in the native client. Profile Deck cannot verify or copy their authorization."))
        }
        return results
    }

    func perform(action: String, integration: IntegrationStatus, profiles: [Profile], world: SharedWorld) async throws -> [ConfigurationTransaction] {
        let action = action.lowercased()
        guard ["enable", "disable", "install", "remove", "uninstall", "update"].contains(action) else { throw DeckError.message("This integration action is not supported.") }
        guard integration.kind != .connector else { throw DeckError.message("Use the official client to connect or revoke this account's connector. Authorizations cannot be copied between profiles.") }
        guard !profiles.isEmpty else { throw DeckError.message("No profiles are registered.") }
        guard let canonical = profiles.first(where: { $0.canonicalHome == URL(fileURLWithPath: world.sourceHome).resolvingSymlinksInPath().path }) else { throw DeckError.message("Register the canonical source profile before changing shared integrations.") }
        let orderedProfiles = [canonical] + profiles.filter { $0.id != canonical.id }
        if action == "enable" || action == "disable" {
            guard await runtime(canonical).state == .closed else { return [ConfigurationTransaction(profileID: canonical.id, title: "\(action.capitalized) \(integration.name)", detail: "Close the canonical source profile and retry. Desired shared enablement was not changed.", state: .pending)] }
        }
        if integration.kind == .mcp {
            guard ["enable", "disable"].contains(action), world.managedMCPNames.contains(integration.name) else { throw DeckError.message("Only shared managed MCP enablement can be changed here. Review definition or account changes in the native client.") }
            try SharingService.validateComponent(integration.name)
            var transactions: [ConfigurationTransaction] = []
            for profile in orderedProfiles {
                let transaction = try await sharing.applyIntegrationEdit(profile: profile, edits: ["mcp_servers.\(integration.name).enabled": .bool(action == "enable")], title: "\(action.capitalized) \(integration.name)")
                transactions.append(transaction)
                if profile.id == canonical.id && transaction.state != .applied { return transactions }
            }
            return transactions
        }
        let selector = integration.source
        try Self.validatePluginSelector(selector)
        if action == "enable" || action == "disable" {
            var transactions: [ConfigurationTransaction] = []
            for profile in orderedProfiles {
                let transaction = try await sharing.applyIntegrationEdit(profile: profile, edits: ["plugins.\"\(selector)\".enabled": .bool(action == "enable")], title: "\(action.capitalized) \(integration.name)")
                transactions.append(transaction)
                if profile.id == canonical.id && transaction.state != .applied { return transactions }
            }
            return transactions
        }
        guard !packageMutationInProgress else { throw DeckError.message("Another shared package change is in progress.") }
        guard let owner = profiles.first(where: { $0.canonicalHome == URL(fileURLWithPath: world.sourceHome).resolvingSymlinksInPath().path }) else { throw DeckError.message("Register the canonical source profile before changing shared packages.") }
        for profile in profiles {
            guard await runtime(profile).state == .closed else {
                return [ConfigurationTransaction(profileID: owner.id, title: "\(action.capitalized) \(integration.name)", detail: "Pending. Close every registered instance before retrying because they may reference the same package cache. No package files were changed.", state: .pending)]
            }
        }
        // Removal deletes provider-owned cache bytes. Without a provider-supported recovery
        // operation it cannot satisfy the recovery contract; never pretend it is a safe disable.
        guard action != "remove" && action != "uninstall" && action != "update" else {
            throw DeckError.message("Package deletion and in-place updates are unavailable until the provider supports a verified recoverable package transaction. Disable the plugin instead; its files and active tools remain intact.")
        }
        let lockPath = URL(fileURLWithPath: world.sourceHome).appendingPathComponent(".profile-deck-packages.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw DeckError.message("Cannot acquire the shared package lock.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DeckError.message("Another manager is changing shared packages.") }
        var referenceLocks: [ProfileOperationLock] = []
        defer { withExtendedLifetime(referenceLocks) {} }
        for home in Set(profiles.map(\.canonicalHome)).sorted() { referenceLocks.append(try ProfileOperationLock(home: home)) }
        packageMutationInProgress = true
        defer { packageMutationInProgress = false }
        for profile in profiles { guard await runtime(profile).state == .closed else { throw DeckError.message("An instance opened during preparation. Package change stopped.") } }
        _ = try await cli(owner, ["plugin", "add", selector, "--json"])
        let checked = try JSONDecoder().decode(JSONValue.self, from: await cli(owner, ["plugin", "list", "--json"]))
        let entries = Self.decodePlugins(checked, profile: owner)
        guard entries.contains(where: { $0.source == selector && $0.installed == .shared }) else {
            return [ConfigurationTransaction(profileID: owner.id, title: "Install \(integration.name)", detail: "Provider command completed, but installed state was not confirmed. Inspect the native client before retrying.", state: .failed)]
        }
        return [ConfigurationTransaction(profileID: owner.id, title: "Install \(integration.name)", detail: "Provider reports the package installed in the canonical profile. Other profiles need enablement and fresh tool discovery; account sign-in and functional use remain unverified.", state: .applied)]
    }

    static func validatePluginSelector(_ selector: String) throws {
        guard selector.count <= 256, selector.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*@[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
            throw DeckError.message("Use a provider catalogue selector in the form plugin@marketplace. URLs, inline arguments and credentials are not accepted.")
        }
    }

    static func decodePlugins(_ response: JSONValue, profile: Profile) -> [IntegrationStatus] {
        var rows: [JSONValue] = []
        if case .array(let direct) = response { rows = direct }
        if case .array(let direct) = response.object?["plugins"] { rows += direct }
        if case .array(let marketplaces) = response.object?["marketplaces"] {
            for marketplace in marketplaces { if case .array(let plugins) = marketplace.object?["plugins"] { rows += plugins } }
        }
        return rows.compactMap { row in
            guard let item = row.object, let id = item["id"]?.string ?? item["name"]?.string else { return nil }
            let name = item["name"]?.string ?? id
            return IntegrationStatus(id: "plugin:\(profile.id):\(id)", name: name, kind: .plugin, source: id, version: item["localVersion"]?.string ?? item["version"]?.string, desiredEnabled: item["enabled"]?.bool ?? false, profileID: profile.id, installed: item["installed"]?.bool == true ? .shared : .pending, discovery: .unchecked, authorization: .unchecked, compatibility: item["disabledReason"]?.string == nil ? .unchecked : .unavailable, functional: .unchecked, refresh: .unchecked, detail: "Provider package inventory only. Tool discovery, account authorization and functional use have not been established.")
        }
    }
}

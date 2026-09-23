import Foundation
import CryptoKit
import Darwin

/// All providers are injected in tests; fixture operations never touch an installed profile.
actor SharingService {
    typealias RuntimeCheck = @Sendable (Profile) async -> RuntimeSnapshot
    typealias RPCCall = @Sendable (Profile, String, JSONValue) async throws -> JSONValue
    private let runtime: RuntimeCheck
    private let rpc: RPCCall
    private let recoveryRoot: URL
    private let files = FileManager.default
    // Executable plugin caches belong to each provider home. Shared symlinks
    // escape the native client's canonical trusted-code roots.
    private static let names = ["skills", "AGENTS.md", "rules", "pets", "memories", "keybindings.json"]
    static let preferenceAllowlist: Set<String> = ["model", "model_reasoning_effort", "model_verbosity", "model_reasoning_summary", "personality", "service_tier", "instructions", "developer_instructions"]

    init(recoveryRoot: URL? = nil,
         runtime: @escaping RuntimeCheck = { await NativeAdapter().snapshot(profile: $0) },
         rpc: @escaping RPCCall = { profile, method, params in
             let client = ProviderRPC(profile: profile)
             do { let result = try await client.call(method: method, params: params); await client.close(); return result }
             catch { await client.close(); throw error }
         }) {
        self.recoveryRoot = recoveryRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Profile Deck/Recovery", isDirectory: true)
        self.runtime = runtime
        self.rpc = rpc
    }

    /// Bootstrap shared paths before any provider helper can create default skills.
    /// Only manager-owned, closed profiles qualify; independent content is preserved.
    func prepareNewProfileSources(profile: Profile, world: SharedWorld) async throws -> ConfigurationTransaction? {
        guard profile.createdByDeck else { return nil }
        let marker = URL(fileURLWithPath: profile.homePath).appendingPathComponent(".profile-deck-owner")
        guard (try? String(contentsOf: marker, encoding: .utf8)) == profile.id.uuidString else {
            throw DeckError.message("The profile folder is not owned by Profile Deck. Adopt it explicitly.")
        }
        let worldLock = try acquireWorldLock(world)
        defer { flock(worldLock, LOCK_UN); Darwin.close(worldLock) }
        let profileLock = try ProfileOperationLock(home: profile.canonicalHome)
        defer { withExtendedLifetime(profileLock) {} }
        guard await runtime(profile).state == .closed else { throw ProviderRPCError.busy }
        try Self.validatePluginRuntimeLocation(profile)
        let inspection = await inspect(profile: profile, world: world)
        let conflicts = inspection.resources.filter { $0.state == .conflict }
        guard conflicts.isEmpty else {
            throw DeckError.message("Independent shared paths need review: " + conflicts.map(\.name).joined(separator: ", ") + ". Existing files were preserved.")
        }
        let pending = inspection.resources.filter { Self.names.contains($0.id) && $0.state == .pending }
        guard !pending.isEmpty else { return nil }
        for resource in pending { try Self.validateLinkTarget(profile: profile, path: resource.targetPath) }
        var record = RecoveryRecord(profile: profile, kind: "configuration", worldSourcePath: world.sourceHome)
        var transaction = try saveRecovery(record, title: "Prepare new profile shared sources")
        do {
            for resource in pending {
                guard await runtime(profile).state == .closed else { throw ProviderRPCError.busy }
                try Self.validateLinkTarget(profile: profile, path: resource.targetPath)
                guard !Self.pathExists(URL(fileURLWithPath: resource.targetPath)) else {
                    throw DeckError.message("A shared path changed during setup. Existing files were preserved.")
                }
                try files.createDirectory(at: URL(fileURLWithPath: resource.targetPath).deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.createSymbolicLink(atPath: resource.targetPath, withDestinationPath: resource.sourcePath)
                record.links.append(LinkRecovery(target: resource.targetPath, source: resource.sourcePath))
                try updateRecovery(record, transaction: transaction)
            }
            transaction.state = .applied
            transaction.detail = "Shared sources prepared before provider initialization. Configuration verification is still required before launch."
        } catch {
            transaction.state = .failed
            transaction.detail = "Shared source setup stopped: \(error.localizedDescription) Recovery is available."
        }
        transaction.safeToLaunch = false
        return transaction
    }

    func inspect(profile: Profile, world: SharedWorld) async -> SharedInspection {
        var resources = Self.names.map { name -> SharedResource in
            let source = URL(fileURLWithPath: world.sourceHome).appendingPathComponent(name)
            let target = URL(fileURLWithPath: profile.homePath).appendingPathComponent(name)
            let sourceExists = files.fileExists(atPath: source.path)
            let same = sourceExists && source.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path
            let targetExists = Self.pathExists(target)
            return SharedResource(id: name, name: name, sourcePath: source.path, targetPath: target.path,
                state: !sourceExists ? .unavailable : same ? .shared : targetExists ? .conflict : .pending,
                detail: !sourceExists ? "Canonical source is missing. No empty replacement will be created." : same ? "Same source on disk. Existing tasks may retain previously loaded content." : targetExists ? "An independent path exists. Review it before changing ownership." : "Can link when this profile is closed.")
        }
        let override = URL(fileURLWithPath: profile.homePath).appendingPathComponent("AGENTS.override.md")
        if Self.pathExists(override) {
            resources.append(SharedResource(id: "instruction-override", name: "Instruction override", sourcePath: world.sourceHome, targetPath: override.path, state: .conflict, detail: "This file can override the shared global instructions. Review it in the native client."))
        }
        for path in world.workspacePaths {
            resources.append(SharedResource(id: "workspace:" + path, name: URL(fileURLWithPath: path).lastPathComponent, sourcePath: path, targetPath: path, state: files.fileExists(atPath: path) ? .shared : .unavailable, detail: "Shared folder reference. Availability does not prove registration in the native client or conflict-free editing."))
        }
        resources.append(SharedResource(id: "effective-config", name: "Custom instructions and preferences", sourcePath: world.sourceHome, targetPath: profile.homePath, state: .unchecked, detail: "Use Apply to compare approved configuration through the provider while source and target are closed. Disk sharing does not prove a task loaded these settings."))
        return SharedInspection(profileID: profile.id, resources: resources)
    }

    struct ConfigurationPreview: Sendable {
        var resources: [SharedResource]
        var token: String?
        var detail: String
    }

    func preview(profile: Profile, world: SharedWorld, allProfiles: [Profile]) async throws -> ConfigurationPreview {
        let inspection = await inspect(profile: profile, world: world)
        var resources = inspection.resources.filter { $0.id != "effective-config" }
        guard let sourceProfile = allProfiles.first(where: { $0.canonicalHome == URL(fileURLWithPath: world.sourceHome).resolvingSymlinksInPath().path }) else { throw DeckError.message("Register the canonical source profile before reviewing configuration.") }
        guard await runtime(profile).state == .closed, await runtime(sourceProfile).state == .closed else {
            return ConfigurationPreview(resources: resources, token: nil, detail: "Exact before/after configuration review is unavailable while either instance is open. Close source and target, then refresh this preview. No configuration was changed.")
        }
        let source = try await readConfiguration(sourceProfile)
        let target = profile.canonicalHome == sourceProfile.canonicalHome ? source : try await readConfiguration(profile)
        let plan = try prepareConfiguration(profile: profile, world: world, sourceProfile: sourceProfile, source: source, target: target)
        resources += plan.resources
        let conflicts = inspection.resources.contains { $0.state == .conflict }
        return ConfigurationPreview(resources: resources,
            token: conflicts ? nil : try previewToken(profile: profile, world: world, source: source, target: target, inspection: inspection, plan: plan),
            detail: conflicts ? "Resolve conflicting shared paths before applying configuration." : "Review the exact approved values below. A change to source, target, sharing policy or managed ownership invalidates this review. Externally changed MCP definitions are preserved.")
    }

    func apply(profile: Profile, world: SharedWorld, allProfiles: [Profile], expectedPreviewToken: String? = nil) async throws -> ConfigurationTransaction {
        let snapshot = await runtime(profile)
        guard snapshot.state == .closed else { return pending(profile, "Close this profile before applying shared configuration.") }
        try Self.validatePluginRuntimeLocation(profile)
        guard let sourceProfile = allProfiles.first(where: { $0.canonicalHome == URL(fileURLWithPath: world.sourceHome).resolvingSymlinksInPath().path }) else {
            throw DeckError.message("Register the canonical source profile before applying shared preferences.")
        }
        guard world.memoryOwnerID == nil || world.memoryOwnerID == sourceProfile.id else { throw DeckError.message("The memory owner differs from the canonical source. Complete a validated ownership handover before applying changes.") }
        let worldLock = try acquireWorldLock(world)
        defer { flock(worldLock, LOCK_UN); Darwin.close(worldLock) }
        let sourceClosed = await runtime(sourceProfile).state == .closed
        let inspection = await inspect(profile: profile, world: world)
        guard !inspection.resources.contains(where: { $0.state == .conflict }) else { throw DeckError.message("Resolve independent shared paths or instruction overrides first. No files were replaced.") }
        let source = sourceClosed ? try await readConfiguration(sourceProfile) : nil
        let target = try await readConfiguration(profile)
        var plan = try prepareConfiguration(profile: profile, world: world, sourceProfile: sourceProfile, source: source, target: target)
        if let expectedPreviewToken {
            guard let source else { throw DeckError.message("The source is now running. Refresh the configuration preview before applying changes.") }
            let currentToken = try previewToken(profile: profile, world: world, source: source, target: target, inspection: inspection, plan: plan)
            guard expectedPreviewToken == currentToken else { throw DeckError.message("Configuration changed after review. Refresh the before/after preview; no changes were applied.") }
        }
        let deferredKeys = expectedPreviewToken == nil ? plan.requiresReview : []
        for key in deferredKeys {
            plan.desired.removeValue(forKey: key)
            if key.hasPrefix("mcp_servers.") {
                let name = String(key.dropFirst("mcp_servers.".count))
                plan.nextLedger?.entries[name] = plan.previousLedger?.entries[name]
            }
        }
        let desired = plan.desired
        var links: [LinkRecovery] = []
        for resource in inspection.resources where Self.names.contains(resource.id) && resource.state == .pending {
            try Self.validateLinkTarget(profile: profile, path: resource.targetPath)
            links.append(LinkRecovery(target: resource.targetPath, source: resource.sourcePath))
        }
        let previous = Dictionary(uniqueKeysWithValues: desired.keys.map { ($0, Self.value(in: target.values, key: $0)) })
        let changes = desired.filter { !Self.equal($0.value, previous[$0.key] ?? .null) }
        var record = RecoveryRecord(profile: profile, kind: "configuration", worldSourcePath: world.sourceHome, previousValues: previous, appliedValues: desired, previousLedger: plan.previousLedger, appliedLedger: plan.nextLedger)
        var transaction = try saveRecovery(record, title: "Apply shared configuration")
        do {
            guard await runtime(profile).state == .closed else { throw DeckError.message("Profile opened during preparation. Nothing was applied.") }
            if !changes.isEmpty { try await writeConfiguration(profile, expected: target.version, edits: changes) }
            do {
                let profileLock = try ProfileOperationLock(home: profile.canonicalHome)
                defer { withExtendedLifetime(profileLock) {} }
                for link in links {
                try Self.validateLinkTarget(profile: profile, path: link.target)
                guard await runtime(profile).state == .closed else { throw DeckError.message("Profile opened while applying shared paths. Remaining changes were stopped.") }
                guard !Self.pathExists(URL(fileURLWithPath: link.target)) else { throw DeckError.message("A shared path changed during preparation. Configuration recovery is available.") }
                try files.createDirectory(at: URL(fileURLWithPath: link.target).deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.createSymbolicLink(atPath: link.target, withDestinationPath: link.source)
                record.links.append(link)
                try updateRecovery(record, transaction: transaction)
                }
            }
            let checked = try await readConfiguration(profile)
            guard desired.allSatisfy({ Self.equal(Self.value(in: checked.values, key: $0.key), $0.value) }) else { throw DeckError.message("Provider configuration did not match the requested values. Use recovery before retrying.") }
            try writeLedger(plan.nextLedger, profile: profile)
            transaction.state = plan.resources.contains(where: { $0.state == .conflict }) ? .conflict : (!sourceClosed || !deferredKeys.isEmpty || plan.resources.contains(where: { $0.state == .unavailable })) ? .pending : .applied
            let finalInspection = await inspect(profile: profile, world: world)
            let required = Set(["skills", "AGENTS.md", "memories"])
            transaction.safeToLaunch = finalInspection.resources.filter { required.contains($0.id) }.allSatisfy { $0.state == .shared }
            transaction.detail = "Shared file sources and applied configuration were verified. Memory documents and account data were not written."
            if !sourceClosed { transaction.detail += " Custom instructions, plugin enablement, other preferences and MCP changes remain pending until the canonical profile closes." }
            if !deferredKeys.isEmpty { transaction.detail += " Existing values were preserved for \(deferredKeys.sorted().joined(separator: ", ")). Review their before/after preview to apply them." }
            if plan.resources.contains(where: { $0.state == .conflict }) { transaction.detail += " Externally changed MCP definitions were preserved and require review." }
            if plan.resources.contains(where: { $0.state == .unavailable }) { transaction.detail += " Some selected MCP definitions are absent from the source." }
            return transaction
        } catch {
            transaction.state = .failed
            transaction.safeToLaunch = false
            transaction.detail = "Application stopped: \(error.localizedDescription) Recovery is available for any applied changes."
            return transaction
        }
    }

    func readInstructions(world: SharedWorld) async throws -> (String, String) {
        let path = URL(fileURLWithPath: world.sourceHome).appendingPathComponent("AGENTS.md").resolvingSymlinksInPath()
        let data = try Data(contentsOf: path)
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else { throw DeckError.message("Instructions must be UTF-8 text smaller than 2 MB.") }
        return (text, Self.hash(data))
    }

    func saveInstructions(world: SharedWorld, text: String, expectedHash: String) async throws -> ConfigurationTransaction {
        guard let data = text.data(using: .utf8), data.count <= 2_000_000 else { throw DeckError.message("Instructions exceed the 2 MB editing limit.") }
        let path = URL(fileURLWithPath: world.sourceHome).appendingPathComponent("AGENTS.md").resolvingSymlinksInPath()
        return try withFileLock(path) {
            let old = try Data(contentsOf: path)
            let permissions = try files.attributesOfItem(atPath: path.path)[.posixPermissions]
            guard Self.hash(old) == expectedHash else { throw DeckError.message("Instructions changed since you opened the editor. Reload and compare before saving.") }
            let record = RecoveryRecord(profile: nil, kind: "instructions", instructionPath: path.path, previousText: String(data: old, encoding: .utf8), appliedHash: Self.hash(data))
            var transaction = try saveRecovery(record, title: "Edit shared instructions")
            try data.write(to: path, options: .atomic)
            if let permissions { try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: path.path) }
            transaction.state = .applied
            transaction.detail = "Canonical instructions saved. Existing tasks may require a new conversation to load changes."
            return transaction
        }
    }

    func restore(transaction: ConfigurationTransaction) async throws {
        guard let path = transaction.recoveryPath else { throw DeckError.message("This action has no recovery record.") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == recoveryRoot.resolvingSymlinksInPath().path else { throw DeckError.message("Recovery record is outside the private recovery folder.") }
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: url))
        let worldLock = try record.worldSourcePath.map { try acquireWorldLock(SharedWorld(sourceHome: $0)) }
        defer { if let worldLock { flock(worldLock, LOCK_UN); Darwin.close(worldLock) } }
        if record.kind == "instructions", let path = record.instructionPath, let text = record.previousText {
            let destination = URL(fileURLWithPath: path)
            try withFileLock(destination) {
                guard Self.hash(try Data(contentsOf: destination)) == record.appliedHash else { throw DeckError.message("Instructions changed after this edit. Automatic recovery would overwrite newer work.") }
                let permissions = try files.attributesOfItem(atPath: destination.path)[.posixPermissions]
                try Data(text.utf8).write(to: destination, options: .atomic)
                if let permissions { try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path) }
            }
        } else if let profile = record.profile {
            guard await runtime(profile).state == .closed else { throw DeckError.message("Close the affected profile before restoring configuration.") }
            try validateRecoveryLinks(record.links, profile: profile)
            if record.previousLedger != nil || record.appliedLedger != nil {
                let ledger = try readLedger(profile: profile)
                guard try ledgerHash(ledger) == ledgerHash(record.appliedLedger) || ledgerHash(ledger) == ledgerHash(record.previousLedger) else { throw DeckError.message("Managed MCP ownership changed after this transaction. Review before restoring.") }
            }
            let current = try await readConfiguration(profile)
            guard record.appliedValues.allSatisfy({ Self.equal(Self.value(in: current.values, key: $0.key), $0.value) || Self.equal(Self.value(in: current.values, key: $0.key), record.previousValues[$0.key] ?? .null) }) else { throw DeckError.message("Managed configuration changed after this transaction. Review the difference before restoring.") }
            if !record.previousValues.isEmpty { try await writeConfiguration(profile, expected: current.version, edits: record.previousValues) }
            let profileLock = try ProfileOperationLock(home: profile.canonicalHome)
            defer { withExtendedLifetime(profileLock) {} }
            guard await runtime(profile).state == .closed else { throw DeckError.message("The profile opened before link recovery. Close it and retry.") }
            try validateRecoveryLinks(record.links, profile: profile)
            for link in record.links {
                let destination = URL(fileURLWithPath: link.target)
                if (try? files.destinationOfSymbolicLink(atPath: destination.path)) == link.source { try files.removeItem(at: destination) }
            }
            if record.previousLedger != nil || record.appliedLedger != nil { try writeLedger(record.previousLedger, profile: profile) }
        } else { throw DeckError.message("Recovery record is incomplete.") }
    }

    func discoverSkills(world: SharedWorld) async -> [SharedResource] {
        let root = URL(fileURLWithPath: world.sourceHome).appendingPathComponent("skills")
        var remainingEntries = 512
        var result: [SharedResource] = []
        func issue(_ path: URL, _ detail: String) -> SharedResource {
            SharedResource(id: path.path, name: path.deletingLastPathComponent().lastPathComponent, sourcePath: path.path, targetPath: path.path, state: .error, detail: detail)
        }
        func children(_ directory: URL) -> [URL]? {
            guard files.isReadableFile(atPath: directory.path) else { return nil }
            var enumerationFailed = false
            guard let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else { return nil }
            var values: [URL] = []
            while remainingEntries > 0, let item = enumerator.nextObject() as? URL {
                remainingEntries -= 1
                if item.lastPathComponent.hasPrefix(".") && item.lastPathComponent != ".system" { continue }
                var isDirectory: ObjCBool = false
                if files.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue { values.append(item) }
            }
            guard !enumerationFailed else { return nil }
            return values.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        func readEntry(_ entry: URL) -> SharedResource {
            do {
                let resolved = entry.resolvingSymlinksInPath()
                let metadata = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard metadata.isRegularFile == true else { return issue(entry, "SKILL.md is not a regular file.") }
                guard let size = metadata.fileSize, size <= 1_048_576 else { return issue(entry, "SKILL.md exceeds the 1 MiB inspection limit.") }
                let handle = try FileHandle(forReadingFrom: resolved)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { return issue(entry, "SKILL.md must be UTF-8 text no larger than 1 MiB.") }
                let lines = text.components(separatedBy: .newlines)
                guard lines.first?.trimmingCharacters(in: .whitespaces) == "---", let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return issue(entry, "Skill frontmatter is missing or unterminated.") }
                let header = lines[1..<closing]
                guard let nameLine = header.first(where: { $0.hasPrefix("name:") }) else { return issue(entry, "Skill frontmatter has no name.") }
                var name = String(nameLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if name.count >= 2, (name.first == "\"" && name.last == "\"") || (name.first == "'" && name.last == "'") { name.removeFirst(); name.removeLast() }
                guard !name.isEmpty, name.count <= 256, name != "|", name != ">" else { return issue(entry, "Skill name is missing or uses unsupported multiline metadata.") }
                return SharedResource(id: entry.path, name: name, sourcePath: entry.path, targetPath: entry.path, state: .unchecked, detail: "Source name and frontmatter inspected. Provider parsing, compatibility and task discovery remain unverified.", revision: Self.hash(data))
            } catch { return issue(entry, "Could not read SKILL.md. Check the file, its link and read permissions.") }
        }
        guard files.fileExists(atPath: root.path), let direct = children(root) else { return [issue(root.appendingPathComponent("SKILL.md"), "The canonical skills folder is unavailable.")] }
        for folder in direct {
            let entry = folder.appendingPathComponent("SKILL.md")
            if Self.pathExists(entry) { result.append(readEntry(entry)); continue }
            guard remainingEntries > 0 else { break }
            guard let nested = children(folder), !nested.isEmpty else { result.append(issue(entry, "This skill folder has no SKILL.md and no child skill folders.")); continue }
            for child in nested {
                let nestedEntry = child.appendingPathComponent("SKILL.md")
                result.append(Self.pathExists(nestedEntry) ? readEntry(nestedEntry) : issue(nestedEntry, "No SKILL.md found within the supported two-level layout."))
            }
        }
        if remainingEntries == 0 { result.append(issue(root.appendingPathComponent("inspection-limit"), "Inspection stopped at 512 directory entries. Additional skills were not inspected.")) }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct ConfigurationSnapshot: Sendable { var values: [String: JSONValue]; var version: String }
    func readConfiguration(_ profile: Profile) async throws -> ConfigurationSnapshot {
        let response = try await rpc(profile, "config/read", .object(["includeLayers": .bool(true)]))
        guard response.object?["config"]?.object != nil else { throw DeckError.message("Provider returned no configuration.") }
        let path = URL(fileURLWithPath: profile.canonicalHome).appendingPathComponent("config.toml").standardizedFileURL.path
        guard case .array(let layers) = response.object?["layers"],
              let layer = layers.first(where: { $0.object?["name"]?.object?["type"]?.string == "user" && $0.object?["name"]?.object?["file"]?.string == path }),
              let version = layer.object?["version"]?.string else { throw DeckError.message("Provider did not expose a matching versioned user configuration. Safe writes are unavailable.") }
        // Preserve user-layer absence on recovery rather than materializing managed defaults.
        guard let userValues = layer.object?["config"]?.object else { throw DeckError.message("The provider user configuration layer has an unsupported shape. No merged defaults will be written.") }
        return ConfigurationSnapshot(values: userValues, version: version)
    }

    func applyIntegrationEdit(profile: Profile, edits: [String: JSONValue], title: String) async throws -> ConfigurationTransaction {
        guard await runtime(profile).state == .closed else { return pending(profile, "Close this profile to apply the integration change.") }
        let current = try await readConfiguration(profile)
        let previous = Dictionary(uniqueKeysWithValues: edits.keys.map { ($0, Self.value(in: current.values, key: $0)) })
        var transaction = try saveRecovery(RecoveryRecord(profile: profile, kind: "configuration", previousValues: previous, appliedValues: edits), title: title)
        do {
            try await writeConfiguration(profile, expected: current.version, edits: edits)
            let checked = try await readConfiguration(profile)
            guard edits.allSatisfy({ Self.equal(Self.value(in: checked.values, key: $0.key), $0.value) }) else { throw DeckError.message("The provider did not confirm the requested integration setting.") }
            transaction.state = .applied; transaction.detail = "Configuration saved and verified. Existing loaded tools are not terminated."
        } catch { transaction.state = .failed; transaction.detail = "\(error.localizedDescription) Recovery record retained." }
        return transaction
    }

    private func writeConfiguration(_ profile: Profile, expected: String, edits: [String: JSONValue]) async throws {
        guard await runtime(profile).state == .closed else { throw DeckError.message("Profile is no longer closed. Apply was stopped.") }
        _ = try await rpc(profile, "config/batchWrite", .object(["expectedVersion": .string(expected), "filePath": .string(URL(fileURLWithPath: profile.canonicalHome).appendingPathComponent("config.toml").path), "reloadUserConfig": .bool(false), "edits": .array(edits.sorted { $0.key < $1.key }.map { .object(["keyPath": .string($0.key), "value": $0.value, "mergeStrategy": .string("replace")]) })]))
    }
    private func pending(_ profile: Profile, _ detail: String) -> ConfigurationTransaction { ConfigurationTransaction(profileID: profile.id, title: "Shared configuration pending", detail: detail, state: .pending) }
    private struct ManagedMCPEntry: Codable, Sendable {
        var originalValue: JSONValue
        var lastAppliedHash: String
    }
    private struct ManagedMCPLedger: Codable, Sendable {
        var version = 1
        var canonicalHome: String
        var sourceHome: String
        var entries: [String: ManagedMCPEntry] = [:]
    }
    private struct PreparedConfiguration {
        var desired: [String: JSONValue] = [:]
        var requiresReview: Set<String> = []
        var resources: [SharedResource] = []
        var previousLedger: ManagedMCPLedger?
        var nextLedger: ManagedMCPLedger?
    }

    private func prepareConfiguration(profile: Profile, world: SharedWorld, sourceProfile: Profile, source: ConfigurationSnapshot?, target: ConfigurationSnapshot) throws -> PreparedConfiguration {
        var plan = PreparedConfiguration()
        plan.previousLedger = try readLedger(profile: profile)
        if let ledger = plan.previousLedger, ledger.sourceHome != sourceProfile.canonicalHome { throw DeckError.message("Managed MCP ownership belongs to a different canonical source. Resolve ownership before applying changes.") }
        let canonicalTarget = profile.canonicalHome == sourceProfile.canonicalHome
        plan.nextLedger = canonicalTarget ? nil : plan.previousLedger ?? ManagedMCPLedger(canonicalHome: profile.canonicalHome, sourceHome: sourceProfile.canonicalHome)
        if let source {
            for key in world.managedPreferenceKeys {
                guard Self.preferenceAllowlist.contains(key) else { throw DeckError.message("The requested preference is outside the approved sharing allowlist: \(key)") }
                plan.desired[key] = source.values[key] ?? .null
            }
            for (identifier, entry) in source.values["plugins"]?.object ?? [:] {
                guard let enabled = entry.object?["enabled"]?.bool else { continue }
                try Self.validatePluginIdentifier(identifier)
                plan.desired["plugins.\"\(identifier)\".enabled"] = .bool(enabled)
            }
        }
        for key in plan.desired.keys {
            let existing = Self.value(in: target.values, key: key)
            if existing != .null && !Self.equal(existing, plan.desired[key] ?? .null) { plan.requiresReview.insert(key) }
        }
        if !canonicalTarget {
            let desiredNames = Set(world.managedMCPNames)
            for name in desiredNames { try Self.validateComponent(name) }
            let allNames = desiredNames.union(plan.previousLedger?.entries.keys.map { $0 } ?? [])
            for name in allNames.sorted() {
                let key = "mcp_servers.\(name)"
                let current = Self.value(in: target.values, key: key)
                let owned = plan.previousLedger?.entries[name]
                let sourceValue = source?.values["mcp_servers"]?.object?[name] ?? .null
                let unsharing = !desiredNames.contains(name) || (source != nil && sourceValue == .null)
                if unsharing {
                    if let owned {
                        if try valueHash(current) == owned.lastAppliedHash {
                            plan.desired[key] = owned.originalValue
                        } else {
                            plan.resources.append(SharedResource(id: "config:" + key, name: "Preserve changed MCP: " + name, sourcePath: sourceProfile.canonicalHome, targetPath: profile.canonicalHome, state: .conflict, detail: "This definition changed outside Profile Deck. Its current value is withheld and preserved; manager ownership will be released."))
                        }
                        plan.nextLedger?.entries.removeValue(forKey: name)
                    }
                    if desiredNames.contains(name), source != nil, sourceValue == .null {
                        plan.resources.append(SharedResource(id: "missing-source:" + name, name: "Missing source MCP: " + name, sourcePath: sourceProfile.canonicalHome, targetPath: profile.canonicalHome, state: .unavailable, detail: owned == nil ? "The source has no definition. Any profile-owned definition will be retained." : "The source has no definition. Only unchanged manager-applied content will be removed or restored to its original baseline."))
                    }
                    continue
                }
                guard source != nil else { continue }
                try Self.validateMCP(sourceValue)
                if let owned, try valueHash(current) != owned.lastAppliedHash {
                    plan.resources.append(SharedResource(id: "config:" + key, name: "Preserve changed MCP: " + name, sourcePath: sourceProfile.canonicalHome, targetPath: profile.canonicalHome, state: .conflict, detail: "This managed definition changed outside Profile Deck. It will not be overwritten; inspect its native configuration before resuming management."))
                    continue
                }
                try Self.validateMCP(current)
                plan.desired[key] = sourceValue
                plan.nextLedger?.entries[name] = ManagedMCPEntry(originalValue: owned?.originalValue ?? current, lastAppliedHash: try valueHash(sourceValue))
                if owned == nil, current != .null, !Self.equal(current, sourceValue) { plan.requiresReview.insert(key) }
            }
        }
        if profile.id != world.memoryOwnerID && !canonicalTarget {
            plan.desired["memories.generate_memories"] = .bool(false)
            plan.desired["memories.use_memories"] = .bool(true)
        }
        for (key, value) in plan.desired.sorted(by: { $0.key < $1.key }) {
            let previous = Self.value(in: target.values, key: key)
            plan.resources.append(SharedResource(id: "config:" + key, name: key, sourcePath: sourceProfile.canonicalHome + "/config.toml", targetPath: profile.canonicalHome + "/config.toml", state: Self.equal(previous, value) ? .shared : .pending, detail: "Before:\n\(try displayValue(previous))\n\nAfter:\n\(try displayValue(value))"))
        }
        return plan
    }

    private func previewToken(profile: Profile, world: SharedWorld, source: ConfigurationSnapshot, target: ConfigurationSnapshot, inspection: SharedInspection, plan: PreparedConfiguration) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let parts = JSONValue.object([
            "profile": .string(profile.id.uuidString), "home": .string(profile.canonicalHome),
            "world": .string(Self.hash(try encoder.encode(world))),
            "sourceVersion": .string(source.version), "targetVersion": .string(target.version),
            "ledger": .string(try ledgerHash(plan.previousLedger)),
            "changes": .object(plan.desired),
            "paths": .array(inspection.resources.filter { $0.id != "effective-config" }.map { .string("\($0.id)|\($0.sourcePath)|\($0.targetPath)|\($0.state.rawValue)") })
        ])
        return Self.hash(try encoder.encode(parts))
    }
    private func displayValue(_ value: JSONValue) throws -> String {
        if value == .null { return "Not configured (remove this user override)" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func valueHash(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Self.hash(try encoder.encode(value))
    }
    private func ledgerHash(_ ledger: ManagedMCPLedger?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Self.hash(try encoder.encode(ledger))
    }
    private func ledgerURL(profile: Profile) -> URL {
        recoveryRoot.deletingLastPathComponent().appendingPathComponent("Managed MCP", isDirectory: true).appendingPathComponent(Self.hash(Data(profile.canonicalHome.utf8)) + ".json")
    }
    private func readLedger(profile: Profile) throws -> ManagedMCPLedger? {
        let url = ledgerURL(profile: profile)
        guard Self.pathExists(url) else { return nil }
        guard (try? files.destinationOfSymbolicLink(atPath: url.path)) == nil,
              (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 1_048_577 <= 1_048_576 else { throw DeckError.message("Managed MCP ownership record is invalid or too large.") }
        let ledger = try JSONDecoder().decode(ManagedMCPLedger.self, from: Data(contentsOf: url))
        guard ledger.version == 1, ledger.canonicalHome == profile.canonicalHome, ledger.entries.count <= 512 else { throw DeckError.message("Managed MCP ownership record does not match this profile.") }
        for (name, entry) in ledger.entries {
            try Self.validateComponent(name); try Self.validateMCP(entry.originalValue)
            guard entry.lastAppliedHash.count == 64, entry.lastAppliedHash.allSatisfy({ $0.isHexDigit }) else { throw DeckError.message("Managed MCP ownership hash is invalid.") }
        }
        return ledger
    }
    private func writeLedger(_ ledger: ManagedMCPLedger?, profile: Profile) throws {
        let url = ledgerURL(profile: profile)
        guard (try? files.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw DeckError.message("Refusing to replace a linked MCP ownership record.") }
        if let ledger {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(ledger)
            guard data.count <= 1_048_576 else { throw DeckError.message("Managed MCP ownership record exceeds its bounded size.") }
            try data.write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    private struct LinkRecovery: Codable { var target: String; var source: String }
    private struct RecoveryRecord: Codable {
        var profile: Profile?; var kind: String; var worldSourcePath: String?; var instructionPath: String?; var previousText: String?; var appliedHash: String?
        var links: [LinkRecovery] = []; var previousValues: [String: JSONValue] = [:]; var appliedValues: [String: JSONValue] = [:]
        var previousLedger: ManagedMCPLedger?; var appliedLedger: ManagedMCPLedger?
    }
    private func updateRecovery(_ record: RecoveryRecord, transaction: ConfigurationTransaction) throws {
        guard let path = transaction.recoveryPath else { throw DeckError.message("Missing recovery record.") }
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: path), options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    private func saveRecovery(_ record: RecoveryRecord, title: String) throws -> ConfigurationTransaction {
        try files.createDirectory(at: recoveryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var transaction = ConfigurationTransaction(profileID: record.profile?.id ?? UUID(), title: title, detail: "Prepared; not yet applied.")
        let path = recoveryRoot.appendingPathComponent(transaction.id.uuidString + ".json")
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        transaction.recoveryPath = path.path
        return transaction
    }
    private static func validatePluginRuntimeLocation(_ profile: Profile) throws {
        let home = profile.canonicalHome
        for suffix in ["plugins", "plugins/cache"] {
            let resolved = URL(fileURLWithPath: profile.homePath).appendingPathComponent(suffix).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(home + "/") else {
                throw DeckError.message("The plugin runtime resolves outside this profile. Keep executable plugin packages local to the native profile; existing files were preserved.")
            }
        }
    }

    static func validateLinkTarget(profile: Profile, path: String) throws {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let allowed = names.map { URL(fileURLWithPath: profile.homePath).appendingPathComponent($0).standardizedFileURL.path }
        guard allowed.contains(target.path) else { throw DeckError.message("Shared path is outside the managed relative-path allowlist.") }
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        let home = profile.canonicalHome
        guard parent == home || parent.hasPrefix(home + "/") else { throw DeckError.message("The shared path's parent resolves outside this profile. Review the existing folder link before applying changes.") }
    }
    private func validateRecoveryLinks(_ links: [LinkRecovery], profile: Profile) throws {
        for link in links {
            try Self.validateLinkTarget(profile: profile, path: link.target)
            if Self.pathExists(URL(fileURLWithPath: link.target)), (try? files.destinationOfSymbolicLink(atPath: link.target)) != link.source {
                throw DeckError.message("A shared link was replaced or retargeted after this transaction. Review it before restoring; no newer link will be removed.")
            }
        }
    }
    private func acquireWorldLock(_ world: SharedWorld) throws -> Int32 {
        let path = URL(fileURLWithPath: world.sourceHome).appendingPathComponent(".profile-deck-sharing.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DeckError.message("Cannot acquire the shared-world change lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw DeckError.message("Another shared-world change is in progress.") }
        return descriptor
    }
    private func withFileLock<T>(_ path: URL, operation: () throws -> T) throws -> T {
        let descriptor = open(path.deletingLastPathComponent().appendingPathComponent(".profile-deck-instructions.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DeckError.message("Cannot acquire instruction edit lock.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DeckError.message("Another instruction edit is in progress.") }
        return try operation()
    }
    static func pathExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }
    static func value(in values: [String: JSONValue], key: String) -> JSONValue {
        var current = JSONValue.object(values)
        var components: [String] = []; var component = ""; var quoted = false
        for character in key {
            if character == "\"" { quoted.toggle() }
            else if character == "." && !quoted { components.append(component); component = "" }
            else { component.append(character) }
        }
        components.append(component)
        for component in components { current = current.object?[component] ?? .null }
        return current
    }
    static func validatePluginIdentifier(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else { throw DeckError.message("Unsupported plugin identifier.") }
    }
    static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }) else { throw DeckError.message("Integration identifiers must contain only letters, numbers, hyphens and underscores.") }
    }
    static func validateMCP(_ value: JSONValue) throws {
        if case .null = value { return }
        guard let definition = value.object else { throw DeckError.message("MCP definition must be a table.") }
        let allowed: Set<String> = ["command", "args", "cwd", "enabled", "startup_timeout_sec", "tool_timeout_sec", "enabled_tools", "disabled_tools", "env_vars", "bearer_token_env_var", "url"]
        guard Set(definition.keys).isSubset(of: allowed) else { throw DeckError.message("This MCP includes private or unsupported fields. Configure its account-specific connection in the native client.") }
        if let field = definition["url"] {
            guard let string = field.string, let url = URLComponents(string: string),
                  ["https", "http"].contains(url.scheme ?? ""), url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  !sensitiveArgument(string) else { throw DeckError.message("Credential-bearing or unsupported MCP URLs cannot be shared.") }
            let ordinaryEndpoint = url.path.isEmpty || url.path == "/" || url.path.range(of: "^/(v[0-9]+/)?(mcp|sse)/?$", options: .regularExpression) != nil
            guard ordinaryEndpoint, url.host?.split(separator: ".").allSatisfy({ $0.count < 32 }) == true else { throw DeckError.message("This MCP URL may contain an account-specific access path. Keep it in the native profile's connection settings.") }
        }
        if let field = definition["command"] {
            guard let command = field.string, !command.isEmpty, !command.contains(where: { $0.isWhitespace }),
                  !sensitiveArgument(command) else { throw DeckError.message("MCP command must be an executable name or path without inline credentials.") }
        }
        if let field = definition["cwd"] {
            guard let path = field.string, path.hasPrefix("/"), !path.contains("\0") else { throw DeckError.message("MCP working directory must be an absolute local path.") }
        }
        if let field = definition["enabled"], field.bool == nil { throw DeckError.message("MCP enabled must be true or false.") }
        for key in ["startup_timeout_sec", "tool_timeout_sec"] {
            if let field = definition[key] { guard case .number(let n) = field, n.isFinite, n >= 0 else { throw DeckError.message("MCP timeouts must be nonnegative numbers.") } }
        }
        for key in ["env_vars", "enabled_tools", "disabled_tools"] {
            if let field = definition[key] {
                guard let list = field.array, list.allSatisfy({ item in
                    guard let text = item.string, !text.isEmpty else { return false }
                    let expression = key == "env_vars" ? "^[A-Za-z_][A-Za-z0-9_]*$" : "^[A-Za-z_][A-Za-z0-9_.:-]*$"
                    return text.range(of: expression, options: .regularExpression) != nil
                }) else { throw DeckError.message("MCP reference lists must contain names, never credential values.") }
            }
        }
        if let field = definition["bearer_token_env_var"] {
            guard let name = field.string, name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw DeckError.message("MCP authentication must reference a per-profile environment variable name.") }
        }
        if let field = definition["args"] {
            guard let values = field.array else { throw DeckError.message("MCP arguments must be a list of reviewed non-secret launch arguments.") }
            let executable = definition["command"]?.string.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let switches: Set<String> = ["-y", "--yes", "--stdio", "--quiet", "--no-progress", "--offline", "--no-cache"]
            let subcommands: Set<String> = ["serve", "server", "stdio", "mcp", "run", "start"]
            var expectsTransport = false
            var consumedPackageSelector = false
            for value in values {
                guard let argument = value.string, !argument.isEmpty, !argument.contains("\0"), !argument.contains("\n"), !sensitiveArgument(argument) else {
                    throw DeckError.message("MCP arguments may contain credentials. Use per-profile credential references.")
                }
                if expectsTransport {
                    guard ["stdio", "sse", "streamable-http"].contains(argument) else { throw DeckError.message("Unsupported MCP transport argument.") }
                    expectsTransport = false; continue
                }
                if argument == "--transport" { expectsTransport = true; continue }
                if argument.hasPrefix("--transport=") {
                    guard ["stdio", "sse", "streamable-http"].contains(String(argument.dropFirst(12))) else { throw DeckError.message("Unsupported MCP transport argument.") }
                    continue
                }
                if switches.contains(argument) || subcommands.contains(argument) { continue }
                if argument.hasPrefix("-") {
                    throw DeckError.message("An unreviewed MCP option cannot be shared automatically. Configure this definition in the native client.")
                }
                // Script/resource paths identify existing local material; never copy inline shell
                // programs, arbitrary positional payloads or guessed credential arguments.
                if argument.hasPrefix("/"), FileManager.default.fileExists(atPath: argument) { continue }
                if !consumedPackageSelector, ["npx", "uvx"].contains(executable), argument.range(of: "^(@[A-Za-z0-9_.-]+/)?[A-Za-z0-9][A-Za-z0-9_.-]*(@[A-Za-z0-9_.+-]+)?$", options: .regularExpression) != nil { consumedPackageSelector = true; continue }
                throw DeckError.message("An opaque MCP argument cannot be classified as non-secret. Keep this connection profile-specific in the native client.")
            }
            guard !expectsTransport else { throw DeckError.message("MCP transport option has no value.") }
        }
    }

    private static func sensitiveArgument(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = ["credential", "token", "password", "passwd", "secret", "api_key", "api-key", "apikey", "authorization", "bearer", "cookie", "session-key", "session_key", "access-key", "access_key", "private-key", "private_key", "client-key", "client_key", "--auth", "--key", "--header", "sk-", "-----begin"]
        if markers.contains(where: lower.contains) { return true }
        // Common structured tokens and long opaque payloads are never useful launch flags.
        if value.range(of: "^[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil { return true }
        return value.range(of: "^[A-Za-z0-9_+/=-]{32,}$", options: .regularExpression) != nil
    }
}

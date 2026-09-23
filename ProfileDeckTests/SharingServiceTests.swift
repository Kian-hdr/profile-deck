import XCTest
@testable import ProfileDeck

final class SharingServiceTests: XCTestCase {
    private func fixture() throws -> (URL, Profile, Profile, SharedWorld) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeckSharingTests-" + UUID().uuidString)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["skills", "rules", "pets", "memories", "plugins/cache"] {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("# Shared instructions\nKeep account data separate.\n".utf8).write(to: source.appendingPathComponent("AGENTS.md"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("keybindings.json"))
        let first = Profile(name: "Source", homePath: source.path, dataPath: root.appendingPathComponent("source-data").path)
        let second = Profile(name: "Target", homePath: target.path, dataPath: root.appendingPathComponent("target-data").path)
        let world = SharedWorld(sourceHome: source.path, memoryOwnerID: first.id)
        return (root, first, second, world)
    }

    func testNewProfileBootstrapPrecedesProviderDefaultsAndIsIdempotent() async throws {
        let (root, source, originalTarget, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var target = originalTarget; target.createdByDeck = true
        let home = URL(fileURLWithPath: target.homePath)
        try target.id.uuidString.write(to: home.appendingPathComponent(".profile-deck-owner"), atomically: true, encoding: .utf8)
        let provider = FixtureConfiguration()
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { profile in
            RuntimeSnapshot(profileID: profile.id, state: profile.id == source.id ? .open : .closed)
        }, rpc: { profile, method, params in
            // The real provider installs system skills during its first read.
            let skills = URL(fileURLWithPath: profile.homePath).appendingPathComponent("skills")
            guard skills.resolvingSymlinksInPath().path == URL(fileURLWithPath: world.sourceHome).appendingPathComponent("skills").path else {
                throw DeckError.message("Provider initialized before shared skills were prepared")
            }
            return try await provider.call(profile, method, params)
        })
        let bootstrap = try await service.prepareNewProfileSources(profile: target, world: world)
        XCTAssertEqual(bootstrap?.state, .applied)
        XCTAssertEqual(bootstrap?.safeToLaunch, false)
        XCTAssertNotNil(bootstrap?.recoveryPath)
        let repeated = try await service.prepareNewProfileSources(profile: target, world: world)
        XCTAssertNil(repeated)
        let applied = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(applied.safeToLaunch, true)
    }

    func testPluginExecutableCacheRemainsProviderLocalThroughBootstrapAndApply() async throws {
        let (root, source, originalTarget, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var target = originalTarget; target.createdByDeck = true
        let home = URL(fileURLWithPath: target.homePath)
        try target.id.uuidString.write(to: home.appendingPathComponent(".profile-deck-owner"), atomically: true, encoding: .utf8)
        let provider = FixtureConfiguration()
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"),
            runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) },
            rpc: { profile, method, params in try await provider.call(profile, method, params) })
        _ = try await service.prepareNewProfileSources(profile: target, world: world)
        let cache = home.appendingPathComponent("plugins/cache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "Bootstrap must leave runtime installation to the provider")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let runtime = cache.appendingPathComponent("provider-runtime.mjs")
        try Data("profile-local executable fixture".utf8).write(to: runtime)
        let transaction = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(transaction.state, .applied)
        XCTAssertEqual(cache.resolvingSymlinksInPath().path, cache.path)
        XCTAssertEqual(try String(contentsOf: runtime, encoding: .utf8), "profile-local executable fixture")
        let inspection = await service.inspect(profile: target, world: world)
        XCTAssertFalse(inspection.resources.contains { $0.id == "plugins/cache" })
    }

    func testBootstrapPreservesIndependentSkillsAndRequiresOwnership() async throws {
        let (root, _, originalTarget, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var target = originalTarget; target.createdByDeck = true
        let home = URL(fileURLWithPath: target.homePath)
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) })
        do { _ = try await service.prepareNewProfileSources(profile: target, world: world); XCTFail("Owner marker required") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not owned")) }
        try target.id.uuidString.write(to: home.appendingPathComponent(".profile-deck-owner"), atomically: true, encoding: .utf8)
        let skills = home.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data("private skill".utf8).write(to: skills.appendingPathComponent("user.txt"))
        do { _ = try await service.prepareNewProfileSources(profile: target, world: world); XCTFail("Independent paths must conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("skills")) }
        XCTAssertEqual(try String(contentsOf: skills.appendingPathComponent("user.txt"), encoding: .utf8), "private skill")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery").path))
    }

    func testInstructionCompareAndSwapAndRecovery() async throws {
        let (root, _, _, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"))
        let original = try await service.readInstructions(world: world)
        let transaction = try await service.saveInstructions(world: world, text: "# Revised\n", expectedHash: original.1)
        XCTAssertEqual(transaction.state, .applied)
        do {
            _ = try await service.saveInstructions(world: world, text: "stale", expectedHash: original.1)
            XCTFail("Stale writes must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        try await service.restore(transaction: transaction)
        let restored = try await service.readInstructions(world: world)
        XCTAssertEqual(restored.0, original.0)
        XCTAssertEqual(restored.1, original.1)
    }

    func testRecoveryDoesNotOverwriteLaterInstructionEdit() async throws {
        let (root, _, _, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"))
        let original = try await service.readInstructions(world: world)
        let transaction = try await service.saveInstructions(world: world, text: "first change", expectedHash: original.1)
        try Data("external newer change".utf8).write(to: URL(fileURLWithPath: world.sourceHome).appendingPathComponent("AGENTS.md"))
        do { try await service.restore(transaction: transaction); XCTFail("Recovery must preserve intervening edits") }
        catch { XCTAssertTrue(error.localizedDescription.contains("newer work")) }
    }

    func testNewProfileGetsLinksAndMemoryGuardWhileSourceOpen() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FixtureConfiguration()
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { profile in RuntimeSnapshot(profileID: profile.id, state: profile.id == source.id ? .open : .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        let transaction = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(transaction.state, .pending)
        XCTAssertEqual(transaction.safeToLaunch, true)
        let memory = await provider.value(profile: target, key: "memories.generate_memories")
        XCTAssertEqual(memory, .bool(false))
        let inspection = await service.inspect(profile: target, world: world)
        XCTAssertTrue(inspection.resources.filter { ["skills", "AGENTS.md", "memories"].contains($0.id) }.allSatisfy { $0.state == .shared })
        let sourceWasRead = await provider.readProfiles.contains(source.id)
        XCTAssertFalse(sourceWasRead)
    }

    func testIndependentFilesAreNotOverwritten() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = URL(fileURLWithPath: target.homePath).appendingPathComponent("AGENTS.md")
        try Data("Private instructions".utf8).write(to: path)
        let provider = FixtureConfiguration()
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        do { _ = try await service.apply(profile: target, world: world, allProfiles: [source, target]); XCTFail("Independent instruction file must conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("independent")) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "Private instructions")
        let writes = await provider.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testManagedMCPRemovalPreservesUnrelatedDefinition() async throws {
        let (root, source, target, initialWorld) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var world = initialWorld; world.managedMCPNames = ["retired"]
        let provider = FixtureConfiguration()
        await provider.set(profile: source, key: "mcp_servers", value: .object(["retired": .object(["command": .string("fixture")])]))
        await provider.set(profile: target, key: "mcp_servers", value: .object(["private": .object(["command": .string("private-fixture")])]))
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        let first = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(first.state, .applied)
        world.managedMCPNames = []; world.revision = UUID().uuidString
        let removal = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(removal.state, .applied)
        let retired = await provider.value(profile: target, key: "mcp_servers.retired")
        let untouched = await provider.value(profile: target, key: "mcp_servers.private.command")
        let originalSource = await provider.value(profile: source, key: "mcp_servers.retired.command")
        XCTAssertEqual(retired, .null)
        XCTAssertEqual(untouched, .string("private-fixture"))
        XCTAssertEqual(originalSource, .string("fixture"))
        try await service.restore(transaction: removal)
        let recovered = await provider.value(profile: target, key: "mcp_servers.retired.command")
        XCTAssertEqual(recovered, .string("fixture"))
    }

    func testUnsharingRestoresReviewedOriginalProfileDefinition() async throws {
        let (root, source, target, initialWorld) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var world = initialWorld; world.managedMCPNames = ["shared"]
        let provider = FixtureConfiguration()
        await provider.set(profile: source, key: "mcp_servers", value: .object(["shared": .object(["command": .string("shared-fixture")])]))
        await provider.set(profile: target, key: "mcp_servers", value: .object(["shared": .object(["command": .string("user-fixture")])]))
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        let preview = try await service.preview(profile: target, world: world, allProfiles: [source, target])
        XCTAssertNotNil(preview.token)
        XCTAssertTrue(preview.resources.contains { $0.detail.contains("user-fixture") && $0.detail.contains("shared-fixture") })
        let applied = try await service.apply(profile: target, world: world, allProfiles: [source, target], expectedPreviewToken: preview.token)
        XCTAssertEqual(applied.state, .applied)
        world.managedMCPNames = []; world.revision = UUID().uuidString
        let removal = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(removal.state, .applied)
        let restored = await provider.value(profile: target, key: "mcp_servers.shared.command")
        XCTAssertEqual(restored, .string("user-fixture"))
    }

    func testUnsharingPreservesExternallyChangedManagedDefinition() async throws {
        let (root, source, target, initialWorld) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var world = initialWorld; world.managedMCPNames = ["shared"]
        let provider = FixtureConfiguration()
        await provider.set(profile: source, key: "mcp_servers", value: .object(["shared": .object(["command": .string("shared-fixture")])]))
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        _ = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        await provider.set(profile: target, key: "mcp_servers", value: .object(["shared": .object(["command": .string("external-fixture")])]))
        world.managedMCPNames = []; world.revision = UUID().uuidString
        let removal = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(removal.state, .conflict)
        let preserved = await provider.value(profile: target, key: "mcp_servers.shared.command")
        XCTAssertEqual(preserved, .string("external-fixture"))
    }

    func testPreviewBindsSourceTargetAndWorldBeforeWrites() async throws {
        let (root, source, target, initialWorld) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var world = initialWorld
        let provider = FixtureConfiguration()
        await provider.set(profile: source, key: "model", value: .string("source-model"))
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        for changed in ["target", "source", "world"] {
            let preview = try await service.preview(profile: target, world: world, allProfiles: [source, target])
            XCTAssertNotNil(preview.token)
            if changed == "target" { await provider.set(profile: target, key: "unrelated", value: .bool(true)) }
            if changed == "source" { await provider.set(profile: source, key: "model", value: .string("new-source-model")) }
            if changed == "world" { world.revision = UUID().uuidString }
            do { _ = try await service.apply(profile: target, world: world, allProfiles: [source, target], expectedPreviewToken: preview.token); XCTFail("Stale review must fail before writes") }
            catch { XCTAssertTrue(error.localizedDescription.contains("changed after review")) }
        }
        let writes = await provider.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testNilPreviewPreservesExistingPreferencesWhilePreparingSafeSources() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FixtureConfiguration()
        await provider.set(profile: source, key: "model", value: .string("shared-model"))
        await provider.set(profile: target, key: "model", value: .string("existing-model"))
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        let transaction = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(transaction.state, .pending)
        XCTAssertEqual(transaction.safeToLaunch, true)
        let preserved = await provider.value(profile: target, key: "model")
        XCTAssertEqual(preserved, .string("existing-model"))
    }

    func testRecoveryDirectoryURLHintDoesNotBreakConfinement() async throws {
        let (root, _, _, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SharingService(recoveryRoot: URL(fileURLWithPath: root.path + "/recovery", isDirectory: false))
        let original = try await service.readInstructions(world: world)
        let transaction = try await service.saveInstructions(world: world, text: "reviewed edit", expectedHash: original.1)
        try await service.restore(transaction: transaction)
        let restored = try await service.readInstructions(world: world)
        XCTAssertEqual(restored.0, original.0)
    }

    func testSourcePluginEnablementReachesNewProfile() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FixtureConfiguration()
        await provider.set(profile: source, key: "plugins", value: .object(["fixture@market.example": .object(["enabled": .bool(true)])]))
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        let transaction = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        XCTAssertEqual(transaction.state, .applied)
        let enabled = await provider.value(profile: target, key: "plugins.\"fixture@market.example\".enabled")
        XCTAssertEqual(enabled, .bool(true))
    }

    func testEscapedPluginParentRejectedBeforeConfigurationWrite() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: target.homePath).appendingPathComponent("plugins"), withDestinationURL: external)
        let provider = FixtureConfiguration()
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        do { _ = try await service.apply(profile: target, world: world, allProfiles: [source, target]); XCTFail("An escaped parent must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("outside")) }
        let count = await provider.writeCount
        XCTAssertEqual(count, 0)
        XCTAssertFalse(SharingService.pathExists(external.appendingPathComponent("cache")))
    }

    func testRecoveryConflictsBeforeTouchingConfigurationWhenLinkRetargeted() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FixtureConfiguration()
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"), runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        let transaction = try await service.apply(profile: target, world: world, allProfiles: [source, target])
        let link = URL(fileURLWithPath: target.homePath).appendingPathComponent("skills")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("different-skills"))
        let before = await provider.writeCount
        do { try await service.restore(transaction: transaction); XCTFail("Retargeted links must conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("retargeted")) }
        let after = await provider.writeCount
        XCTAssertEqual(before, after)
    }

    func testPackageMutationHoldsEveryReferenceLockThroughReadback() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = FixtureLockProbe()
        let service = IntegrationService(runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, cli: { _, _ in
            var blocked = 0
            for profile in [source, target] {
                do { let lock = try ProfileOperationLock(home: profile.canonicalHome); withExtendedLifetime(lock) {} }
                catch { blocked += 1 }
            }
            await probe.record(blocked)
            return Data("{\"plugins\":[{\"id\":\"fixture@market\",\"name\":\"Fixture\",\"installed\":true}]}".utf8)
        })
        let transaction = try await service.perform(action: "install", integration: IntegrationStatus(id: "fixture", name: "Fixture", kind: .plugin, source: "fixture@market"), profiles: [source, target], world: world)
        XCTAssertEqual(transaction.first?.state, .applied)
        let observed = await probe.observed
        XCTAssertEqual(observed, [2, 2])
    }

    func testMCPSecretsAndUnsafeFieldsRejected() throws {
        XCTAssertThrowsError(try SharingService.validateMCP(.object(["http_headers": .object(["Authorization": .string("fixture")])])))
        XCTAssertThrowsError(try SharingService.validateMCP(.object(["url": .string("https://example.test/mcp?token=fixture")])))
        XCTAssertThrowsError(try SharingService.validateMCP(.object(["url": .string("https://example.test/access/opaque-access-value/mcp")])))
        XCTAssertNoThrow(try SharingService.validateMCP(.object(["url": .string("https://example.test/v1/mcp")])))
        XCTAssertThrowsError(try SharingService.validateMCP(.object(["command": .string("fixture"), "args": .array([.string("--api-key=fixture")]) ])))
        XCTAssertNoThrow(try SharingService.validateMCP(.object(["command": .string("fixture"), "args": .array([.string("serve")]) ])))
    }

    func testSkillDiscoveryIncludesSystemGroupAndReportsMalformedOrLargeFiles() async throws {
        let (root, _, _, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = URL(fileURLWithPath: world.sourceHome).appendingPathComponent("skills")
        for name in ["direct", ".system/nested", "broken", "large"] {
            try FileManager.default.createDirectory(at: skills.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("---\nname: direct-name\ndescription: Fixture\n---\n# Skill".utf8).write(to: skills.appendingPathComponent("direct/SKILL.md"))
        try Data("---\nname: 'nested-name'\ndescription: Fixture\n---\n# Skill".utf8).write(to: skills.appendingPathComponent(".system/nested/SKILL.md"))
        try Data("---\nname: broken-without-end".utf8).write(to: skills.appendingPathComponent("broken/SKILL.md"))
        try Data(repeating: 65, count: 1_048_577).write(to: skills.appendingPathComponent("large/SKILL.md"))
        let service = SharingService(recoveryRoot: root.appendingPathComponent("recovery"))
        let resources = await service.discoverSkills(world: world)
        XCTAssertEqual(resources.count, 4)
        XCTAssertTrue(resources.contains { $0.name == "direct-name" && $0.state == .unchecked })
        XCTAssertTrue(resources.contains { $0.name == "nested-name" && $0.state == .unchecked })
        XCTAssertEqual(resources.filter { $0.state == .error }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("recovery").path))
    }

    func testUnknownAndCredentialArgumentsNeverReachRecoveryOrConfig() async throws {
        let (root, source, target, originalWorld) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var world = originalWorld; world.managedMCPNames = ["private-server"]
        let provider = FixtureConfiguration()
        let credential = "fixture-sensitive-value-not-for-export"
        await provider.set(profile: source, key: "mcp_servers", value: .object(["private-server": .object(["command": .string("fixture"), "args": .array([.string("--credential"), .string(credential)])])]))
        let recovery = root.appendingPathComponent("recovery")
        let service = SharingService(recoveryRoot: recovery, runtime: { RuntimeSnapshot(profileID: $0.id, state: .closed) }, rpc: { profile, method, params in try await provider.call(profile, method, params) })
        do { _ = try await service.apply(profile: target, world: world, allProfiles: [source, target]); XCTFail("Credential arguments must stop before changes") }
        catch { XCTAssertFalse(error.localizedDescription.contains(credential)) }
        let writes = await provider.writeCount
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        for argument in ["--credential=value", "--unknown-option=value", "--access-key", "--header=Authorization", "unclassified-inline-value"] {
            XCTAssertThrowsError(try SharingService.validateMCP(.object(["command": .string("fixture"), "args": .array([.string(argument)])])))
        }
        XCTAssertThrowsError(try SharingService.validateMCP(.object(["command": .string("fixture"), "args": .string("invalid inline arguments")])))
        XCTAssertThrowsError(try SharingService.validateMCP(.object(["command": .string("npx"), "args": .array([.string("@example/mcp-server"), .string("opaque-value")]) ])))
        XCTAssertNoThrow(try SharingService.validateMCP(.object(["command": .string("npx"), "args": .array([.string("-y"), .string("@example/mcp-server@1.2.3")])])))
        XCTAssertNoThrow(try SharingService.validateMCP(.object(["command": .string("fixture"), "args": .array([.string("--transport"), .string("stdio")]), "bearer_token_env_var": .string("MCP_AUTH_TOKEN") ])))
    }

    func testPluginSelectorCannotBecomeCredentialBearingCLIArgument() throws {
        for source in ["https://example.test/plugin?token=fixture", "https://user:password@example.test/plugin", "--credential=fixture", "package --secret fixture", "/private/plugin"] { XCTAssertThrowsError(try IntegrationService.validatePluginSelector(source)) }
        XCTAssertNoThrow(try IntegrationService.validatePluginSelector("example-plugin@public-marketplace"))
    }

    func testPortableExportDoesNotContainMCPRecoveryOrDefinitions() throws {
        var state = PersistedDeck()
        state.world.managedMCPNames = ["private-server"]
        state.integrations = [IntegrationStatus(id: "private-server", name: "Private server", kind: .mcp, source: "https://private.example/mcp?credential=fixture-value")]
        state.transactions = [ConfigurationTransaction(profileID: UUID(), title: "Private recovery", detail: "fixture-sensitive-content", recoveryPath: "/private/recovery/fixture-secret.json")]
        let output = String(decoding: try JSONEncoder().encode(PortableConfiguration(state: state)), as: UTF8.self)
        for forbidden in ["credential=", "fixture-value", "fixture-sensitive-content", "fixture-secret", "private.example", "managedMCPNames", "recoveryPath"] { XCTAssertFalse(output.contains(forbidden)) }
    }

    func testPluginDecodeNeverClaimsAuthOrFunctionalUse() {
        let profile = Profile(name: "Fixture", homePath: "/fixture", dataPath: "/fixture-data")
        let rows = IntegrationService.decodePlugins(.object(["marketplaces": .array([.object(["plugins": .array([.object(["id": .string("fixture@market"), "name": .string("Fixture"), "installed": .bool(true), "enabled": .bool(true)])])])])]), profile: profile)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.installed, .shared)
        XCTAssertEqual(rows.first?.authorization, .unchecked)
        XCTAssertEqual(rows.first?.functional, .unchecked)
        XCTAssertEqual(SharingService.value(in: ["plugins": .object(["fixture@market.test": .object(["enabled": .bool(true)])])], key: "plugins.\"fixture@market.test\".enabled"), .bool(true))
    }

    func testPackageMutationWaitsForEveryProfile() async throws {
        let (root, source, target, world) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let integration = IntegrationStatus(id: "fixture", name: "Fixture", kind: .plugin, source: "fixture@market")
        let service = IntegrationService(runtime: { RuntimeSnapshot(profileID: $0.id, state: $0.id == target.id ? .open : .closed) }, cli: { _, _ in throw DeckError.message("CLI must not execute with a live profile") })
        let transactions = try await service.perform(action: "install", integration: integration, profiles: [source, target], world: world)
        XCTAssertEqual(transactions.first?.state, .pending)
    }
}

private actor FixtureConfiguration {
    var configurations: [UUID: [String: JSONValue]] = [:]
    var versions: [UUID: Int] = [:]
    var readProfiles: Set<UUID> = []
    var writeCount = 0
    func value(profile: Profile, key: String) -> JSONValue { SharingService.value(in: configurations[profile.id] ?? [:], key: key) }
    func set(profile: Profile, key: String, value: JSONValue) { configurations[profile.id, default: [:]][key] = value; versions[profile.id, default: 0] += 1 }
    func call(_ profile: Profile, _ method: String, _ params: JSONValue) throws -> JSONValue {
        let version = versions[profile.id, default: 0]
        if method == "config/read" {
            readProfiles.insert(profile.id)
            let config = JSONValue.object(configurations[profile.id] ?? [:])
            return .object(["config": config, "layers": .array([.object(["name": .object(["type": .string("user"), "file": .string(profile.canonicalHome + "/config.toml")]), "version": .string(String(version)), "config": config])])])
        }
        guard method == "config/batchWrite", params["expectedVersion"].string == String(version), let edits = params["edits"].array else { throw DeckError.message("Fixture version mismatch") }
        var values = configurations[profile.id] ?? [:]
        for edit in edits {
            guard let key = edit["keyPath"].string else { continue }
            var parts: [String] = []; var token = ""; var quoted = false
            for character in key {
                if character == "\"" { quoted.toggle() }
                else if character == "." && !quoted { parts.append(token); token = "" }
                else { token.append(character) }
            }
            parts.append(token)
            Self.assign(&values, parts: parts, value: edit["value"])
        }
        configurations[profile.id] = values; versions[profile.id] = version + 1; writeCount += 1
        return .object([:])
    }
    private static func assign(_ root: inout [String: JSONValue], parts: [String], value: JSONValue) {
        guard let first = parts.first else { return }
        if parts.count == 1 { if value == .null { root.removeValue(forKey: first) } else { root[first] = value }; return }
        var nested = root[first]?.object ?? [:]
        assign(&nested, parts: Array(parts.dropFirst()), value: value)
        root[first] = .object(nested)
    }
}

private actor FixtureLockProbe {
    var observed: [Int] = []
    func record(_ count: Int) { observed.append(count) }
}

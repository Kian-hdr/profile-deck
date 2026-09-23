import Foundation
import AppKit
import CoreGraphics
import Darwin

struct NativeProcessIdentity: Sendable, Equatable {
    let pid: Int32
    let start: String
    let executable: String
    let home: String
    let data: String
}

actor NativeAdapter {
    private var opening: Set<UUID> = []
    private let billing: PromptBalanceUsage
    init(billingDatabaseURL: URL? = nil) { billing = PromptBalanceUsage(databaseURL: billingDatabaseURL) }

    func snapshot(profile: Profile) async -> RuntimeSnapshot { await inspect(profile: profile) }

    func inspect(profile: Profile) async -> RuntimeSnapshot {
        var result = RuntimeSnapshot(profileID: profile.id)
        let infoURL = URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: infoURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        result.appVersion = info?["CFBundleShortVersionString"] as? String
        result.capabilities = [
            Capability(id: "taskStatus", available: false, detail: "No verified per-instance task transport. App presence does not establish task status."),
            Capability(id: "taskFocus", available: false, detail: "Exact task navigation is not verified for this client."),
            Capability(id: "usage", available: false, detail: "Provider usage transport has not been verified.")
        ]
        guard let executableName = info?["CFBundleExecutable"] as? String, !executableName.contains("/"),
              info?["CFBundleIdentifier"] as? String == "com.openai.codex" else {
            result.detail = "Select the installed official ChatGPT/Codex client."
            return result
        }
        let expectedExecutable = Self.canonical(URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/MacOS/\(executableName)").path)
        let candidatePIDs = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier)
        }
        let lockURL = URL(fileURLWithPath: profile.canonicalData).appendingPathComponent("SingletonLock")
        let lockTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: lockURL.path)
        let lockPID = lockTarget.flatMap(Self.pidFromLock)
        var candidates = candidatePIDs
        if let lockPID, !candidates.contains(lockPID), Darwin.kill(lockPID, 0) == 0 { candidates.append(lockPID) }
        var matches: [NativeProcessIdentity] = []
        var ambiguous = false
        for pid in candidates {
            guard let identity = Self.readIdentity(pid: pid) else { ambiguous = true; continue }
            if identity.executable == expectedExecutable && identity.home == profile.canonicalHome && identity.data == profile.canonicalData {
                matches.append(identity)
            } else if lockPID == pid { ambiguous = true }
        }
        if matches.count == 1, let identity = matches.first {
            result.pid = identity.pid; result.processStart = identity.start
            result.state = .open
            result.detail = "Process identity and isolated profile paths match. Task status is unavailable."
            result.windows = Self.windows(pid: identity.pid)
            result.capabilities.append(Capability(id: "focus", available: true, detail: "Activate this verified process. Exact window selection is unavailable."))
        } else if matches.count > 1 || ambiguous {
            result.state = .unknown
            result.detail = "Process identity could not be established safely. No launch or quit action was taken."
        } else {
            result.state = opening.contains(profile.id) ? .launching : .closed
            result.detail = opening.contains(profile.id) ? "Waiting for the isolated client process." : "No matching native instance is running."
        }
        return result
    }

    func open(profile: Profile, userInitiated: Bool = false) async throws -> RuntimeSnapshot {
        guard !opening.contains(profile.id) else { throw DeckError.message("This profile is already opening.") }
        let existing = await inspect(profile: profile)
        if existing.state == .open { try await focus(profile: profile, userInitiated: userInitiated); return await inspect(profile: profile) }
        guard existing.state == .closed else { throw DeckError.message(existing.detail) }
        try Self.validatePaths(profile)
        try await Self.validateClient(profile: profile)
        if profile.createdByDeck {
            for path in [profile.canonicalHome, profile.canonicalData] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        guard FileManager.default.fileExists(atPath: profile.canonicalHome), FileManager.default.fileExists(atPath: profile.canonicalData) else {
            throw DeckError.message("This profile's folders are missing. Adopt an existing profile or create a new one.")
        }
        let checked = await inspect(profile: profile)
        if checked.state == .open { try await focus(profile: profile, userInitiated: userInitiated); return checked }
        guard checked.state == .closed else { throw DeckError.message(checked.detail) }
        let runtimePaths = try ProfileRuntimePaths.prepare(profile)
        let lock = try ProfileOperationLock(home: profile.canonicalHome)
        defer { withExtendedLifetime(lock) {} }
        opening.insert(profile.id)
        defer { opening.remove(profile.id) }
        var environment = ProcessRunner.profileEnvironment(home: runtimePaths.home)
        environment.removeValue(forKey: "CODEX_HOME")
        let launched = try await ProcessRunner.run(executable: "/usr/bin/open", arguments: [
            "-n", "--env", "CODEX_HOME=\(runtimePaths.home)", "--env", "CODEX_ELECTRON_USER_DATA_PATH=\(runtimePaths.data)",
            profile.appPath, "--args", "--user-data-dir=\(runtimePaths.data)"
        ], environment: environment, timeout: 15, maximumOutputBytes: 8192)
        guard launched.exitCode == 0 else { throw DeckError.message("macOS could not open this isolated profile.") }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            let snapshot = await inspect(profile: profile)
            if snapshot.state == .open { return snapshot }
            if snapshot.state == .unknown { throw DeckError.message(snapshot.detail) }
        }
        throw DeckError.message("Opening was requested, but the profile identity could not be verified. Check the client before trying again.")
    }

    func focus(profile: Profile, windowID: Int? = nil, userInitiated: Bool = false) async throws {
        if windowID != nil { throw DeckError.message("Exact window selection is not verified. Use Open profile instead.") }
        let snapshot = await inspect(profile: profile)
        guard snapshot.state == .open, let pid = snapshot.pid, let start = snapshot.processStart else { throw DeckError.message(snapshot.detail) }
        guard let expectedExecutable = Self.executablePath(profile) else {
            throw DeckError.message("The client executable could not be found. Check the application in this profile's settings.")
        }
        let identity = NativeProcessIdentity(pid: pid, start: start, executable: expectedExecutable,
                                             home: profile.canonicalHome, data: profile.canonicalData)
        do {
            try await ProfileActivation.focus(identity: identity, userInitiated: userInitiated)
        } catch ProfileActivation.Failure.identityChanged {
            throw DeckError.message("This profile's running instance changed. Refresh the profiles and try again.")
        } catch ProfileActivation.Failure.notActivated {
            throw DeckError.message("The profile is still running, but macOS did not bring it forward. Select the profile again or open its window from the Dock.")
        } catch ProfileActivation.Failure.accessibilityRequired {
            throw WindowAccessibilityError()
        } catch ProfileActivation.Failure.windowNotVisible {
            throw DeckError.message("The profile is active, but its selected window could not be confirmed on screen. Check Desktop & Dock → Mission Control → When switching to an application, switch to a Space with open windows for the application. Its full-screen state has been preserved.")
        } catch ProfileActivation.Failure.windowSelectionUnavailable {
            throw DeckError.message("The profile is active, but its selected window could not be identified uniquely. Use the native client's Window menu to choose it. Profile Deck has preserved its full-screen state.")
        }
    }

    /// The caller presents the explicit quit confirmation. No forced termination is used.
    func quit(profile: Profile) async throws {
        let snapshot = await inspect(profile: profile)
        if snapshot.state == .closed { return }
        guard snapshot.state == .open, let pid = snapshot.pid, let start = snapshot.processStart else { throw DeckError.message(snapshot.detail) }
        let expectedExecutable = Self.executablePath(profile)
        let accepted = await MainActor.run {
            guard let identity = Self.readIdentity(pid: pid), identity.start == start,
                  identity.executable == expectedExecutable,
                  identity.home == profile.canonicalHome, identity.data == profile.canonicalData,
                  let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return app.terminate()
        }
        guard accepted else { throw DeckError.message("The client did not accept the quit request. Close it in its own window.") }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if Self.readIdentity(pid: pid)?.start != start { return }
        }
        throw DeckError.message("The client is still open and may need your attention. Profile Deck will not force it to quit.")
    }

    func discoverKnownProfiles() async -> [Profile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appPath = ["/Applications/ChatGPT.app", "/Applications/Codex.app"].first { FileManager.default.fileExists(atPath: $0) } ?? "/Applications/ChatGPT.app"
        let entries: [(String, AuthMode, String, String)] = [
            ("Default", .subscription, ".codex", "Library/Application Support/Codex")
        ]
        return entries.compactMap { name, mode, root, data in
            let rootPath = home.appendingPathComponent(root).path, dataPath = home.appendingPathComponent(data).path
            guard FileManager.default.fileExists(atPath: rootPath), FileManager.default.fileExists(atPath: dataPath) else { return nil }
            return Profile(name: name, authMode: mode, homePath: rootPath, dataPath: dataPath, appPath: appPath)
        }
    }

    func verifyAccount(profile: Profile) async throws -> (String?, AuthMode) {
        let rpc = ProviderRPC(profile: profile, purpose: .accountUsage)
        do {
            let response = try await rpc.call(method: "account/read", params: .object(["refreshToken": .bool(false)]))
            await rpc.close()
            switch response["account"]["type"].string {
            case "chatgpt": return (response["account"]["email"].string, .subscription)
            case "apiKey": return (nil, .apiKey)
            default: throw DeckError.message("No supported saved login was reported. Sign in through this profile's native window.")
            }
        } catch { await rpc.close(); throw error }
    }

    func loginAPI(profile: Profile, key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16384, !trimmed.contains("\n"), !trimmed.contains("\0") else {
            throw DeckError.message("Enter a valid API key.")
        }
        guard await inspect(profile: profile).state == .closed else { throw ProviderRPCError.busy }
        try await Self.validateClient(profile: profile)
        let lock = try ProfileOperationLock(home: profile.canonicalHome)
        defer { withExtendedLifetime(lock) {} }
        guard await inspect(profile: profile).state == .closed else { throw ProviderRPCError.busy }
        let runtime = try ProfileRuntimePaths.prepare(profile)
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Resources/codex").path,
            arguments: ["login", "--with-api-key"], environment: ProcessRunner.profileEnvironment(home: runtime.home),
            stdin: Data((trimmed + "\n").utf8), timeout: 30, maximumOutputBytes: 4096)
        guard result.exitCode == 0 else { throw DeckError.message("The provider could not save this API login. The key was not logged by Profile Deck.") }
    }

    func usage(profile: Profile) async -> UsageSnapshot {
        // Explicit organization billing links do not require a native login or process.
        // This reading supplies no new evidence about the native account identity.
        if profile.hasLinkedAPIBilling, let sourceID = profile.billingSourceID {
            var snapshot = UsageSnapshot(profileID: profile.id, source: "Organization costs via Prompt Balance")
            do { snapshot.apiSpend = try await billing.read(sourceID: sourceID) }
            catch { snapshot.error = error.localizedDescription }
            return snapshot
        }
        let rpc = ProviderRPC(profile: profile, purpose: .accountUsage)
        var snapshot = UsageSnapshot(profileID: profile.id, source: "OpenAI account reader")
        do {
            let account = try await rpc.call(method: "account/read", params: .object(["refreshToken": .bool(false)]))
            switch account["account"]["type"].string {
            case "chatgpt":
                snapshot.observedAuthMode = .subscription
                snapshot.accountLabel = account["account"]["email"].string
                snapshot.planName = account["account"]["planType"].string
                let rates = try await rpc.call(method: "account/rateLimits/read")
                snapshot = try UsageParser.subscription(profileID: profile.id, account: account, rates: rates)
                await rpc.close()
            case "apiKey":
                snapshot.observedAuthMode = .apiKey
                await rpc.close()
                if let sourceID = profile.billingSourceID {
                    snapshot.apiSpend = try await billing.read(sourceID: sourceID)
                    snapshot.source = "Organization costs via Prompt Balance"
                } else {
                    snapshot.error = "Choose a spending source in profile details to show organization API costs."
                }
            default:
                throw DeckError.message("Sign in through this profile's native window to read account usage.")
            }
        } catch {
            await rpc.close()
            snapshot.error = error.localizedDescription
        }
        return snapshot
    }

    nonisolated static func validateClient(profile: Profile) async throws {
        let result = try await ProcessRunner.run(executable: "/usr/bin/codesign", arguments: [
            "--verify", "--deep", "--strict", "-R", "=identifier \"com.openai.codex\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"", profile.appPath
        ], timeout: 20, maximumOutputBytes: 4096)
        guard result.exitCode == 0 else { throw DeckError.message("The selected client did not pass the official OpenAI signature check. Select the original installed app.") }
    }

    nonisolated static func validatePaths(_ profile: Profile) throws {
        guard profile.homePath.hasPrefix("/"), profile.dataPath.hasPrefix("/"), profile.appPath.hasPrefix("/"),
              profile.canonicalHome != profile.canonicalData,
              !profile.canonicalHome.hasPrefix(profile.canonicalData + "/"), !profile.canonicalData.hasPrefix(profile.canonicalHome + "/") else {
            throw DeckError.message("The profile requires distinct, absolute home and application-data folders.")
        }
    }

    nonisolated static func pidFromLock(_ target: String) -> Int32? {
        guard let part = target.split(separator: "-").last, let pid = Int32(part), pid > 1 else { return nil }
        return pid
    }

    nonisolated static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private static func executablePath(_ profile: Profile) -> String? {
        guard let url = Bundle(url: URL(fileURLWithPath: profile.appPath))?.executableURL else { return nil }
        return canonical(url.path)
    }

    nonisolated static func readIdentity(pid: Int32) -> NativeProcessIdentity? {
        var before = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
              before.pbi_uid == getuid() else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), a C macro Swift cannot import.
        var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4_194_304 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        guard let paths = profilePaths(argumentBuffer: Data(bytes.prefix(size))) else { return nil }
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
              before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return NativeProcessIdentity(pid: pid, start: "\(before.pbi_start_tvsec).\(before.pbi_start_tvusec)",
            executable: canonical(String(decoding: executable.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)), home: paths.home, data: paths.data)
    }

    /// Parse only the two isolation settings; credentials and other environment values are discarded.
    nonisolated static func profilePaths(argumentBuffer: Data) -> (home: String, data: String)? {
        let bytes = [UInt8](argumentBuffer)
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = argumentBuffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65536 else { return nil }
        var cursor = 4
        while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard cursor < bytes.count else { return nil }
            let begin = cursor
            while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
            arguments.append(String(decoding: bytes[begin..<cursor], as: UTF8.self)); cursor += 1
        }
        var explicitHome: String?, explicitData: String?
        while cursor < bytes.count {
            let begin = cursor
            while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
            let value = bytes[begin..<cursor]
            if value.starts(with: Array("CODEX_HOME=".utf8)) { explicitHome = String(decoding: value.dropFirst(11), as: UTF8.self) }
            if value.starts(with: Array("CODEX_ELECTRON_USER_DATA_PATH=".utf8)) { explicitData = String(decoding: value.dropFirst(30), as: UTF8.self) }
            cursor += 1
        }
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") { explicitData = String(argument.dropFirst(16)) }
            if argument == "--user-data-dir", index + 1 < arguments.count { explicitData = arguments[index + 1] }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homePath = explicitHome ?? home.appendingPathComponent(".codex").path
        let dataPath = explicitData ?? home.appendingPathComponent("Library/Application Support/Codex").path
        guard homePath.hasPrefix("/"), dataPath.hasPrefix("/") else { return nil }
        return (canonical(homePath), canonical(dataPath))
    }

    nonisolated private static func windows(pid: Int32) -> [NativeWindow] {
        guard let entries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue else { return nil }
            return NativeWindow(id: id, title: entry[kCGWindowName as String] as? String ?? "Native window")
        }
    }
}

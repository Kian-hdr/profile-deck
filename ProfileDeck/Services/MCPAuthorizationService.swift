import Foundation

struct MCPServerAuthorization: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let authStatus: String
    let toolCount: Int
    let pluginID: String?

    var canStartOAuth: Bool { !["unsupported", "bearerToken"].contains(authStatus) }
    var summary: String {
        switch authStatus {
        case "oAuth": toolCount == 0 ? "OAuth token present · no tools reported" : "OAuth token present · \(toolCount) tools reported"
        case "notLoggedIn": "Sign-in required"
        case "bearerToken": "Uses a configured bearer token"
        case "unsupported": "OAuth unavailable for this server"
        default: "Authorization has not been verified"
        }
    }
}

enum MCPAuthorizationError: LocalizedError, Equatable {
    case unsupportedResponse
    case browserAccountMismatch
    case timedOut
    case cancelled
    case providerRejected
    case statusNotConfirmed
    case profileMustClose
    case storageNotVerified

    var errorDescription: String? {
        switch self {
        case .unsupportedResponse: "Codex did not return a valid MCP authorization link. Check this server in its native settings."
        case .browserAccountMismatch: "This authorization link belongs to a different ChatGPT account. Open the selected profile's Chrome session and sign into the account shown in Profile Deck, then start a fresh login."
        case .timedOut: "MCP sign-in timed out. Start a fresh login in the selected account's Chrome session."
        case .cancelled: "MCP sign-in was cancelled. No credential was copied between accounts."
        case .providerRejected: "Codex could not finish this MCP sign-in. Check that the selected Chrome session uses the same ChatGPT account, then retry."
        case .statusNotConfirmed: "Codex finished the browser flow, but MCP authorization was not confirmed. Start a new task in this account and check its MCP tools."
        case .profileMustClose: "Close this Codex account before preparing separate MCP credentials. Its tasks and other accounts will not be closed by Profile Deck."
        case .storageNotVerified: "Codex could not verify separate MCP credential storage for this account. Its existing credentials were preserved."
        }
    }

    static func classify(_ providerMessage: String?) -> MCPAuthorizationError {
        let message = providerMessage?.lowercased() ?? ""
        if message.contains("not owned") || message.contains("wrong account") { return .browserAccountMismatch }
        if message.contains("timed out") || message.contains("timeout") { return .timedOut }
        if message.contains("cancel") { return .cancelled }
        return .providerRejected
    }
}

/// One short-lived app-server per selected profile. It uses the same isolated
/// CODEX_HOME as that profile and never calls plugin installation or token APIs.
actor MCPAuthorizationService {
    private let rpc: ProviderRPC
    private let profile: Profile

    init(profile: Profile) {
        self.profile = profile
        rpc = ProviderRPC(profile: profile, purpose: .mcpOAuth)
    }

    func storageMode() async throws -> String {
        let response = try await rpc.call(method: "config/read", params: .object(["includeLayers": .bool(true)]))
        return Self.userLayer(response, profile: profile)?["config"]["mcp_oauth_credentials_store"].string ?? "auto"
    }

    static func prepareIsolatedStorage(profile: Profile) async throws {
        guard await NativeAdapter().inspect(profile: profile).state == .closed else {
            throw MCPAuthorizationError.profileMustClose
        }
        let rpc = ProviderRPC(profile: profile, purpose: .configuration)
        do {
            let response = try await rpc.call(method: "config/read", params: .object(["includeLayers": .bool(true)]))
            guard let layer = userLayer(response, profile: profile), let version = layer["version"].string else {
                throw MCPAuthorizationError.storageNotVerified
            }
            if layer["config"]["mcp_oauth_credentials_store"].string != "file" {
                _ = try await rpc.call(method: "config/batchWrite", params: .object([
                    "expectedVersion": .string(version),
                    "filePath": .string(URL(fileURLWithPath: profile.canonicalHome).appendingPathComponent("config.toml").path),
                    "reloadUserConfig": .bool(false),
                    "edits": .array([.object([
                        "keyPath": .string("mcp_oauth_credentials_store"),
                        "value": .string("file"),
                        "mergeStrategy": .string("replace")
                    ])])
                ]))
            }
            let checked = try await rpc.call(method: "config/read", params: .object(["includeLayers": .bool(true)]))
            guard userLayer(checked, profile: profile)?["config"]["mcp_oauth_credentials_store"].string == "file" else {
                throw MCPAuthorizationError.storageNotVerified
            }
            await rpc.close()
        } catch {
            await rpc.close()
            throw error
        }
    }

    static func userLayer(_ response: JSONValue, profile: Profile) -> JSONValue? {
        let path = URL(fileURLWithPath: profile.canonicalHome).appendingPathComponent("config.toml").standardizedFileURL.path
        return response["layers"].array?.first {
            $0["name"]["type"].string == "user" && $0["name"]["file"].string == path
        }
    }

    func listServers() async throws -> [MCPServerAuthorization] {
        var result: [MCPServerAuthorization] = []
        var cursor: String?
        for _ in 0..<5 {
            var params: [String: JSONValue] = ["detail": .string("toolsAndAuthOnly"), "limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await rpc.call(method: "mcpServerStatus/list", params: .object(params))
            guard let entries = response["data"].array else { throw MCPAuthorizationError.unsupportedResponse }
            result += entries.compactMap(Self.decodeServer)
            cursor = response["nextCursor"].string
            if cursor == nil { break }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func beginLogin(serverName: String) async throws -> URL {
        let response = try await rpc.call(method: "mcpServer/oauth/login", params: .object([
            "name": .string(serverName), "timeoutSecs": .number(180)
        ]))
        guard let link = response["authorizationUrl"].string else { throw MCPAuthorizationError.unsupportedResponse }
        return try MCPBrowserService.authorizationURL(from: link)
    }

    func finishLogin(serverName: String) async throws -> MCPServerAuthorization {
        let completion = try await rpc.waitForMCPCompletion(name: serverName, timeout: 185)
        guard completion["success"].bool == true else {
            throw MCPAuthorizationError.classify(completion["error"].string)
        }
        for attempt in 0..<6 {
            if let status = try await listServers().first(where: { $0.name == serverName }),
               status.authStatus == "oAuth" {
                guard Self.credentialFileIsPrivate(home: profile.canonicalHome) else {
                    throw MCPAuthorizationError.storageNotVerified
                }
                return status
            }
            if attempt < 5 { try await Task.sleep(for: .milliseconds(500)) }
        }
        throw MCPAuthorizationError.statusNotConfirmed
    }

    func close() async { await rpc.close() }
    func cancel() async { await rpc.abort() }

    static func decodeServer(_ item: JSONValue) -> MCPServerAuthorization? {
        guard let name = item["name"].string, !name.isEmpty,
              let authStatus = item["authStatus"].string else { return nil }
        return MCPServerAuthorization(name: name, authStatus: authStatus,
                                      toolCount: item["tools"].array?.count ?? 0,
                                      pluginID: item["pluginId"].string)
    }

    static func credentialFileIsPrivate(home: String) -> Bool {
        let path = URL(fileURLWithPath: home).appendingPathComponent(".credentials.json").path
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o077 == 0
    }
}

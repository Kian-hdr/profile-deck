import XCTest
@testable import ProfileDeck

final class MCPAuthorizationServiceTests: XCTestCase {
    func testOAuthRPCPolicyAllowsOnlyBoundedServerOperations() {
        XCTAssertTrue(ProviderRPC.permits(method: "mcpServerStatus/list",
            params: .object(["detail": .string("toolsAndAuthOnly"), "limit": .number(100)]), purpose: .mcpOAuth))
        XCTAssertTrue(ProviderRPC.permits(method: "config/read",
            params: .object(["includeLayers": .bool(true)]), purpose: .mcpOAuth))
        XCTAssertTrue(ProviderRPC.permits(method: "mcpServer/oauth/login",
            params: .object(["name": .string("example"), "timeoutSecs": .number(180)]), purpose: .mcpOAuth))
        XCTAssertFalse(ProviderRPC.permits(method: "account/read",
            params: .object(["refreshToken": .bool(false)]), purpose: .mcpOAuth))
        XCTAssertFalse(ProviderRPC.permits(method: "config/read",
            params: .object(["includeLayers": .bool(false)]), purpose: .mcpOAuth))
        XCTAssertFalse(ProviderRPC.permits(method: "mcpServer/oauth/login",
            params: .object(["name": .string("example"), "apiKey": .string("fixture")]), purpose: .mcpOAuth))
        XCTAssertFalse(ProviderRPC.permits(method: "mcpServer/oauth/login",
            params: .object(["name": .string("")]), purpose: .mcpOAuth))
    }

    func testServerStatusSeparatesOAuthFromBearerAndUnsupported() {
        let oauth = MCPAuthorizationService.decodeServer(.object([
            "name": .string("example"), "authStatus": .string("notLoggedIn"),
            "tools": .array([]), "pluginId": .string("sample@remote")
        ]))
        XCTAssertEqual(oauth?.name, "example")
        XCTAssertEqual(oauth?.pluginID, "sample@remote")
        XCTAssertTrue(oauth?.canStartOAuth == true)
        XCTAssertFalse(MCPServerAuthorization(name: "stdio", authStatus: "unsupported", toolCount: 0, pluginID: nil).canStartOAuth)
        XCTAssertFalse(MCPServerAuthorization(name: "bearer", authStatus: "bearerToken", toolCount: 1, pluginID: nil).canStartOAuth)
    }

    func testProviderErrorIsClassifiedWithoutDisplayingPrivateText() {
        XCTAssertEqual(MCPAuthorizationError.classify("OAuth link is not owned by the user"), .browserAccountMismatch)
        XCTAssertEqual(MCPAuthorizationError.classify("request timed out"), .timedOut)
        XCTAssertEqual(MCPAuthorizationError.classify("cancelled"), .cancelled)
        let secret = "token=fixture-secret"
        XCTAssertEqual(MCPAuthorizationError.classify(secret), .providerRejected)
        XCTAssertFalse(MCPAuthorizationError.classify(secret).localizedDescription.contains(secret))
    }

    func testStoreModeComesFromTheSelectedProfilesUserLayer() {
        let profile = Profile(name: "First", homePath: "/fixture/first", dataPath: "/fixture/data")
        let response: JSONValue = .object(["layers": .array([
            .object(["name": .object(["type": .string("user"), "file": .string("/fixture/other/config.toml")]),
                     "config": .object(["mcp_oauth_credentials_store": .string("file")])]),
            .object(["name": .object(["type": .string("user"), "file": .string("/fixture/first/config.toml")]),
                     "config": .object(["mcp_oauth_credentials_store": .string("auto")])])
        ])])
        XCTAssertEqual(MCPAuthorizationService.userLayer(response, profile: profile)?["config"]["mcp_oauth_credentials_store"].string, "auto")
    }

    func testOAuthCredentialEvidenceRequiresOwnerOnlyRegularFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeckMCPCredentials-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".credentials.json")
        XCTAssertFalse(MCPAuthorizationService.credentialFileIsPrivate(home: home.path))
        try Data("fixture-only".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertFalse(MCPAuthorizationService.credentialFileIsPrivate(home: home.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertTrue(MCPAuthorizationService.credentialFileIsPrivate(home: home.path))
    }
}

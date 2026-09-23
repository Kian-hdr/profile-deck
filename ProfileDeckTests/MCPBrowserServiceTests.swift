import XCTest
@testable import ProfileDeck

final class MCPBrowserServiceTests: XCTestCase {
    func testSeparateStableChromeDirectoriesAndLaunchArguments() {
        let root = URL(fileURLWithPath: "/fixture/browser-data")
        let first = Profile(name: "First", homePath: "/fixture/first/home", dataPath: "/fixture/first/data")
        let second = Profile(name: "Second", homePath: "/fixture/second/home", dataPath: "/fixture/second/data")
        let firstDirectory = MCPBrowserService.dataDirectory(for: first, root: root)
        XCTAssertEqual(firstDirectory, MCPBrowserService.dataDirectory(for: first, root: root))
        XCTAssertNotEqual(firstDirectory, MCPBrowserService.dataDirectory(for: second, root: root))
        XCTAssertEqual(MCPBrowserService.launchArguments(chrome: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            dataDirectory: firstDirectory, destination: MCPBrowserService.pluginsURL),
            ["-n", "-a", "/Applications/Google Chrome.app", "--args",
             "--user-data-dir=\(firstDirectory.path)", "https://chatgpt.com/plugins"])
    }

    func testCopiedAuthorizationLinkRequiresHTTPSWithoutEmbeddedCredentials() throws {
        XCTAssertEqual(try MCPBrowserService.authorizationURL(from: " https://example.com/authorize?state=fixture \n").absoluteString,
                       "https://example.com/authorize?state=fixture")
        XCTAssertEqual(try MCPBrowserService.authorizationURL(from: "http://127.0.0.1:43000/authorize?state=fixture").scheme, "http")
        for link in ["http://127.0.0.1:43000/callback", "http://example.com/authorize", "file:///tmp/secret", "https://user:password@example.com/authorize", "invalid"] {
            XCTAssertThrowsError(try MCPBrowserService.authorizationURL(from: link))
        }
    }

    func testLoginCommandKeepsProfileAndServerAsSeparateShellValues() {
        let profile = Profile(name: "Test", homePath: "/fixture/one's home", dataPath: "/fixture/data",
                              appPath: "/Applications/ChatGPT.app")
        let command = MCPBrowserService.loginCommand(profile: profile, serverName: "one's server")
        XCTAssertEqual(command,
            "CODEX_HOME='/fixture/one'\\''s home' '/Applications/ChatGPT.app/Contents/Resources/codex' mcp login --no-browser 'one'\\''s server'")
    }

    func testDirectLoginIsOfferedOnlyForConfiguredHTTPServers() {
        XCTAssertTrue(MCPBrowserService.supportsDirectLogin(definition: .object(["url": .string("https://mcp.example.com/mcp")])))
        XCTAssertFalse(MCPBrowserService.supportsDirectLogin(definition: .object(["command": .string("npx")])))
        XCTAssertFalse(MCPBrowserService.supportsDirectLogin(definition: nil))
    }
}

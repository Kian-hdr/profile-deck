import AppKit
import Foundation

enum MCPBrowserError: LocalizedError {
    case chromeUnavailable
    case invalidAuthorizationLink
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .chromeUnavailable:
            "Google Chrome is unavailable. Install Chrome or choose a different browser for this account."
        case .invalidAuthorizationLink:
            "Copy the HTTPS or loopback HTTP authorization link from the MCP sign-in flow, then try again. Callback and unrelated links are not opened."
        case .launchFailed:
            "Chrome could not open this account's separate browser session. Check that Chrome is installed and retry. Other account sessions were not changed."
        }
    }
}

/// Chrome's default session can belong to a different ChatGPT account than the
/// selected Codex instance. Each profile gets a separate, persistent browser
/// data directory. Profile Deck never reads or copies its cookies or credentials.
enum MCPBrowserService {
    static let pluginsURL = URL(string: "https://chatgpt.com/plugins")!

    static func dataDirectory(for profile: Profile, root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Profile Deck/MCP Browsers", isDirectory: true)) -> URL {
        root.appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
    }

    static func authorizationURL(from copiedText: String) throws -> URL {
        let text = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty,
              (components.scheme?.lowercased() == "https" ||
               (components.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()))),
              !components.path.lowercased().contains("callback"),
              components.user == nil, components.password == nil,
              let url = components.url else { throw MCPBrowserError.invalidAuthorizationLink }
        return url
    }

    static func supportsDirectLogin(definition: JSONValue?) -> Bool {
        definition?.object?["url"]?.string != nil
    }

    static func launchArguments(chrome: URL, dataDirectory: URL, destination: URL) -> [String] {
        ["-n", "-a", chrome.path, "--args", "--user-data-dir=\(dataDirectory.path)", destination.absoluteString]
    }

    static func loginCommand(profile: Profile, serverName: String) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let executable = URL(fileURLWithPath: profile.appPath).appendingPathComponent("Contents/Resources/codex").path
        return "CODEX_HOME=\(quoted(profile.canonicalHome)) \(quoted(executable)) mcp login --no-browser \(quoted(serverName))"
    }

    @MainActor static func open(profile: Profile, copiedAuthorizationLink: String? = nil) async throws {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw MCPBrowserError.chromeUnavailable
        }
        let destination = try copiedAuthorizationLink.map(authorizationURL(from:)) ?? pluginsURL
        let directory = dataDirectory(for: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let result = try await ProcessRunner.run(executable: "/usr/bin/open",
            arguments: launchArguments(chrome: chrome, dataDirectory: directory, destination: destination),
            timeout: 15, maximumOutputBytes: 2048)
        guard result.exitCode == 0 else { throw MCPBrowserError.launchFailed }
    }
}

import SwiftUI

struct MCPConnectSheet: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var service: MCPAuthorizationService?
    @State private var servers: [MCPServerAuthorization] = []
    @State private var selectedName = ""
    @State private var loading = true
    @State private var preparing = false
    @State private var connecting = false
    @State private var loginCancelled = false
    @State private var storageMode: String?
    @State private var profileClosed = false
    @State private var detail = "Reading MCP servers for this account…"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect MCP in \(profile.name)").font(.title2)
            Text("Profile Deck starts OAuth through \(profile.name)'s Codex home and opens the link in this account's separate Chrome session. Sign into the matching account in Chrome. No credential is copied from another profile.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let storageMode, storageMode != "file" {
                GroupBox("Separate MCP credentials") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Codex currently uses \(storageMode) storage for this account's MCP OAuth. The default macOS keyring can share one server's token across Profile Deck accounts. Prepare a separate file in this account's Codex home before connecting. Codex protects the file with owner-only permissions, but its tokens are unencrypted at rest. Existing keyring credentials stay available for recovery; MCPs already connected here may need their own sign-in again.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button(preparing ? "Preparing…" : "Prepare separate MCP credentials") { prepareStorage() }
                            .disabled(preparing || loading || !profileClosed)
                        if !profileClosed {
                            Text("Close \(profile.name)'s native Codex window to prepare this setting, then select Refresh. Other accounts stay open.")
                                .foregroundStyle(.secondary)
                        }
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if storageMode == "file" {
                Label("MCP OAuth tokens are scoped to this account's Codex home.", systemImage: "checkmark.shield")
                    .font(.callout)
            }
            if loading { ProgressView("Reading MCP servers…") }
            else if servers.isEmpty {
                ContentUnavailableView("No MCP servers available", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Install or configure the server in this account's native Codex settings, then reopen this panel."))
                    .frame(height: 150)
            } else {
                Picker("MCP server", selection: $selectedName) {
                    ForEach(servers) { server in Text(server.name).tag(server.name) }
                }
                if let selected = servers.first(where: { $0.name == selectedName }) {
                    LabeledContent("Authorization", value: selected.summary)
                    if let pluginID = selected.pluginID {
                        LabeledContent("Plugin", value: pluginID)
                    }
                    if !selected.canStartOAuth {
                        Text("This server does not offer OAuth in the selected profile. Use its configured authentication method.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(connecting ? "Cancel login" : "Close") {
                    if connecting {
                        loginCancelled = true
                        Task { await service?.cancel() }
                    } else { dismiss() }
                }.disabled(preparing)
                Spacer()
                Button("Refresh") { loadServers() }.disabled(loading || connecting || preparing)
                Button(connecting ? "Waiting for Chrome…" : "Connect in account browser") { connect() }
                    .disabled(loading || connecting || preparing || storageMode != "file" || servers.first(where: { $0.name == selectedName })?.canStartOAuth != true)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 590)
        .interactiveDismissDisabled(preparing || connecting)
        .task { loadServers() }
        .onDisappear {
            if let service { Task { await service.cancel() } }
        }
    }

    private func loadServers() {
        guard !connecting else { return }
        loading = true
        error = nil
        detail = "Reading MCP servers for \(profile.name)…"
        let current = service ?? MCPAuthorizationService(profile: profile)
        service = current
        Task {
            do {
                storageMode = try await current.storageMode()
                profileClosed = await NativeAdapter().inspect(profile: profile).state == .closed
                let found = try await current.listServers()
                servers = found
                if !found.contains(where: { $0.name == selectedName }) { selectedName = found.first?.name ?? "" }
                detail = found.isEmpty ? "No server was returned for this account." : "Choose the MCP server that needs sign-in."
            } catch {
                self.error = "Codex could not read this account's MCP servers. \(error.localizedDescription)"
                detail = "The other profiles and their credentials were not changed."
            }
            loading = false
        }
    }

    private func prepareStorage() {
        guard !preparing, !connecting, profileClosed else { return }
        preparing = true
        error = nil
        detail = "Preparing separate MCP credentials for \(profile.name)…"
        Task {
            do {
                if let service { await service.close() }
                service = nil
                try await MCPAuthorizationService.prepareIsolatedStorage(profile: profile)
                detail = "Separate MCP storage is ready. Reconnect each MCP for this account in its Chrome session."
                preparing = false
                loadServers()
            } catch {
                self.error = error.localizedDescription
                detail = "Existing keyring credentials were preserved."
                preparing = false
            }
        }
    }

    private func connect() {
        guard let service, servers.first(where: { $0.name == selectedName })?.canStartOAuth == true else { return }
        let serverName = selectedName
        connecting = true
        loginCancelled = false
        error = nil
        detail = "Starting \(serverName)'s login in \(profile.name)…"
        Task {
            do {
                let url = try await service.beginLogin(serverName: serverName)
                try await MCPBrowserService.open(profile: profile, copiedAuthorizationLink: url.absoluteString)
                detail = "Complete \(serverName)'s sign-in in \(profile.name)'s Chrome window. This panel will report Codex's result."
                let status = try await service.finishLogin(serverName: serverName)
                servers = try await service.listServers()
                detail = "\(serverName) is signed in for \(profile.name). Codex reports \(status.toolCount) tools. Start a new task in this account if an existing task has not loaded them."
            } catch ProviderRPCError.timeout {
                self.error = MCPAuthorizationError.timedOut.localizedDescription
                detail = "Start a fresh login when ready."
            } catch {
                self.error = loginCancelled ? MCPAuthorizationError.cancelled.localizedDescription : error.localizedDescription
                detail = "The other profiles and their credentials were not changed."
            }
            connecting = false
        }
    }
}

import SwiftUI

struct IntegrationsView: View {
    var model: AppModel
    @State private var kind: IntegrationKind = .plugin
    @State private var query = ""
    @State private var profileID: UUID?
    @State private var add = false
    @State private var review: IntegrationAction?
    @State private var connectingProfile: Profile?
    @State private var checking = false
    private var selectedProfile: Profile? { model.deck.profiles.first { $0.id == profileID } }
    private var integrations: [IntegrationStatus] {
        model.deck.integrations.filter {
            $0.kind == kind && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) &&
            (profileID == nil || $0.profileID == profileID || $0.profileID == nil)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "Integrations", subtitle: "One desired toolset, with account permissions and compatibility shown separately.")
            controls
            if integrations.isEmpty {
                EmptyNotice(title: query.isEmpty ? "No \(kind.rawValue.lowercased()) to show" : "No matching integrations", symbol: kind == .connector ? "link" : "puzzlepiece.extension", detail: query.isEmpty ? "Add a desired integration or check the existing configuration. Installation, sign-in and functional use are checked separately." : "Try another name or choose a different profile.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(integrations) { integration in
                            IntegrationCard(model: model, integration: integration, checking: checking, check: checkIntegrations) { action in
                                review = IntegrationAction(action: action, integration: integration)
                            }
                        }
                    }.frame(maxWidth: .infinity).padding(.bottom, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Shared packages do not transfer logins. Manage unsupported actions in the owning profile’s native settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $add) { IntegrationEditor(model: model, kind: kind).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
        .sheet(item: $review) { action in IntegrationActionReview(model: model, action: action).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
        .sheet(item: $connectingProfile) { profile in MCPConnectSheet(profile: profile).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Integration kind", selection: $kind) {
                ForEach(IntegrationKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { searchField; profilePicker }
                VStack(alignment: .leading, spacing: 10) { searchField; profilePicker }
            }
            HStack(spacing: 10) {
                Text("\(integrations.count) entries").font(.caption).foregroundStyle(.secondary)
                if checking { ProgressView().controlSize(.small).accessibilityLabel("Checking integrations") }
                Spacer(minLength: 8)
                Button("Add…") { add = true }
                Button(checking ? "Checking…" : "Check all", action: checkIntegrations).disabled(checking || model.isLoading)
            }
            HStack(spacing: 10) {
                Button("Open \(selectedProfile?.name ?? "account") browser") { model.openMCPBrowser(profileID: profileID) }
                Button("Open copied sign-in link") { model.openMCPBrowser(profileID: profileID, copiedLink: true) }
                Button("Connect MCP…") { connectingProfile = selectedProfile }
            }
            .disabled(selectedProfile == nil)
            if let selectedProfile {
                Text("Separate Chrome session for \(selectedProfile.name). Previously observed ChatGPT account: \(selectedProfile.observedAccount ?? "unverified"). For account-linked plugins, sign into that account before opening an MCP link.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("If an MCP link opens in the wrong Chrome session, copy its HTTPS or local authorization link and open it here. Direct MCP servers also offer a no-browser login command below. Browser sessions and MCP permissions stay separate for each account.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var searchField: some View {
        TextField("Search integrations", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 150)
    }
    private var profilePicker: some View {
        Picker("Profile", selection: $profileID) {
            Text("All profiles").tag(Optional<UUID>.none)
            ForEach(model.deck.profiles) { Text($0.name).tag(Optional($0.id)) }
        }.labelsHidden().frame(minWidth: 145, idealWidth: 190, maxWidth: 240).accessibilityLabel("Compare profile")
    }
    private func checkIntegrations() {
        guard !checking else { return }
        checking = true
        Task { await model.refreshIntegrations(); checking = false }
    }
}
struct IntegrationAction: Identifiable { var id = UUID(); var action: String; var integration: IntegrationStatus }
struct IntegrationCard: View {
    var model: AppModel
    var integration: IntegrationStatus
    var checking: Bool
    var check: () -> Void
    var review: (String) -> Void
    private var profile: Profile? { model.deck.profiles.first { $0.id == integration.profileID } }
    private var desired: Bool {
        model.deck.integrations.first { $0.profileID == nil && $0.kind == integration.kind && $0.name.caseInsensitiveCompare(integration.name) == .orderedSame }?.desiredEnabled ?? integration.desiredEnabled
    }
    private var pluginActionsAvailable: Bool {
        do { try IntegrationService.validatePluginSelector(integration.source); return true }
        catch { return false }
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(integration.name).font(.headline).lineLimit(2).textSelection(.enabled)
                        Text(profile?.name ?? "Shared desired selection").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                    Toggle("Desired", isOn: Binding(get: { desired }, set: { var edited = integration; edited.desiredEnabled = $0; model.saveIntegration(edited) }))
                        .toggleStyle(.switch).controlSize(.small).fixedSize()
                        .help("Save shared selection; installation and authorization remain separate")
                }
                if !integration.detail.isEmpty {
                    Text(integration.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                    state("Configuration", integration.installed)
                    state("Discovery", integration.discovery)
                    state("Authorization", integration.authorization)
                    state("Compatibility", integration.compatibility)
                    state("Functional check", integration.functional)
                    state("Refresh", integration.refresh)
                }
                Divider()
                HStack(spacing: 10) {
                    Button("Check", action: check).disabled(checking)
                    if integration.kind != .connector { operationMenu }
                    Spacer(minLength: 8)
                    Button("Open profile") { openSettings() }.disabled(profile == nil)
                        .help("Open the owning profile to manage this integration in its native Settings")
                }.controlSize(.small)
                if integration.kind == .plugin {
                    Text("Package update and removal are unavailable until a recoverable provider transaction is verified.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if integration.kind == .mcp, integration.authorization != .unavailable, let profile {
                    Button("Copy isolated login command") { model.copyMCPLoginCommand(profileID: profile.id, serverName: integration.name) }
                        .help("Run the command in Terminal, then open its authorization link in this profile's account browser. Paste the resulting callback URL back into Terminal. This works for direct MCP servers known to the Codex CLI.")
                }
                if integration.kind == .mcp && !model.deck.world.managedMCPNames.contains(integration.name) {
                    Text("Approve this server name in Shared World before managing its shared enablement.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Source and evidence") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(integration.source.isEmpty ? "Source not verified" : integration.source).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("Version: \(integration.version ?? "Not verified")")
                        Text("Checked: \(integration.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("Open profile focuses the native instance. Navigate to its Settings there; an exact settings route is not available.").fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var operationMenu: some View {
        Menu("Actions") {
            if integration.kind == .plugin {
                Button("Enable…") { review("enable") }.disabled(!pluginActionsAvailable)
                Button("Disable…") { review("disable") }.disabled(!pluginActionsAvailable)
                Button("Install…") { review("install") }.disabled(!pluginActionsAvailable)
                Divider()
                Button("Update package unavailable") { }.disabled(true)
                Button("Remove package unavailable") { }.disabled(true)
            } else if integration.kind == .mcp {
                Button("Enable…") { review("enable") }.disabled(!model.deck.world.managedMCPNames.contains(integration.name))
                Button("Disable…") { review("disable") }.disabled(!model.deck.world.managedMCPNames.contains(integration.name))
            }
        }.fixedSize().accessibilityLabel("Actions for \(integration.name)")
    }
    private func state(_ label: String, _ state: HealthState) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption); HealthLabel(state: state) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func openSettings() { if let profile { model.open(profile) } }
}
struct IntegrationEditor: View {
    var model: AppModel
    var kind: IntegrationKind
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source = ""
    @State private var enabled = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add desired integration").font(.title2)
            Text("\(kind.rawValue) · shared selection").foregroundStyle(.secondary)
            TextField("Name", text: $name)
            if kind == .plugin {
                TextField("Plugin@marketplace", text: $source)
                Text("Use the provider’s package identifier, such as plugin-name@marketplace-name.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Desired in every profile", isOn: $enabled)
            Text("This records the desired selection. Installation, configuration, compatibility and authorization are checked separately. Do not enter tokens, private endpoints or credentials here.").font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            SheetFooter(title: "Add to shared selection", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, cancel: { dismiss() }) {
                var entry = IntegrationStatus(id: UUID().uuidString, name: name, kind: kind)
                entry.source = source; entry.desiredEnabled = enabled; entry.detail = "Desired selection recorded; installation and account availability have not been checked."
                if model.saveIntegration(entry) { dismiss() }
                else { error = model.errorMessage ?? "The integration could not be saved. Check its identifier."; model.errorMessage = nil }
            }
        }.padding(24).frame(width: 560)
    }
}
struct IntegrationActionReview: View {
    var model: AppModel
    var action: IntegrationAction
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(action.action.capitalized) \(action.integration.name)").font(.title2)
            Text("The provider adapter checks whether this operation is supported. Changes to shared packages are deferred while affected native instances are running.")
            LabeledContent("Source", value: action.integration.source.isEmpty ? "Not verified" : action.integration.source)
            LabeledContent("Version", value: action.integration.version ?? "Not verified")
            Text("Configuration and authentication remain distinct. Review any permission changes in the native provider flow. No sign-in tokens are transferred.").foregroundStyle(.secondary)
            SheetFooter(title: "Request \(action.action)", cancel: { dismiss() }) { model.performIntegration(action: action.action, integration: action.integration); dismiss() }
        }.padding(24).frame(width: 570)
    }
}

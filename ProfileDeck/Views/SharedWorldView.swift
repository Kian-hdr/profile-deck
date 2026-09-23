import SwiftUI

struct SharedWorldView: View {
    @Bindable var model: AppModel
    @State private var editingWorld = false
    @State private var editingInstructions = false
    @State private var applyProfile: Profile?
    @State private var restoreItem: ConfigurationTransaction?
    private var profile: Profile? { model.selectedProfile ?? model.deck.profiles.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(title: "Shared World", subtitle: "The same knowledge, skills and instructions, with separate account state.")
                HStack {
                    Button("Edit shared sources…") { editingWorld = true }
                    Button("View and edit instructions…") { editingInstructions = true }
                    Spacer()
                    Button("Check sharing") { Task { await model.refresh() } }.disabled(model.isLoading)
                }
                GroupBox("Canonical sources") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Profile home") { Text(model.deck.world.sourceHome).textSelection(.enabled) }
                        LabeledContent("Memory generator") { Text(model.deck.profiles.first { $0.id == model.deck.world.memoryOwnerID }?.name ?? "Existing owner preserved") }
                        ForEach(model.deck.world.workspacePaths, id: \.self) { path in
                            HStack { Image(systemName: "folder").foregroundStyle(.secondary); Text(path).lineLimit(2).textSelection(.enabled); Spacer(); Button("Open") { DeckPanels.openPath(path) } }
                        }
                        if model.deck.world.workspacePaths.isEmpty { Text("No shared workspace selected.").foregroundStyle(.secondary) }
                        Text("One source of truth does not merge cloud memories or already-loaded task context. Existing project instructions keep their normal precedence.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                SharedSkillsView(model: model)
                HStack {
                    Text("Profile comparison").font(.title3.weight(.semibold))
                    Spacer()
                    Picker("Profile", selection: Binding(get: { profile?.id }, set: { model.selectedProfileID = $0 })) {
                        Text("Choose a profile").tag(Optional<UUID>.none)
                        ForEach(model.deck.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 260)
                }
                if let profile, let inspection = model.sharing[profile.id] {
                    ForEach(inspection.resources) { resource in ResourceRow(resource: resource) }
                    HStack {
                        Text("Checked \(inspection.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Review and apply sharing…") { applyProfile = profile }
                    }
                } else {
                    Text("Select a registered profile and check sharing to inspect its sources. No shared state is inferred from its label.").foregroundStyle(.secondary)
                }
                GroupBox("Instruction refresh") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Saved source: inspect the resource revisions above", systemImage: "doc")
                        Label("New tasks: use applied shared sources", systemImage: "plus.bubble")
                        Label("Existing tasks: loaded context is not observable", systemImage: "questionmark.bubble")
                        Text("Refresh tools or begin a new task in the native client when needed. Profile Deck will never restart work to refresh instructions.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                recovery
            }.padding(24).accessibilityElement(children: .contain)
        }
        .sheet(isPresented: $editingWorld) { WorldEditor(model: model).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
        .sheet(isPresented: $editingInstructions) { InstructionsEditor(model: model).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
        .sheet(item: $applyProfile) { profile in SharingReview(model: model, profile: profile).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
        .confirmationDialog("Restore this manager-owned change?", isPresented: Binding(get: { restoreItem != nil }, set: { if !$0 { restoreItem = nil } }), titleVisibility: .visible) {
            Button("Restore") { if let restoreItem { model.restore(restoreItem) }; restoreItem = nil }
        } message: { Text(restoreItem?.detail ?? "") }
    }
    private var recovery: some View {
        GroupBox("Pending changes and recovery") {
            VStack(alignment: .leading, spacing: 12) {
                if model.deck.transactions.isEmpty { Text("No manager-owned configuration changes recorded.").foregroundStyle(.secondary) }
                else { Text("Pending changes are not replayed automatically. Review the selected profile and use Apply sharing or the integration action again when ready.").font(.caption).foregroundStyle(.secondary) }
                ForEach(model.deck.transactions.sorted { $0.createdAt > $1.createdAt }) { transaction in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) { Text(transaction.title).fontWeight(.medium); Text("\(transaction.state.rawValue) · \(transaction.detail)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if transaction.recoveryPath != nil && transaction.state == .applied { Button("Restore…") { restoreItem = transaction } }
                        if transaction.state == .pending {
                            Button("Review pending change") { if let p = model.deck.profiles.first(where: { $0.id == transaction.profileID }) { model.selectedProfileID = p.id } }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
struct ResourceRow: View {
    var resource: SharedResource
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(resource.name).font(.headline); Spacer(); HealthLabel(state: resource.state) }
                Text(resource.detail).foregroundStyle(.secondary)
                DisclosureGroup("Source and destination") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source: \(resource.sourcePath)"); Text("Destination: \(resource.targetPath)")
                        if let revision = resource.revision { Text("Revision: \(revision)") }
                        HStack { Button("Open source") { DeckPanels.openPath(resource.sourcePath) }; Button("Reveal destination") { DeckPanels.reveal(resource.targetPath) } }
                    }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }.padding(6)
        }
    }
}
struct WorldEditor: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var world = SharedWorld.initial
    @State private var newMCPName = ""
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Shared sources") {
                    Text("All profiles inherit one Shared World. Saving these references does not overwrite profile files.").foregroundStyle(.secondary)
                    PathPicker(title: "Canonical profile home", path: $world.sourceHome)
                    Text("This home supplies skills, AGENTS.md, memory documents and approved configuration.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Workspaces") {
                    ForEach(world.workspacePaths, id: \.self) { path in HStack { Text(path).lineLimit(2); Spacer(); Button("Remove reference") { world.workspacePaths.removeAll { $0 == path } } } }
                    Button("Add workspace…") { Task { if let url = await DeckPanels.open(directory: true), !world.workspacePaths.contains(url.path) { world.workspacePaths.append(url.path) } } }
                }
                Section("Approved shared MCP definitions") {
                    Text("Enter an existing server name from the canonical profile, not a URL, command or credential. Its definition stays in the source configuration.").font(.caption).foregroundStyle(.secondary)
                    ForEach(world.managedMCPNames, id: \.self) { name in
                        HStack {
                            Text(name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Stop sharing") { world.managedMCPNames.removeAll { $0 == name } }
                        }
                    }
                    HStack {
                        TextField("Server name", text: $newMCPName).onSubmit(addMCPName)
                        Button("Approve name", action: addMCPName).disabled(!validMCPName)
                    }
                    if !newMCPName.isEmpty && !validMCPName {
                        Text("Use a unique name containing only letters, numbers, hyphens and underscores.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Save records your approval. Review and Apply sharing separately. Credentials and live runtime endpoints are rejected rather than copied. If the source is running, definition changes remain pending until it closes.").font(.caption).foregroundStyle(.secondary)
                    Text("Stop sharing removes this approval only. Existing server definitions and connections are preserved; remove them through the owning profile when intended.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Memory ownership") {
                    Text(model.deck.profiles.first { $0.id == world.memoryOwnerID }?.name ?? "Existing memory owner preserved")
                    Text("Changing the automatic generator requires a controlled handover. This editor preserves the existing owner and does not enable another generator.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
                .deckHighContrastSurface(enabled:model.deck.settings.usesHighContrastDark)
            SheetFooter(enabled: world.sourceHome.hasPrefix("/"), cancel: { dismiss() }) { model.saveWorld(world); dismiss() }
        }.frame(width: 640, height: 620).onAppear { world = model.deck.world }
    }
    private var validMCPName: Bool {
        let name = newMCPName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return !name.isEmpty && name.unicodeScalars.allSatisfy { allowed.contains($0) } && !world.managedMCPNames.contains(name)
    }
    private func addMCPName() {
        guard validMCPName else { return }
        world.managedMCPNames.append(newMCPName.trimmingCharacters(in: .whitespacesAndNewlines))
        world.managedMCPNames.sort(); newMCPName = ""
    }
}
struct SharingReview: View {
    var model: AppModel
    var profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var preview: SharingService.ConfigurationPreview?
    @State private var loading = true
    @State private var error: String?
    @State private var retryID = UUID()
    @State private var loadedRevision = ""
    private var canApply: Bool {
        !loading && error == nil && preview != nil && loadedRevision == model.deck.world.revision
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Apply sharing to \(profile.name)").font(.title2)
                Spacer()
                Button("Refresh preview") { retryID = UUID() }.disabled(loading)
            }
            Text("Review the approved configuration fields and shared paths before applying. Account credentials, histories and loaded task context stay separate.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Approved configuration preview") {
                        VStack(alignment: .leading, spacing: 12) {
                            if loading { ProgressView("Reading the current configuration…") }
                            if let error {
                                Label("Preview unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                                Button("Retry preview") { retryID = UUID() }
                            }
                            if let preview, !loading, error == nil {
                                Text(preview.detail).textSelection(.enabled)
                                ForEach(preview.resources) { resource in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack { Text(resource.name).font(.headline); Spacer(); HealthLabel(state: resource.state) }
                                        Text(resource.detail).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Divider()
                                }
                                if preview.token == nil {
                                    Text("A complete configuration snapshot is not available. Any pending work must be reviewed again when its required profiles are closed.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("Shared paths") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let inspection = model.sharing[profile.id] {
                                Text("Last path inspection: \(inspection.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                ForEach(inspection.resources.filter { $0.id != "effective-config" }) { ResourceRow(resource: $0) }
                            } else { Text("No previous path inspection. The service checks current paths before applying.").foregroundStyle(.secondary) }
                        }.padding(8)
                    }
                    if !model.deck.world.managedMCPNames.isEmpty {
                        Text("Approved MCP names: " + model.deck.world.managedMCPNames.joined(separator: ", ")).font(.caption).textSelection(.enabled)
                    }
                }
            }
            Text("Applying rechecks the preview token. Changed configuration requires another review; running work is never restarted to synchronize settings.").font(.caption).foregroundStyle(.secondary)
            SheetFooter(title: "Apply approved sharing", enabled: canApply, cancel: { dismiss() }) {
                guard canApply else { return }
                model.applySharing(profile, expectedPreviewToken: preview?.token)
                dismiss()
            }
        }.padding(24).frame(width: 720, height: 660)
        .task(id: model.deck.world.revision + retryID.uuidString) {
            let revision = model.deck.world.revision
            loading = true; preview = nil; error = nil
            do {
                let result = try await model.previewSharing(profile)
                guard !Task.isCancelled, revision == model.deck.world.revision else { return }
                preview = result; loadedRevision = revision
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

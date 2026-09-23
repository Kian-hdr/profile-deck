import SwiftUI

struct HandoffsView: View {
    var model: AppModel
    @State private var editing: Handoff?
    @State private var remove: Handoff?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeading(title: "Handoffs", subtitle: "Prepare a brief, review it, then continue in the destination profile.")
                Button("New handoff") { editing = Handoff() }.buttonStyle(.borderedProminent).fixedSize()
            }
            if model.deck.handoffs.isEmpty { EmptyNotice(title: "Keep work moving", symbol: "arrow.right.arrow.left", detail: "Create a reviewed handoff with the current objective, verified progress and next steps. Credentials and full conversation histories are never copied automatically.") }
            else {
                List(model.deck.handoffs.sorted { $0.updatedAt > $1.updatedAt }) { handoff in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(handoff.title).font(.headline)
                            Text("\(name(handoff.sourceProfileID)) → \(name(handoff.destinationProfileID))").foregroundStyle(.secondary)
                            Text(handoff.state.rawValue).font(.caption)
                        }
                        Spacer()
                        Button("Review…") { editing = handoff }
                        Menu {
                            Button("Mark acknowledged") { model.acknowledgeHandoff(handoff.id) }
                            Button("Delete draft…", role: .destructive) { remove = handoff }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Handoff actions")
                    }.padding(.vertical, 8)
                        .listRowBackground(model.deck.settings.usesHighContrastDark ? Color.black : nil)
                }.scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
            }
            Text("Copy and open prepares the destination; it does not submit a task. Acknowledgment does not mean work is complete.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editing) { HandoffEditor(model: model, initial: $0).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
        .confirmationDialog("Delete this manager-owned handoff?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
            Button("Delete handoff", role: .destructive) { if let remove { model.removeHandoff(remove.id) }; remove = nil }
        } message: { Text("This removes its local brief. It does not delete or cancel any native task.") }
    }
    private func name(_ id: UUID?) -> String { model.deck.profiles.first { $0.id == id }?.name ?? "Not selected" }
}
struct HandoffEditor: View {
    var model: AppModel
    var initial: Handoff
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Handoff()
    @State private var preview = false
    @State private var reviewed = false
    private var ready: Bool { !draft.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.destinationProfileID != nil && draft.sourceProfileID != draft.destinationProfileID && draft.ownershipReleased && draft.canTransferSourceContext && reviewed }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Review handoff").font(.title2); Spacer(); Toggle("Preview exact brief", isOn: $preview).toggleStyle(.checkbox) }.padding(20)
            if preview { ScrollView { Text(draft.rendered).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading) } }
            else { form }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Toggle("I reviewed the exact brief and intended destination", isOn: $reviewed)
                HStack {
                    Text("Copy only; no task is submitted automatically.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save draft") { draft.state = .draft; model.saveHandoff(draft); dismiss() }
                    Button("Copy continuation brief and open destination") { draft.state = .ready; model.saveHandoff(draft); model.copyAndOpen(draft); dismiss() }.disabled(!ready).buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }.frame(width: 820, height: 700).onAppear { draft = initial }
        .onChange(of: draft.rendered) { reviewed = false }
        .onChange(of: draft.destinationProfileID) { reviewed = false }
        .onChange(of: draft.sourceProfileID) { reviewed = false }
    }
    private var form: some View {
        Form {
            Section("Destination") {
                TextField("Title", text: $draft.title)
                Picker("Source", selection: $draft.sourceProfileID) { Text("Manual brief").tag(Optional<UUID>.none); ForEach(model.deck.profiles) { Text($0.name).tag(Optional($0.id)) } }
                Picker("Destination", selection: $draft.destinationProfileID) { Text("Choose profile").tag(Optional<UUID>.none); ForEach(model.deck.profiles.filter { $0.id != draft.sourceProfileID }) { Text($0.name).tag(Optional($0.id)) } }
                PathPicker(title: "Workspace", path: $draft.workspacePath)
                if let id = draft.destinationProfileID {
                    HealthLabel(state: model.sharing[id]?.summary ?? .unchecked)
                    Text("Confirm the destination can access the workspace and required integrations before starting work.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Brief") {
                field("Objective", $draft.objective)
                field("Verified progress", $draft.progress)
                field("Files, worktree and checks", $draft.filesAndChecks)
                field("Next steps and unresolved decisions", $draft.nextSteps)
                field("Pending approvals", $draft.pendingApprovals)
                field("Background jobs", $draft.backgroundJobs)
            }
            Section("Conversation context") {
                TextField("ChatGPT shared-conversation link", text: sourceContextLink)
                    .textContentType(.URL)
                    .accessibilityHint("Optional. Only ChatGPT shared-conversation links can be included in a transferable continuation brief.")
                if draft.sourceContextKind.isTransferable {
                    Text(draft.sourceContextKind.editorDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(draft.sourceContextKind.editorDetail).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Profile Deck never fetches, reads or submits conversation content. Private Codex and ChatGPT thread links remain private to their source profile.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Ownership") {
                Toggle("Source is checkpointed and ownership is released for this handoff", isOn: $draft.ownershipReleased)
                Text("For a manual brief, confirm no conflicting work owns these files. Profile Deck does not stop the source task or transfer terminals.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
            .deckHighContrastSurface(enabled:model.deck.settings.usesHighContrastDark)
    }
    private func field(_ title: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.callout.weight(.medium)); TextEditor(text: binding).scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic).frame(minHeight: 70).border(Color(nsColor: .separatorColor)) }
    }
    private var sourceContextLink: Binding<String> {
        Binding(get: { draft.sourceContextLink ?? "" }, set: { draft.sourceContextLink = $0 })
    }
}

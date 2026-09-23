import SwiftUI

struct SharedSkillsView: View {
    var model: AppModel
    @State private var skills: [SharedResource] = []
    @State private var loading = false
    @State private var query = ""
    @State private var requestID = UUID()
    @State private var expanded = false
    private var filtered: [SharedResource] {
        skills.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.sourcePath.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        GroupBox("Shared skills") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("One canonical library; no per-account copy.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("Refresh skills") { Task { await refresh() } }.disabled(loading)
                }
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Find a skill", text: $query).textFieldStyle(.roundedBorder)
                        if filtered.isEmpty && !loading {
                            Text(skills.isEmpty ? "No skills found in the selected canonical library. Check its path and permissions." : "No matching skills.").foregroundStyle(.secondary)
                        }
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filtered) { skill in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(skill.name).fontWeight(.medium)
                                        Spacer()
                                        HealthLabel(state: skill.state)
                                        Button("Open original") { DeckPanels.openPath(skill.sourcePath) }
                                    }
                                    Text(skill.sourcePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(skill.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                        }
                    }.padding(.top, 10)
                } label: {
                    Text(loading && skills.isEmpty ? "Discovering skills…" : "\(skills.count) discovered entries")
                }
                Text("Discovery checks local source files. It does not establish that a running native task loaded a skill. Editing and generation remain with the canonical library owner.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .task(id: model.deck.world.revision) { await refresh() }
    }
    private func refresh() async {
        let request = UUID(); requestID = request; loading = true
        let result = await model.discoverSkills()
        guard !Task.isCancelled, requestID == request else { return }
        skills = result; loading = false
    }
}

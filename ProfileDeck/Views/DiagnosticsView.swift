import SwiftUI

struct DiagnosticsView: View {
    var model: AppModel
    @State private var importing: ImportDraft?
    @State private var exported: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "Diagnostics", subtitle: "See what was checked, what is unavailable and what needs attention.")
                HStack {
                    Button("Refresh checks") { Task { await model.refresh() } }
                    Button("Export redacted report…") { exportReport() }
                    Spacer()
                    Menu("Configuration") {
                        Button("Export portable configuration…") { exportConfig() }
                        Button("Import configuration…") { importConfig() }
                    }
                }
                if let exported { Label(exported, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                GroupBox("Privacy and operating limits") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Diagnostics exclude conversation bodies and credentials. Exports redact account identifiers and private paths by default.")
                        Text("Profile Deck stops monitoring when it quits. Your native instances keep running.")
                        Text("Imported configuration contains labels and desired selections, not logins, histories or shared document contents.")
                    }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                ForEach(model.deck.profiles) { profile in
                    GroupBox(profile.name) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let runtime = model.runtime[profile.id] {
                                LabeledContent("Instance", value: runtime.state.rawValue)
                                LabeledContent("Client version", value: runtime.appVersion ?? "Not verified")
                                Text(runtime.detail).foregroundStyle(.secondary)
                                ForEach(runtime.capabilities) { capability in
                                    HStack(alignment: .top) {
                                        Image(systemName: capability.available ? "checkmark.circle" : "minus.circle").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) { Text(capability.id).fontWeight(.medium); Text(capability.detail).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                Text("Checked \(runtime.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            } else { Text("No runtime inspection recorded.").foregroundStyle(.secondary) }
                            HealthLabel(state: model.sharing[profile.id]?.summary ?? .unchecked)
                            Button("Open profile") { model.open(profile) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                GroupBox("Recovery") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.deck.archivedHandoffs.isEmpty {
                            Text("No deleted handoffs to restore.").foregroundStyle(.secondary)
                        } else {
                            Text("Deleted briefs remain here until restored. Only their titles and last saved dates are shown.").font(.caption).foregroundStyle(.secondary)
                            ForEach(model.deck.archivedHandoffs.sorted { $0.updatedAt > $1.updatedAt }) { handoff in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(handoff.title).fontWeight(.medium)
                                        Text("Last saved \(handoff.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Restore") { model.restoreHandoff(handoff.id) }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Recent events") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.deck.diagnostics.isEmpty { Text("No diagnostic events recorded.").foregroundStyle(.secondary) }
                        ForEach(Array(model.deck.diagnostics.suffix(100).reversed())) { event in
                            VStack(alignment: .leading, spacing: 3) { Text("\(event.category) · \(event.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary); Text(event.message).textSelection(.enabled) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(24).accessibilityElement(children: .contain)
        }.sheet(item: $importing) { ImportConfigurationView(model: model, config: $0.config).deckHighContrastDialog(enabled:model.deck.settings.usesHighContrastDark) }
    }
    private func exportReport() { Task { if let url = await DeckPanels.save(name: "Profile-Deck-Diagnostics.txt", type: .plainText) { do { try await model.exportDiagnostics(to: url); exported = "Redacted report exported." } catch { model.report(error) } } } }
    private func exportConfig() { Task { if let url = await DeckPanels.save(name: "Profile-Deck-Configuration.json") { do { try await model.exportConfiguration(to: url); exported = "Portable configuration exported." } catch { model.report(error) } } } }
    private func importConfig() { Task { if let url = await DeckPanels.open() { do { importing = ImportDraft(config: try await model.importPreview(from: url)) } catch { model.report(error) } } } }
}
private struct ImportDraft: Identifiable { var id = UUID(); var config: PortableConfiguration }
struct ImportConfigurationView: View {
    var model: AppModel
    var config: PortableConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var homeRoot = ""
    @State private var dataRoot = ""
    @State private var reviewed = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review configuration import").font(.title2)
            Text("Map these portable profile labels to new local folders. Existing registrations remain intact; conflicts must be resolved before import.")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(config.profiles) { profile in HStack { Text(profile.name); Spacer(); Text(profile.authMode.rawValue).foregroundStyle(.secondary) } }
                    Text("\(config.integrations.count) desired integrations").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxHeight: 170)
            PathPicker(title: "New profile homes parent", path: $homeRoot)
            PathPicker(title: "New application data parent", path: $dataRoot)
            Text("Each imported profile receives a separate subfolder. No source-machine paths, credentials or runtime data are imported.").font(.caption).foregroundStyle(.secondary)
            Toggle("I reviewed the profiles and destination folders", isOn: $reviewed)
            if let error { Text(error).foregroundStyle(.red) }
            SheetFooter(title: "Import reviewed configuration", enabled: reviewed && homeRoot.hasPrefix("/") && dataRoot.hasPrefix("/") && homeRoot != dataRoot, busy: busy, cancel: { dismiss() }) {
                busy = true
                Task { do { try await model.importConfiguration(config, homeRoot: homeRoot, dataRoot: dataRoot); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
            }
        }.padding(24).frame(width: 650, height: 530)
        .onAppear {
            let root = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Profile Deck/Imported"
            homeRoot = root + "/Homes"; dataRoot = root + "/ApplicationData"
        }
        .onChange(of: homeRoot) { reviewed = false }
        .onChange(of: dataRoot) { reviewed = false }
    }
}

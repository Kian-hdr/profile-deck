import SwiftUI

struct InstructionsEditor: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var original = ""
    @State private var draft = ""
    @State private var revision = ""
    @State private var compare = false
    @State private var loading = true
    @State private var error: String?
    @State private var saving = false
    @State private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Shared instructions").font(.title2); Spacer(); Toggle("Compare changes", isOn: $compare).toggleStyle(.checkbox); Button("Open original") { DeckPanels.openPath(model.deck.world.sourceHome + "/AGENTS.md") } }
            Text("Editing the canonical AGENTS.md changes the local instructions shared by profiles. Account-hosted custom instructions remain separate where their settings cannot be synchronized.").foregroundStyle(.secondary)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { EmptyNotice(title: "Could not load instructions", symbol: "exclamationmark.triangle", detail: error) }
            else {
                HStack(alignment: .top, spacing: 12) {
                    if compare { VStack(alignment: .leading) { Text("Saved source").font(.headline); ScrollView { Text(original).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.background(.background).border(Color(nsColor: .separatorColor)) } }
                    VStack(alignment: .leading) { Text(compare ? "Your changes" : "AGENTS.md").font(.headline); TextEditor(text: $draft).font(.system(.body, design: .monospaced)).border(Color(nsColor: .separatorColor)) }
                }
            }
            Text("Saving checks that the source has not changed since it was loaded. A recovery record is kept. Existing task context is not automatically reloaded.").font(.caption).foregroundStyle(.secondary)
            if let saveError {
                Text(saveError).foregroundStyle(.red).font(.callout)
                Text("Reload saved source keeps your draft and opens comparison. Review both versions before saving again.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Button("Revert draft") { draft = original }.disabled(draft == original || loading || saving)
                Button("Reload saved source") {
                    saving = true
                    Task {
                        do {
                            let (text, hash) = try await model.readInstructions()
                            original = text; revision = hash; compare = true; saveError = nil
                        } catch { saveError = error.localizedDescription }
                        saving = false
                    }
                }.disabled(loading || saving)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save shared instructions") {
                    saving = true; saveError = nil
                    Task {
                        do { try await model.saveInstructions(text: draft, expectedHash: revision); dismiss() }
                        catch { saveError = error.localizedDescription }
                        saving = false
                    }
                }.keyboardShortcut("s").disabled(saving || loading || error != nil || draft == original)
            }
        }.padding(24).frame(minWidth: 720, idealWidth: 860, minHeight: 540, idealHeight: 660)
        .task {
            do { let (text, hash) = try await model.readInstructions(); original = text; draft = text; revision = hash }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

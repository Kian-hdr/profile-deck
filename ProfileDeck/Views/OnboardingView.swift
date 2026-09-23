import SwiftUI

struct OnboardingView: View {
    var model: AppModel
    @State private var step = 0
    @State private var selected: Set<UUID> = []
    @State private var world = SharedWorld.initial
    @State private var extra = false
    @State private var busy = false
    @State private var error: String?
    @State private var previews: [UUID: SharedInspection] = [:]
    @State private var previewLoading = false
    private let steps = ["Find client", "Choose profiles", "Shared World", "Review", "Finish"]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                Image(systemName: "person.crop.rectangle.stack.fill").font(.system(size: 36)).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) { Text("Welcome to Profile Deck").font(.title.weight(.semibold)); Text("Your accounts, with one shared world.").foregroundStyle(.secondary) }
            }
            HStack { ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                VStack(spacing: 5) { Text("\(index + 1)").font(.caption.bold()).frame(width: 24, height: 24).background(index == step ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: Circle()); Text(title).font(.caption).foregroundStyle(index == step ? .primary : .secondary) }.frame(maxWidth: .infinity)
            } }.accessibilityElement(children: .combine)
            Divider()
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }.frame(maxHeight: .infinity)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.disabled(busy) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(step == 4 ? "Finish setup" : "Continue") { if step < 4 { step += 1 } else { finish() } }.keyboardShortcut(.defaultAction).disabled(busy || (step == 3 && previewLoading) || (step == 2 && !world.sourceHome.hasPrefix("/")))
            }
        }.padding(28).frame(width: 660, height: 560)
        .onAppear { selected = Set(model.candidates.map(\.id)); world = model.deck.world }
        .task(id: previewKey) {
            guard step == 3 else { return }
            previews = [:]; previewLoading = true
            let result = await model.inspectCandidates(world: world)
            guard !Task.isCancelled else { return }
            previews = result; previewLoading = false
        }
        .sheet(isPresented: $extra) { ProfileEditor(model: model) }
    }
    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep the native client").font(.title2)
                Text("Profile Deck opens separate instances of the installed official application. Projects, chats and terminals remain in that application.")
                ForEach(model.candidates) { profile in
                    VStack(alignment: .leading, spacing: 3) { Text(profile.name).fontWeight(.medium); Text(profile.appPath).font(.caption).textSelection(.enabled); Text(model.runtime[profile.id]?.detail ?? "Client and launch support will be checked before use.").font(.caption).foregroundStyle(.secondary) }
                }
                if model.candidates.isEmpty { Text("No known profiles found. You can add a profile after setup.").foregroundStyle(.secondary) }
                Text("Client signature: not checked in this step. The official signature is validated before launch. Detected folders and app paths alone do not establish launch support; setup does not change your login.").font(.caption).foregroundStyle(.secondary)
            }
        case 1:
            VStack(alignment: .leading, spacing: 14) {
                Text("Adopt your existing profiles").font(.title2)
                Text("Select folders to register in place. Nothing is moved or copied.")
                ForEach(model.candidates) { profile in
                    Toggle(isOn: Binding(get: { selected.contains(profile.id) }, set: { if $0 { selected.insert(profile.id) } else { selected.remove(profile.id) } })) {
                        VStack(alignment: .leading) { Text(profile.name); Text(profile.homePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                Text("You can choose additional folders with Add profile after setup.").font(.caption).foregroundStyle(.secondary)
            }
        case 2:
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose the canonical sources").font(.title2)
                PathPicker(title: "Canonical profile home", path: $world.sourceHome)
                Text("Skills, global instructions and local memory documents are read from this source. Credentials and histories stay separate.")
                ForEach(world.workspacePaths.indices, id: \.self) { index in Text(world.workspacePaths[index]).font(.caption).textSelection(.enabled) }
                Button("Add workspace…") { Task { if let url = await DeckPanels.open(directory: true), !world.workspacePaths.contains(url.path) { world.workspacePaths.append(url.path) } } }
                LabeledContent("Memory generator", value: "Existing owner preserved")
                Text("No new memory generator is created. Existing running tasks may need a context refresh.").font(.caption).foregroundStyle(.secondary)
            }
        case 3:
            VStack(alignment: .leading, spacing: 12) {
                Text("Review adoption").font(.title2)
                LabeledContent("Profiles selected", value: "\(selected.count)")
                LabeledContent("Shared source", value: world.sourceHome)
                if previewLoading { ProgressView("Checking the selected shared sources…") }
                ForEach(model.candidates.filter { selected.contains($0.id) }) { profile in
                    VStack(alignment: .leading) {
                        Text(profile.name).font(.headline)
                        HealthLabel(state: previews[profile.id]?.summary ?? .unchecked)
                        ForEach(previews[profile.id]?.resources.filter { $0.state != .shared } ?? []) { resource in Text("\(resource.name): \(resource.detail)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("This step registers locations. Any missing links or configuration differences are reviewed in Shared World before applying changes.").foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 14) {
                Text("Ready to organize your profiles").font(.title2)
                Label("Existing logins and history remain in place", systemImage: "lock")
                Label("Instances open only when you ask", systemImage: "macwindow")
                Label("Unverified task and connector states stay visible", systemImage: "info.circle")
                Text("After setup, check Shared World, then open the profiles you want to use. Notification and system permissions are requested only when their features are enabled.").foregroundStyle(.secondary)
            }
        }
    }
    private var previewKey: String {
        "\(step)|\(world.sourceHome)|\(world.workspacePaths.joined(separator: "|"))"
    }
    private func finish() {
        busy = true; error = nil
        Task {
            do { try await model.adopt(model.candidates.filter { selected.contains($0.id) }, world: world) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

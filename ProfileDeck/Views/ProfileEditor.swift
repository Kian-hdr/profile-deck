import SwiftUI

struct ProfileEditor: View {
    var model: AppModel
    var existing: Profile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var auth: AuthMode = .subscription
    @State private var home = ""
    @State private var data = ""
    @State private var color = "blue"
    @State private var adopt = false
    @State private var openOnStartup = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(existing == nil ? "Add a profile" : "Edit profile").font(.title2.weight(.semibold))
                    Text("Accounts keep separate logins and history. Shared resources are reviewed separately.").foregroundStyle(.secondary)
                }
                Section("Identity") {
                    TextField("Name", text: $name)
                    Picker("Authentication", selection: $auth) { ForEach(AuthMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Colour", selection: $color) { ForEach(["blue", "green", "orange", "purple", "pink", "gray"], id: \.self) { Text($0.capitalized).tag($0) } }
                }
                Section("Startup") {
                    Toggle("Open when Profile Deck starts", isOn: $openOnStartup)
                    Text("Opens this native profile without starting a task. Opening the manager at system login is a separate setting.").font(.caption).foregroundStyle(.secondary)
                }
                if existing == nil {
                    Section("Profile folders") {
                        Toggle("Adopt existing folders", isOn: $adopt)
                        PathPicker(title: "Profile home", path: $home)
                        PathPicker(title: "Application data", path: $data)
                        Text(adopt ? "Existing folders will be registered in place. No credentials or history are copied." : "Choose new, empty folders. The native application opens after creation so you can sign in.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Existing locations") {
                        Text(home).textSelection(.enabled)
                        Text(data).textSelection(.enabled)
                        Text("Changing a label does not change the observed account or move its files.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
            }.formStyle(.grouped).disabled(busy)
                .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
                .deckHighContrastSurface(enabled:model.deck.settings.usesHighContrastDark)
            SheetFooter(title: existing == nil ? (adopt ? "Adopt profile" : "Create and open") : "Save", enabled: valid, busy: busy, cancel: { dismiss() }, action: save)
        }.frame(width: 580, height: existing == nil ? 580 : 530)
        .interactiveDismissDisabled(busy)
        .onAppear {
            if let existing { name = existing.name; auth = existing.authMode; home = existing.homePath; data = existing.dataPath; color = existing.color; openOnStartup = existing.startAtLogin }
            else {
                let root = FileManager.default.homeDirectoryForCurrentUser.path
                let id = UUID().uuidString.lowercased()
                home = "\(root)/Library/Application Support/Profile Deck/Profiles/\(id)/home"
                data = "\(root)/Library/Application Support/Profile Deck/Profiles/\(id)/app-data"
            }
        }
    }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && home.hasPrefix("/") && data.hasPrefix("/") && home != data }
    private func save() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            do {
                if let existing {
                    guard var p = model.deck.profiles.first(where: { $0.id == existing.id }) else { throw DeckError.message("This profile was removed while its editor was open.") }
                    p.name = name; p.authMode = auth; p.color = color; p.startAtLogin = openOnStartup; model.update(p)
                }
                else {
                    let created = try await model.addProfile(name: name, authMode: auth, homePath: home, dataPath: data, adoptExisting: adopt, color: color, startAtLogin: openOnStartup)
                    dismiss()
                    if created.createdByDeck { model.open(created) }
                    busy = false
                    return
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct APILoginView: View {
    var model: AppModel
    var profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var reviewed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("API key for \(profile.name)").font(.title2)
            Text("This changes authentication for this profile only. The key is passed to the supported native login flow and is never included in commands or diagnostics.")
            SecureField("API key", text: $key)
            Toggle("I intend to update this profile’s authentication", isOn: $reviewed)
            Text("The native instance must be closed. Organization, credits and billing are not inferred from the key.").font(.caption).foregroundStyle(.secondary)
            SheetFooter(title: "Set API key", enabled: reviewed && !key.isEmpty, cancel: { key = ""; dismiss() }) { model.loginAPI(profile, key: key); key = ""; dismiss() }
        }.padding(24).frame(width: 520)
    }
}

import SwiftUI
import ApplicationServices

struct DeckSettingsView: View {
    var model: AppModel
    @State private var windowAccess = AXIsProcessTrusted()
    @SceneStorage("settingsTab") private var selectedTab = "General"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings category", selection: $selectedTab) {
                Text("General").tag("General")
                Text("Notifications").tag("Notifications")
                Text("Privacy").tag("Privacy")
            }.pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 420).padding(20)
            Group {
                switch selectedTab {
                case "Notifications": notifications
                case "Privacy": privacy
                default: general
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.refreshLoginItemStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                windowAccess = AXIsProcessTrusted()
                model.refreshLoginItemStatus()
            }
    }
    private func binding<T>(_ keyPath: WritableKeyPath<DeckSettings, T>) -> Binding<T> {
        Binding(get: { model.deck.settings[keyPath: keyPath] }, set: { var settings = model.deck.settings; settings[keyPath: keyPath] = $0; model.updateSettings(settings) })
    }
    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Open Profile Deck at login", isOn: Binding(
                    get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }
                )).disabled(model.isDemo || model.isLoading)
                loginItemStatus
                Text("Enabled by default for new installations. You can turn it off here at any time.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Appearance", selection: binding(\.appearance)) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0).tag($0) } }
                Toggle("High contrast floating tabs", isOn: Binding(
                    get: { model.deck.settings.usesHighContrastTabs },
                    set: { var settings=model.deck.settings; settings.highContrastDark=$0; model.updateSettings(settings) }
                ))
                Text("Adds a darker, higher-contrast style to the floating profile tab bar. The manager and menu-bar popover keep their normal appearance.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show floating profile tabs", isOn: binding(\.showFloatingTabs))
                Button("Reset floating tabs position") { NotificationCenter.default.post(name: .deckResetTabs, object: nil) }
                Text("Profile Deck stays in the menu bar without a Dock icon. Floating tabs are optional.").font(.caption).foregroundStyle(.secondary)
            }
            SoftwareUpdateSettings()
            Section("Full-screen switching") {
                Text(windowAccess ? "Window access enabled" : "Accessibility access is not enabled")
                Text("Select a profile to follow its window into its full-screen Space. Accessibility access lets Profile Deck bring that window forward without leaving full-screen mode.").font(.caption).foregroundStyle(.secondary)
                if !windowAccess {
                    Button("Enable window access…") {
                        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        windowAccess = AXIsProcessTrustedWithOptions(options)
                    }
                }
            }
            Section("Native profiles at startup") {
                Text("Selected native profiles open when Profile Deck starts, including at login. No task is started automatically.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.deck.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(get: { profile.startAtLogin }, set: { var p = profile; p.startAtLogin = $0; model.update(p) }))
                }
            }
            Section("Quick switcher") {
                ShortcutRecorder(keyCode: binding(\.shortcutKeyCode), modifiers: binding(\.shortcutModifiers))
                if let error = model.shortcutError { Text(error).foregroundStyle(.orange).font(.caption) }
                Button("Restore Control–Option–Space") { var settings = model.deck.settings; settings.shortcutKeyCode = 49; settings.shortcutModifiers = 6144; model.updateSettings(settings) }
            }
            Section("Refresh") { Picker("Fallback interval", selection: binding(\.refreshSeconds)) { Text("1 minute").tag(60); Text("2 minutes").tag(120); Text("5 minutes").tag(300) }; Text("Closed profiles use a short-lived account reader for quota checks. Their native windows stay closed.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
            .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
            .deckHighContrastSurface(enabled:model.deck.settings.usesHighContrastDark)
    }
    @ViewBuilder private var loginItemStatus: some View {
        if model.isDemo {
            Text("Login items are unavailable in preview mode.").font(.caption).foregroundStyle(.secondary)
        } else {
            switch model.loginItemStatus {
            case .enabled:
                Label("Launch at login is enabled", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            case .requiresApproval:
                Label("Allow Profile Deck in macOS Login Items to finish enabling startup.", systemImage: "exclamationmark.circle").font(.caption)
                Button("Open Login Items…") { model.openLoginItemSettings() }
            case .notRegistered:
                Text("Launch at login is off.").font(.caption).foregroundStyle(.secondary)
            case .notFound:
                Text("Launch at login has not been set up for this copy of Profile Deck.").font(.caption).foregroundStyle(.secondary)
            case .unknown:
                Text("macOS login-item status is unavailable.").font(.caption)
            }
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
    private var notifications: some View {
        Form {
            Section {
                if !model.deck.settings.notificationsEnabled { Button("Enable notifications…") { Task { await model.enableNotifications() } } }
                else { Toggle("Enable notifications", isOn: binding(\.notificationsEnabled)) }
                Text("System permission is requested only when enabled. Profile Deck must remain running to deliver observed updates.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Categories") {
                Toggle("Task completed", isOn: binding(\.completionAlerts))
                Toggle("Needs input or approval", isOn: binding(\.inputAlerts))
                Toggle("Task failed", isOn: binding(\.failureAlerts))
                Toggle("Usage thresholds", isOn: binding(\.usageAlerts))
                Toggle("Play sound", isOn: binding(\.sound))
            }.disabled(!model.deck.settings.notificationsEnabled)
            Section("Usage alerts") {
                Stepper("Warning: \(model.deck.settings.warningThreshold)% used", value: binding(\.warningThreshold), in: 1...94)
                Stepper("Critical: \(model.deck.settings.criticalThreshold)% used", value: binding(\.criticalThreshold), in: 95...99)
                Text("A confirmed exhausted window also triggers an alert. Accounts sharing the same provider bucket are deduplicated.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
            .deckHighContrastSurface(enabled:model.deck.settings.usesHighContrastDark)
    }
    private var privacy: some View {
        Form {
            Section("Account isolation") {
                Text("Each native profile retains its own login, sessions and history. Profile Deck does not merge cloud memories or transfer connector tokens.")
                Text("Only approved local knowledge, instruction sources and tool selections are shared.")
            }
            Section("Diagnostics") {
                Text("Local event logs retain up to seven days or 20 MB. Routine logs do not contain conversation bodies.")
                Button("Open diagnostics") { model.section = .diagnostics; NotificationCenter.default.post(name: .deckShowManager, object: nil) }
            }
            Section("Recovery and removal") {
                Text("Removing a profile from Profile Deck preserves its native data. Quitting this manager leaves native instances running.")
                Button("Open shared sources and recovery") { model.section = .world; NotificationCenter.default.post(name: .deckShowManager, object: nil) }
            }
        }.formStyle(.grouped)
            .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
            .deckHighContrastSurface(enabled:model.deck.settings.usesHighContrastDark)
    }
}

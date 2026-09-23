import SwiftUI
import AppKit

@MainActor
func showProfileDeckManager() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "manager" })
        ?? NSApp.windows.first(where: { $0.title == "Profile Deck" || $0.title == "Settings" }) {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class DeckAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var panels: PanelController?
    func applicationDidFinishLaunching(_ notification:Notification) { NSApp.setActivationPolicy(.accessory); NSApp.activate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification:Notification) { model?.stopMonitoring() }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.hasActiveUpdateWork, !SoftwareUpdateStore.hasOpenEditor() else {
            model.errorMessage = "Finish or cancel open editors and wait for Profile Deck's saves before quitting or installing an update."
            NotificationCenter.default.post(name: .deckShowManager, object: nil)
            return .terminateCancel
        }
        Task {
            do {
                try await model.flushForExit()
                sender.reply(toApplicationShouldTerminate: !model.hasActiveUpdateWork && !SoftwareUpdateStore.hasOpenEditor())
            }
            catch { model.report(error); NotificationCenter.default.post(name:.deckShowManager,object:nil); sender.reply(toApplicationShouldTerminate:false) }
        }
        return .terminateLater
    }
}
@main struct ProfileDeckApp: App {
    @NSApplicationDelegateAdaptor(DeckAppDelegate.self) private var delegate
    @State private var model=AppModel()
    var body: some Scene {
        Window("Profile Deck",id:"manager") {
            ManagerScene(model:model)
                .frame(minWidth:800,minHeight:560)
                .task { delegate.model=model; if delegate.panels == nil { delegate.panels=PanelController(model:model) }; await model.bootstrap(); delegate.panels?.applySettings(); SoftwareUpdateStore.shared.configure(model: model) }
        }.defaultSize(width:1100,height:740).windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.presented)
        .commands {
            DeckSettingsCommands(model: model)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { SoftwareUpdateStore.shared.checkForUpdates() }
                    .disabled(!SoftwareUpdateStore.shared.isConfigured || !SoftwareUpdateStore.shared.canCheckForUpdates)
            }
            CommandGroup(after:.newItem) {
                Button("Quick Switch…") { NotificationCenter.default.post(name:.deckShowSwitcher,object:nil) }.keyboardShortcut("k",modifiers:.command)
                Button("Show Profile Deck") { NotificationCenter.default.post(name:.deckShowManager,object:nil) }
            }
            CommandMenu("Navigate") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.rawValue) { model.section = section; NotificationCenter.default.post(name:.deckShowManager,object:nil) }.keyboardShortcut(KeyEquivalent(Character(String(index+1))),modifiers:.command)
                }
            }
            CommandMenu("Profiles") {
                Button("Open Selected Profile") { if let p=model.selectedProfile { model.open(p) } }.disabled(model.selectedProfile == nil)
                Button("Refresh Status") { Task { await model.refresh() } }.keyboardShortcut("r",modifiers:.command)
                Divider()
                Button("Show or Hide Floating Tabs") { NotificationCenter.default.post(name:.deckToggleTabs,object:nil) }
                Button("Reset Floating Tabs Position") { NotificationCenter.default.post(name:.deckResetTabs,object:nil) }
            }
        }
        MenuBarExtra("Profile Deck",systemImage:"person.crop.rectangle.stack") { MenuContentView(model:model) }.menuBarExtraStyle(.window)
    }
}
private struct DeckSettingsCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.section = .settings
                openWindow(id: "manager")
                showProfileDeckManager()
            }.keyboardShortcut(",", modifiers: .command)
        }
    }
}
private struct ManagerScene: View {
    let model:AppModel
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        RootView(model:model)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { await model.refreshAfterClockChange() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                Task { await model.refreshAfterClockChange() }
            }
            .onReceive(NotificationCenter.default.publisher(for:.deckShowManager)) { _ in openWindow(id:"manager"); showProfileDeckManager() }
            .onReceive(NotificationCenter.default.publisher(for:.deckNotificationAction)) { note in
                if let string=note.userInfo?["profileID"] as? String, let id=UUID(uuidString:string) {
                    model.selectedProfileID=id
                    let action=note.userInfo?["action"] as? String
                    if action == "openProfile", let p=model.selectedProfile { model.open(p) }
                    else { model.section=action == "prepareHandoff" ? .handoffs : .profiles; openWindow(id:"manager"); showProfileDeckManager() }
                }
            }
    }
}

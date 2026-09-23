import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var newProfile = false
    @SceneStorage("showProfileInspector") private var showProfileDetails = true
    @SceneStorage("selectedSection") private var sectionName = AppSection.profiles.rawValue
    @SceneStorage("selectedProfile") private var storedSelection = ""
    @SceneStorage("profileSearch") private var storedSearch = ""
    @SceneStorage("profileOrder") private var storedOrder = ProfileOrder.manual.rawValue
    @SceneStorage("showHiddenProfiles") private var storedShowHidden = false
    @State private var restored = false
    var body: some View {
        // Keep the window proposal independent of each page's ideal content size.
        // Lists and empty states otherwise feed different sizes back into the split view.
        GeometryReader { viewport in
            navigation
                .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .frame(minWidth: 800, minHeight: 560)
        .deckHighContrastSurface(enabled: model.deck.settings.usesHighContrastDark)
    }
    private var navigation: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(model.section) }, set: { if let section = $0 { model.section = section; sectionName = section.rawValue } })) {
                ForEach(AppSection.allCases, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 165, ideal: 185, max: 260)
            .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
            .deckHighContrastSurface(enabled: model.deck.settings.usesHighContrastDark)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Profile Deck", systemImage: "person.crop.rectangle.stack").font(.headline)
                    Text(model.isDemo ? "Preview data · no account actions" : "One world. Independent accounts.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button(role: .destructive) {
                        // Routes through DeckAppDelegate, which flushes manager
                        // state and refuses to quit while an editor or save is active.
                        // Native ChatGPT/Codex instances are never terminated here.
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit Profile Deck", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                    .help("Quit Profile Deck. Managed native account apps stay open.")
                    .accessibilityLabel("Quit Profile Deck")
                    .accessibilityHint("Managed native account apps stay open")
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            GeometryReader { viewport in
                detail
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            }
            .deckHighContrastSurface(enabled: model.deck.settings.usesHighContrastDark)
        }
        .navigationTitle(model.section.rawValue)
        .toolbar {
            ToolbarItem { Button { newProfile = true } label: { Label("Add profile", systemImage: "plus") }.help("Add or adopt a profile") }
            ToolbarItem { Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.isLoading) }
            ToolbarItem { Button { NotificationCenter.default.post(name: .deckShowSwitcher, object: nil) } label: { Label("Quick switcher", systemImage: "rectangle.on.rectangle") } }
            ToolbarItem(placement: .primaryAction) {
                if model.section == .profiles {
                    Toggle(isOn: $showProfileDetails) {
                        Label("Details", systemImage: "sidebar.right")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.titleAndIcon)
                    .help(showProfileDetails ? "Hide details" : "Show details")
                    .accessibilityLabel(showProfileDetails ? "Hide details" : "Show details")
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(model.selectedProfile == nil)
                }
            }
        }
        .overlay(alignment: .topTrailing) { if model.isLoading { ProgressView().controlSize(.small).padding(12) } }
        .sheet(isPresented: $newProfile) { ProfileEditor(model: model).deckHighContrastDialog(enabled: model.deck.settings.usesHighContrastDark) }
        .sheet(isPresented: Binding(get: { model.storageAvailable && !model.deck.onboardingComplete && !model.isLoading }, set: { _ in })) { OnboardingView(model: model).interactiveDismissDisabled().deckHighContrastDialog(enabled: model.deck.settings.usesHighContrastDark) }
        .alert("Unable to finish", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.errorOffersAccessibility {
                Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
            }
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .task {
            guard !restored else { return }
            let savedID = UUID(uuidString: storedSelection)
            model.section = AppSection(rawValue: sectionName) ?? .profiles
            model.search = storedSearch
            model.order = ProfileOrder(rawValue: storedOrder) ?? .manual
            model.showHidden = storedShowHidden
            await model.bootstrap()
            if model.deck.lastSelectedProfileID == nil,
               let savedID, model.deck.profiles.contains(where: { $0.id == savedID }) { model.selectedProfileID = savedID }
            restored = true
        }
        .onChange(of: model.section) { if restored { sectionName = model.section.rawValue } }
        .onChange(of: model.selectedProfileID) { if restored { storedSelection = model.selectedProfileID?.uuidString ?? "" } }
        .onChange(of: model.search) { if restored { storedSearch = model.search } }
        .onChange(of: model.order) { if restored { storedOrder = model.order.rawValue } }
        .onChange(of: model.showHidden) { if restored { storedShowHidden = model.showHidden } }
    }
    @ViewBuilder private var detail: some View {
        if !model.storageAvailable {
            ContentUnavailableView("Profile storage unavailable",systemImage:"externaldrive.badge.exclamationmark",description:Text(model.storageFailure ?? "Existing native accounts and shared files are intact. Reopen Profile Deck after resolving its storage error."))
        } else { switch model.section {
        case .profiles: ProfilesView(model: model, inspect: $showProfileDetails)
        case .activity: ActivityView(model: model)
        case .world: SharedWorldView(model: model)
        case .integrations: IntegrationsView(model: model)
        case .handoffs: HandoffsView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        case .settings: DeckSettingsView(model: model)
        } }
    }
}

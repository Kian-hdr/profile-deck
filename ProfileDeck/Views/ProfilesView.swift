import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var edit: Profile?
    @State private var quit: Profile?
    @State private var removal: Profile?
    @State private var login: Profile?
    @State private var add = false
    @Binding var inspect: Bool
    @State private var detailsInteraction = ProfileDetailsInteraction()
    @State private var pointerInsideTable = false
    @FocusState private var tableFocused: Bool
    @State private var frozenOrder: [UUID]?
    @State private var nameSort: [KeyPathComparator<Profile>] = []
    @State private var dragTargetID: UUID?
    @State private var draggedProfileID: UUID?
    @SceneStorage("profileColumns") private var columns = TableColumnCustomization<Profile>()
    var body: some View {
        GeometryReader { geometry in
            let detailsWidth = inspect && model.selectedProfile != nil ? ProfileInspectorLayout.width(in: geometry.size.width) : 0
            let tableWidth = max(0, geometry.size.width - detailsWidth - (detailsWidth > 0 ? 1 : 0))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeading(title: "Your profiles", subtitle: "Open a profile to keep working. Other accounts stay where you left them.")
                        .padding([.horizontal, .top], 24)
                    controls.padding(.horizontal, 24)
                    if model.visibleProfiles.isEmpty {
                        EmptyNotice(title: model.deck.profiles.isEmpty ? "Add your first profile" : "No matching profiles", symbol: "person.crop.rectangle.badge.plus", detail: "Add a new isolated profile or adopt an existing one.")
                        Button("Add profile") { add = true }.frame(maxWidth: .infinity)
                        Spacer()
                    } else if model.order == .manual && nameSort.isEmpty {
                        manualOrderList(compact: tableWidth < 750)
                    } else {
                        table(compact: tableWidth < 750, availableWidth: tableWidth)
                    }
                }
                .frame(width: tableWidth, height: geometry.size.height)
                .deckHighContrastSurface(enabled: model.deck.settings.usesHighContrastDark)
                if detailsWidth > 0, let profile = model.selectedProfile {
                    Divider().frame(width: 1)
                    ProfileInspector(model: model, profile: profile, edit: { edit = profile }, quit: { quit = profile }, login: { login = profile })
                        .frame(width: detailsWidth, height: geometry.size.height)
                        .accessibilityLabel("Account details")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: model.order) { nameSort = []; refreshFrozenOrder() }
        .onChange(of: model.search) { refreshFrozenOrder() }
        .onChange(of: model.showHidden) { refreshFrozenOrder() }
        .onChange(of: model.visibleProfiles.map(\.id)) { refreshFrozenOrder(); ensureVisibleSelection() }
        .onAppear { ensureVisibleSelection() }
        .onDisappear { detailsInteraction.cancelPendingReveal() }
        .onChange(of: inspect) { detailsInteraction.cancelPendingReveal() }
        .onChange(of: tableFocused) { updateInteractionFreeze() }
        .sheet(item: $edit) { ProfileEditor(model: model, existing: $0).deckHighContrastDialog(enabled: model.deck.settings.usesHighContrastDark) }
        .sheet(item: $login) { APILoginView(model: model, profile: $0).deckHighContrastDialog(enabled: model.deck.settings.usesHighContrastDark) }
        .sheet(isPresented: $add) { ProfileEditor(model: model).deckHighContrastDialog(enabled: model.deck.settings.usesHighContrastDark) }
        .confirmationDialog("Quit \(quit?.name ?? "profile")?", isPresented: Binding(get: { quit != nil }, set: { if !$0 { quit = nil } }), titleVisibility: .visible) {
            Button("Quit profile", role: .destructive) { if let quit { model.requestQuit(quit) }; quit = nil }
            Button("Cancel", role: .cancel) { quit = nil }
        } message: { Text("Task status may be unavailable. Running work could be interrupted. The native app will handle any unsaved-work prompts.") }
        .confirmationDialog("Remove \(removal?.name ?? "profile") from Profile Deck?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove registration", role: .destructive) { if let removal { model.remove(removal) }; removal = nil }
        } message: { Text("Its login, history, profile folders and shared resources will remain in place.") }
    }
    private var controls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    profileSearch.frame(width: 270)
                    filters
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    profileSearch
                    filters
                }
            }
            HStack {
                Text("\(model.visibleProfiles.count) profiles").font(.caption).foregroundStyle(.secondary)
                if let profile = model.selectedProfile { Text("· " + profile.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let profile = model.selectedProfile, model.opening.contains(profile.id) {
                    ProgressView().controlSize(.small)
                    Text("Preparing and opening profile…").font(.callout)
                }
                Button("Open profile") { if let profile = model.selectedProfile { model.open(profile) } }.buttonStyle(.borderedProminent).disabled(model.selectedProfile == nil || model.selectedProfileID.map { model.opening.contains($0) } == true)
            }
        }
    }
    private var profileSearch: some View {
        TextField("Search profiles", text: $model.search).textFieldStyle(.roundedBorder)
    }
    private var filters: some View {
        HStack {
            Picker("Order", selection: $model.order) { ForEach(ProfileOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 160)
            Toggle("Show hidden", isOn: $model.showHidden).toggleStyle(.checkbox)
            if model.order == .manual && nameSort.isEmpty {
                Text(model.search.isEmpty ? "Drag rows to reorder" : "Dragging reorders visible slots only")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Choose Manual order to reorder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
    private func ensureVisibleSelection() {
        guard !model.visibleProfiles.contains(where: { $0.id == model.selectedProfileID }) else { return }
        model.selectedProfileID = model.visibleProfiles.first?.id
    }
    private func table(compact: Bool, availableWidth: CGFloat) -> some View {
        let compactWidth = max(240, availableWidth - 30)
        return Table(orderedProfiles, selection: Binding(get: { model.selectedProfileID }, set: { id in
            model.selectedProfileID = id
            if id != nil, detailsInteraction.shouldRevealForSelection(isKeyboard: NSApp.currentEvent?.type == .keyDown) { inspect = true }
        }), sortOrder: $nameSort, columnCustomization: $columns) {
            TableColumn("Profile", value: \.name) { profile in
                HStack {
                    ProfileGlyph(profile: profile)
                    Text(profile.name).fontWeight(.medium).lineLimit(1).help(profile.name)
                    if profile.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Favourite") }
                }
                    .padding(.vertical, 2)
            }.width(min: compact ? compactWidth * 0.4 : 110, ideal: compact ? compactWidth * 0.4 : 200, max: compact ? compactWidth * 0.4 : .infinity).customizationID("name")
            TableColumn("Account") { profile in
                VStack(alignment: .leading) { Text(profile.authMode.rawValue); Text(profile.observedAccount ?? (profile.verifiedAuthMode == .apiKey ? "API key verified" : "Identity not verified")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.width(min: compact ? compactWidth * 0.37 : 95, ideal: compact ? compactWidth * 0.37 : 160, max: compact ? compactWidth * 0.37 : .infinity).customizationID("account")
            TableColumn("Instance") { profile in Text(model.opening.contains(profile.id) ? "Opening…" : (model.runtime[profile.id]?.state.rawValue ?? "Not checked")).lineLimit(1) }.width(min: compact ? compactWidth * 0.23 : 65, ideal: compact ? compactWidth * 0.23 : 90, max: compact ? compactWidth * 0.23 : .infinity).customizationID("instance")
            if !compact {
                TableColumn("Attention") { profile in Text(attention(profile)).foregroundStyle(.secondary) }.width(min: 85, ideal: 110).customizationID("attention")
                TableColumn("Usage") { profile in
                    if let snapshot = model.deck.usage.first(where: { $0.profileID == profile.id }),
                       snapshot.observedAuthMode != .apiKey, let window = snapshot.windows.first,
                       window.usedPercent.isFinite, (0...100).contains(window.usedPercent) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(window.label + (snapshot.isFresh() ? "" : " · cached")).font(.caption2).foregroundStyle(.secondary)
                            AllowanceMeter(window: window, isFresh: snapshot.isFresh())
                        }.padding(.vertical, 3)
                    } else { Text(usageSummary(profile)).font(.caption).foregroundStyle(.secondary) }
                }.width(min: 85, ideal: 110).customizationID("usage")
            }
            if !compact {
                TableColumn("Shared World") { profile in HealthLabel(state: model.sharing[profile.id]?.summary ?? .unchecked) }.width(min: 95, ideal: 115).customizationID("world")
            }
        }
        .background(ProfileTableClickObserver { row in
            guard !inspect, orderedProfiles.indices.contains(row) else { return }
            let id = orderedProfiles[row].id
            detailsInteraction.deferPointerReveal {
                guard model.selectedProfileID == id else { return }
                inspect = true
            }
        })
        .focused($tableFocused)
        .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
        .deckHighContrastSurface(enabled: model.deck.settings.usesHighContrastDark)
        .onHover { pointerInsideTable = $0; updateInteractionFreeze() }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let profile = model.deck.profiles.first(where: { $0.id == id }) { actions(profile) }
        } primaryAction: { ids in
            detailsInteraction.cancelPendingReveal()
            if let id = ids.first, let profile = model.deck.profiles.first(where: { $0.id == id }) {
                inspect = true
                model.open(profile)
            }
        }
    }
    private func manualOrderList(compact: Bool) -> some View {
        let profiles = model.visibleProfiles
        return ScrollView {
            LazyVStack(spacing: 4) {
                ProfileManualOrderHeader(compact: compact)
                ForEach(profiles) { profile in
                    ProfileManualOrderRow(
                        profile: profile,
                        account: profile.observedAccount ?? (profile.verifiedAuthMode == .apiKey ? "API key verified" : "Identity not verified"),
                        instance: model.opening.contains(profile.id) ? "Opening…" : (model.runtime[profile.id]?.state.rawValue ?? "Not checked"),
                        usage: usageSummary(profile),
                        selected: model.selectedProfileID == profile.id,
                        compact: compact,
                        showsInsertionTarget: dragTargetID == profile.id,
                        select: {
                            model.selectedProfileID = profile.id
                            inspect = true
                        },
                        beginDrag: {
                            draggedProfileID = profile.id
                            return NSItemProvider(object: profile.id.uuidString as NSString)
                        }
                    )
                    .onDrop(of: [UTType.plainText.identifier], delegate: ProfileRowDropDelegate(
                        targetID: profile.id,
                        isEnabled: true,
                        draggingID: $draggedProfileID,
                        dragTargetID: $dragTargetID,
                        visibleIDs: profiles.map(\.id),
                        reorder: { source, target, visible in
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                model.reorderManually(moving: source, before: target, visibleIDs: visible)
                            }
                        }
                    ))
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: profiles.map(\.id))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
        .deckHighContrastSurface(enabled: model.deck.settings.usesHighContrastDark)
        .accessibilityLabel("Manual profile order")
    }
    private var orderedProfiles: [Profile] {
        nameSort.isEmpty ? displayedProfiles : displayedProfiles.sorted(using: nameSort)
    }
    private var displayedProfiles: [Profile] {
        guard let frozenOrder else { return model.visibleProfiles }
        let current = Dictionary(uniqueKeysWithValues: model.visibleProfiles.map { ($0.id, $0) })
        return frozenOrder.compactMap { current[$0] }
    }
    private func updateInteractionFreeze() {
        if pointerInsideTable || tableFocused {
            if frozenOrder == nil { frozenOrder = model.visibleProfiles.map(\.id) }
        } else { frozenOrder = nil }
    }
    private func refreshFrozenOrder() {
        if pointerInsideTable || tableFocused { frozenOrder = model.visibleProfiles.map(\.id) }
    }
    private func usageSummary(_ profile: Profile) -> String {
        guard let snapshot = model.deck.usage.first(where: { $0.profileID == profile.id }) else { return "Not checked" }
        if let spend = snapshot.apiSpend {
            guard let amount = spend.monthUSD else { return "Costs pending" }
            return amount.formatted(.currency(code: "USD")) + " · month (UTC)"
        }
        guard let window = snapshot.windows.first else { return snapshot.observedAuthMode == .apiKey ? "Link spending source" : "Unavailable" }
        guard snapshot.isFresh() else { return "Stale reading" }
        return "\(Int(window.usedPercent))% used · \(window.label)"
    }
    private func attention(_ profile: Profile) -> String {
        let tasks = model.deck.tasks.filter { $0.profileID == profile.id }
        if tasks.contains(where: { $0.state == .input }) { return "Needs input" }
        if tasks.contains(where: \.unread) { return "Unread update" }
        return "Status unavailable"
    }
    @ViewBuilder private func actions(_ profile: Profile) -> some View {
        Button("Open profile") { model.open(profile) }
        Button("Edit profile…") { edit = profile }
        Button(profile.favorite ? "Remove favourite" : "Favourite") { var p = profile; p.favorite.toggle(); model.update(p) }
        Button(profile.hidden ? "Show profile" : "Hide profile") { var p = profile; p.hidden.toggle(); model.update(p) }
        Button(profile.tabVisible ? "Hide floating tab" : "Show floating tab") { var p = profile; p.tabVisible.toggle(); model.update(p) }
        Button("Move up") { model.move(profile, offset: -1) }
            .disabled(model.order != .manual || !nameSort.isEmpty)
        Button("Move down") { model.move(profile, offset: 1) }
            .disabled(model.order != .manual || !nameSort.isEmpty)
        Divider()
        Button("Quit profile…") { quit = profile }
        Button("Remove registration…", role: .destructive) { removal = profile }
    }
}

private struct ProfileManualOrderHeader: View {
    let compact: Bool
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 22)
            Text("Profile").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            Text("Account").frame(width: compact ? 110 : 170, alignment: .leading)
            Text("Instance").frame(width: 82, alignment: .leading)
            if !compact { Text("Usage").frame(width: 120, alignment: .leading) }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct ProfileManualOrderRow: View {
    let profile: Profile
    let account: String
    let instance: String
    let usage: String
    let selected: Bool
    let compact: Bool
    let showsInsertionTarget: Bool
    let select: () -> Void
    let beginDrag: () -> NSItemProvider

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
                .onDrag(beginDrag)
                .help("Drag \(profile.name) to reorder")
                .accessibilityLabel("Drag \(profile.name) to reorder")
            HStack(spacing: 8) {
                ProfileGlyph(profile: profile)
                Text(profile.name).fontWeight(.medium).lineLimit(1)
                if profile.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Favourite") }
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.authMode.rawValue)
                Text(account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: compact ? 110 : 170, alignment: .leading)
            Text(instance).foregroundStyle(.secondary).lineLimit(1).frame(width: 82, alignment: .leading)
            if !compact { Text(usage).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .leading) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .top) {
            if showsInsertionTarget {
                Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Select profile", select)
    }
}

private struct ProfileRowDropDelegate: DropDelegate {
    let targetID: UUID
    let isEnabled: Bool
    @Binding var draggingID: UUID?
    @Binding var dragTargetID: UUID?
    let visibleIDs: [UUID]
    let reorder: (UUID, UUID, [UUID]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        guard isEnabled, let source = draggingID, source != targetID else { return }
        dragTargetID = targetID
        reorder(source, targetID, visibleIDs)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isEnabled ? DropProposal(operation: .move) : DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isEnabled else { return false }
        defer { draggingID = nil; dragTargetID = nil }
        if let source = draggingID, source != targetID {
            reorder(source, targetID, visibleIDs)
            return true
        }
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let string = value as? NSString,
                  let source = UUID(uuidString: String(string)), source != targetID else { return }
            Task { @MainActor in reorder(source, targetID, visibleIDs) }
        }
        return true
    }
}

@MainActor final class ProfileDetailsInteraction {
    private var pending: Task<Void, Never>?
    private(set) var pointerSelectionPending = false
    func deferPointerReveal(delay: Duration = .seconds(NSEvent.doubleClickInterval), reveal: @escaping @MainActor () -> Void) {
        cancelPendingReveal()
        pointerSelectionPending = true
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pointerSelectionPending = false
            self.pending = nil
            reveal()
        }
    }
    func shouldRevealForSelection(isKeyboard: Bool) -> Bool {
        if isKeyboard { cancelPendingReveal(); return true }
        return !pointerSelectionPending
    }
    func cancelPendingReveal() {
        pending?.cancel()
        pending = nil
        pointerSelectionPending = false
    }
}

/// SwiftUI Table does not emit a selection change when the selected row is
/// clicked again. Observe only local mouse events over this table, leaving its
/// native selection and primaryAction (double-click) handling intact.
struct ProfileTableClickObserver: NSViewRepresentable {
    var onRowClick: (Int) -> Void
    func makeNSView(context: Context) -> ProfileTableClickView {
        let view = ProfileTableClickView()
        view.onRowClick = onRowClick
        return view
    }
    func updateNSView(_ view: ProfileTableClickView, context: Context) { view.onRowClick = onRowClick }
    static func dismantleNSView(_ view: ProfileTableClickView, coordinator: ()) { view.stopObserving() }
}

@MainActor final class ProfileTableClickView: NSView {
    var onRowClick: ((Int) -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.observe(event) ?? event
        }
    }
    func observe(_ event: NSEvent) -> NSEvent {
        guard event.clickCount == 1, let row = clickedRow(event) else { return event }
        // Set the pending-click gate before native selection updates its binding.
        // The callback schedules presentation; it does not change table selection.
        onRowClick?(row)
        return event
    }
    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func clickedRow(_ event: NSEvent) -> Int? {
        guard let window, event.window === window,
              !isHiddenOrHasHiddenAncestor,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let content = window.contentView else { return nil }
        return Self.row(at: event.locationInWindow, in: content)
    }
    static func row(at point: NSPoint, in view: NSView) -> Int? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let table = view as? NSTableView {
            let local = table.convert(point, from: nil)
            guard table.visibleRect.contains(local) else { return nil }
            let row = table.row(at: local)
            return row >= 0 ? row : nil
        }
        for child in view.subviews {
            if let row = row(at: point, in: child) { return row }
        }
        return nil
    }
}

struct ProfileInspector: View {
    var model: AppModel
    var profile: Profile
    var edit: () -> Void
    var quit: () -> Void
    var login: () -> Void
    @State private var billingSources: [BillingSource] = []
    @State private var billingError: String?
    var body: some View {
        let profile = model.deck.profiles.first(where: { $0.id == self.profile.id }) ?? self.profile
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProfileInspectorSection {
                    Label(profile.name, systemImage: "person.crop.rectangle").font(.title2)
                    LabeledContent("Authentication", value: profile.authMode.rawValue)
                    Text(profile.observedAccount ?? (profile.verifiedAuthMode == .apiKey ? "API-key authentication verified. Organization identity is not provided by this login." : "Account identity has not been verified.")).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Edit profile…", action: edit)
                }
                ProfileInspectorSection("Usage") {
                    UsageDetailView(snapshot: model.deck.usage.first { $0.profileID == profile.id }, authMode: profile.verifiedAuthMode ?? profile.authMode)
                    if (profile.verifiedAuthMode ?? profile.authMode) == .apiKey {
                        Text("Link a Prompt Balance source for organization-wide spending. These costs include other API activity in that organization.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Spending source", selection: Binding(get: { profile.billingSourceID ?? "" }, set: {
                            model.setBillingSource($0.isEmpty ? nil : $0, for: profile.id)
                        })) {
                            Text("Not linked").tag("")
                            ForEach(billingSources) { Text($0.name).tag($0.id) }
                            if let selected = profile.billingSourceID, !billingSources.contains(where: { $0.id == selected }) {
                                Text("Saved source unavailable").tag(selected)
                            }
                        }
                        if let billingError { Text(billingError).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ProfileInspectorSection("Menu-bar usage") {
                    UsagePreviewControls(model: model, profileID: profile.id)
                    Text("Choose the previews shown for this account. Usage details and alerts keep working.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProfileInspectorSection("Native instance") {
                    Text(model.runtime[profile.id]?.detail ?? "Not checked")
                    if let runtime = model.runtime[profile.id], let version = runtime.appVersion { LabeledContent("Client version", value: version) }
                    Button("Open profile") { model.open(profile) }
                    if model.runtime[profile.id]?.capabilities.contains(where: { $0.id == "windowFocus" && $0.available }) == true {
                        ForEach(model.runtime[profile.id]?.windows ?? []) { window in
                            Button(window.title.isEmpty ? "Focus native window" : "Focus \(window.title)") {
                                model.focus(profile, windowID: window.id)
                            }.lineLimit(2)
                        }
                    } else {
                        Text("Exact window selection needs Accessibility access. Open profile still activates the selected instance.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if profile.authMode == .apiKey { Button("Set API key…", action: login) }
                    Button("Quit profile…", action: quit)
                }
                ProfileInspectorSection("Startup") {
                    Toggle("Open when Profile Deck starts", isOn: Binding(get: { profile.startAtLogin }, set: { var p = profile; p.startAtLogin = $0; model.update(p) }))
                    Text("Includes login when Profile Deck starts with macOS. No task starts automatically.").font(.caption).foregroundStyle(.secondary)
                }
                ProfileInspectorSection("Shared World") {
                    HealthLabel(state: model.sharing[profile.id]?.summary ?? .unchecked)
                    Button("Inspect shared sources") { model.selectedProfileID = profile.id; model.section = .world }
                }
                ProfileInspectorSection("Notifications") {
                    Toggle("Mute this profile", isOn: Binding(get: { profile.muted }, set: { var p = profile; p.muted = $0; model.update(p) }))
                    Button("Snooze for one hour") { var p = profile; p.snoozedUntil = Date().addingTimeInterval(3600); model.update(p) }
                }
                ProfileInspectorSection("Folders") {
                    Button("Reveal profile folder") { DeckPanels.reveal(profile.homePath) }
                    Button("Reveal application data") { DeckPanels.reveal(profile.dataPath) }
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        // Reserve space inside the scrollable content, not outside the scroll view:
        // overlay scrollers otherwise draw over trailing switches and values.
        .contentMargins(.trailing, ProfileInspectorLayout.scrollerClearance, for: .scrollContent)
        .scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
        .deckHighContrastSurface(enabled: model.deck.settings.usesHighContrastDark, surface: DeckVercelPalette.panel)
        .task(id: profile.id) {
            do { billingSources = try await model.billingSources(); billingError = nil }
            catch { billingError = error.localizedDescription }
        }
    }
}

@MainActor enum ProfileInspectorLayout {
    static func width(in availableWidth: CGFloat) -> CGFloat {
        min(360, max(240, availableWidth - 520))
    }
    static var scrollerClearance: CGFloat {
        max(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay),
            NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)) + 4
    }
}

private struct ProfileInspectorSection<Content: View>: View {
    private let title: String?
    private let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

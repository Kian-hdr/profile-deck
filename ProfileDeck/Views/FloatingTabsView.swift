import SwiftUI

/// One row with reserved controls. Excess profiles remain available in a named menu.
struct FloatingTabsLayout {
    static let padding: CGFloat = 6
    static let gap: CGFloat = 4
    static let trafficLightsWidth: CGFloat = 72
    static let controlsWidth: CGFloat = trafficLightsWidth + gap + 26
    static let minimumTabWidth: CGFloat = 88
    static let idealTabWidth: CGFloat = 128
    static let rowHeight: CGFloat = 34
    static let panelHeight: CGFloat = rowHeight + padding * 2
    let visibleCount: Int
    let overflowCount: Int
    let tabWidth: CGFloat
    let tabsWidth: CGFloat
    let controlWidth: CGFloat
    static func preferredWidth(count: Int, maximumWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(300, padding * 2 + controlsWidth + gap + CGFloat(max(1, count)) * idealTabWidth + CGFloat(max(0, count - 1)) * gap))
    }
    init(width: CGFloat, count: Int) {
        let initial = max(1, Int((width - Self.padding * 2 - Self.controlsWidth) / (Self.minimumTabWidth + Self.gap)))
        controlWidth = Self.controlsWidth + (count > initial ? 28 : 0)
        tabsWidth = max(1, width - Self.padding * 2 - Self.gap - controlWidth)
        visibleCount = min(count, max(1, Int((tabsWidth + Self.gap) / (Self.minimumTabWidth + Self.gap))))
        overflowCount = max(0, count - visibleCount)
        tabWidth = max(1, (tabsWidth - CGFloat(max(0, visibleCount - 1)) * Self.gap) / CGFloat(max(1, visibleCount)))
    }
}

struct FloatingTabsView: View {
    var model: AppModel
    var maximumWidth: CGFloat = 1600
    var onPreferredSizeChange: (CGSize) -> Void = { _ in }
    @State private var search = ""
    @State private var showSearch = false
    @State private var stripHovered=false
    @State private var hoveredProfileID: UUID?
    private var profiles: [Profile] {
        model.deck.profiles.filter { !$0.hidden && $0.tabVisible && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }; return $0.id.uuidString < $1.id.uuidString }
    }
    var body: some View {
        GeometryReader { geometry in
            let layout = FloatingTabsLayout(width: geometry.size.width, count: profiles.count)
            HStack(spacing: FloatingTabsLayout.gap) {
                trafficLights
                    .padding(.leading, 6).padding(.trailing, 8)
                    .frame(width:FloatingTabsLayout.trafficLightsWidth, height:FloatingTabsLayout.rowHeight)
                HStack(spacing: FloatingTabsLayout.gap) {
                    if profiles.isEmpty {
                        Text(search.isEmpty ? "No visible tabs" : "No matching tabs")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(profiles.prefix(layout.visibleCount))) { profile in
                        tab(profile).frame(width: layout.tabWidth)
                    }
                }.frame(width: layout.tabsWidth, height: FloatingTabsLayout.rowHeight)
                HStack(spacing: 0) {
                    if layout.overflowCount > 0 { overflowMenu(layout).frame(width: 28) }
                    searchControl.frame(width:26)
                }.frame(width: layout.controlWidth - FloatingTabsLayout.trafficLightsWidth - FloatingTabsLayout.gap, height: FloatingTabsLayout.rowHeight)
            }
            .padding(FloatingTabsLayout.padding)
            .onChange(of: preferredSize, initial: true) { _, size in onPreferredSizeChange(size) }
        }
        .background {
            RoundedRectangle(cornerRadius:10).fill(model.deck.settings.usesHighContrastTabs ? AnyShapeStyle(DeckVercelPalette.surface) : AnyShapeStyle(.regularMaterial))
        }
        .deckHighContrastContent(enabled:model.deck.settings.usesHighContrastTabs)
        .contentShape(Rectangle())
        .onHover { stripHovered=$0 }
        .onDisappear { stripHovered=false; hoveredProfileID=nil }
        .onReceive(NotificationCenter.default.publisher(for:.deckTabsPointerRefresh)) { event in
            if let hovered=event.userInfo?["hovered"] as? Bool { stripHovered=hovered; if !hovered { hoveredProfileID=nil } }
        }
        .contextMenu {
            Button("Show manager") { NotificationCenter.default.post(name:.deckShowManager,object:nil) }
            Button("Reset position") { NotificationCenter.default.post(name:.deckResetTabs,object:nil) }
            Button("Hide strip") { NotificationCenter.default.post(name:.deckHideTabs,object:nil) }
            if model.deck.profiles.contains(where: { !$0.tabVisible }) {
                Divider()
                ForEach(model.deck.profiles.filter { !$0.tabVisible }) { profile in
                    Button("Show \(profile.name)") { var p=profile; p.tabVisible=true; model.update(p) }
                }
            }
        }
    }
    private var preferredSize: CGSize {
        CGSize(width: FloatingTabsLayout.preferredWidth(count: model.deck.profiles.filter { !$0.hidden && $0.tabVisible }.count, maximumWidth: maximumWidth), height: FloatingTabsLayout.panelHeight)
    }
    private func overflowMenu(_ layout: FloatingTabsLayout) -> some View {
        Menu {
            ForEach(Array(profiles.dropFirst(layout.visibleCount))) { profile in
                let presentation = presentation(for: profile)
                Button("\(presentation.action) \(profile.name)") { activate(profile) }
                    .disabled(!presentation.allowsActivation)
            }
        } label: { Text("+\(layout.overflowCount)").font(.caption).monospacedDigit().frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More profiles: \(layout.overflowCount)").accessibilityLabel("\(layout.overflowCount) more profiles")
    }
    private var trafficLights: some View {
        HStack(spacing:8) {
            FloatingTrafficLight(color:.red,symbol:"xmark",label:"Hide profile tabs",stripHovered:stripHovered) {
                NotificationCenter.default.post(name:.deckHideTabs,object:nil)
            }
            FloatingTrafficLight(color:.yellow,symbol:"minus",label:"Minimize unavailable",stripHovered:stripHovered,enabled:false) {}
            FloatingTrafficLight(color:.green,symbol:"plus",label:"Open manager",stripHovered:stripHovered) {
                NotificationCenter.default.post(name:.deckShowManager,object:nil)
            }
        }
    }
    private var searchControl: some View {
            Button { showSearch.toggle() } label: {
                Image(systemName: search.isEmpty ? "magnifyingglass" : "line.3.horizontal.decrease.circle.fill")
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain).help("Search profile tabs").accessibilityLabel("Search profile tabs")
            .popover(isPresented: $showSearch) {
                VStack(alignment: .leading) {
                    TextField("Filter tabs", text: $search).textFieldStyle(.roundedBorder)
                    Button("Clear filter") { search = "" }
                    Button("Open quick switcher") {
                        NotificationCenter.default.post(name: .deckShowSwitcher, object: nil); showSearch = false
                    }
                }.padding().frame(width: 250)
            }
    }
    private func tabBackground(_ profile: Profile) -> Color {
        if model.deck.settings.usesHighContrastTabs {
            if model.selectedProfileID == profile.id {
                return hoveredProfileID == profile.id ? DeckVercelPalette.selectionHover : DeckVercelPalette.selection
            }
            return hoveredProfileID == profile.id ? DeckVercelPalette.control : DeckVercelPalette.secondarySurface
        }
        return model.selectedProfileID == profile.id ? .accentColor.opacity(0.18) : .primary.opacity(0.055)
    }
    private func tab(_ profile: Profile) -> some View {
        let presentation = presentation(for: profile)
        return Button { activate(profile) } label: {
            HStack(spacing: 6) {
                ProfileGlyph(profile: profile).frame(width: 16)
                Text(profile.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.deck.tasks.contains(where: { $0.profileID == profile.id && $0.unread }) {
                    Image(systemName: "circle.fill").font(.system(size: 6)).accessibilityLabel("Unread update")
                }
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: FloatingTabsLayout.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(tabBackground(profile), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if model.deck.settings.usesHighContrastTabs {
                    RoundedRectangle(cornerRadius:7).strokeBorder((model.selectedProfileID == profile.id ? DeckVercelPalette.focusBorder : DeckVercelPalette.border),lineWidth:1)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.deck.settings.usesHighContrastTabs ? DeckVercelPalette.ink : (model.selectedProfileID == profile.id ? Color.accentColor : Color.primary))
        .opacity(presentation.opacity)
        .disabled(!presentation.allowsActivation)
        .onHover { hovering in
            if hovering { hoveredProfileID=profile.id }
            else if hoveredProfileID == profile.id { hoveredProfileID=nil }
        }
        .help("\(presentation.detail) \(profile.name)")
        .accessibilityLabel("\(presentation.action) \(profile.name)")
        .accessibilityValue(presentation.detail)
        .accessibilityAddTraits(model.selectedProfileID == profile.id ? .isSelected : [])
        .contextMenu {
            Button(profile.favorite ? "Unpin" : "Pin") { var p = profile; p.favorite.toggle(); model.update(p) }
            Button("Move earlier") { model.move(profile, offset: -1) }
            Button("Move later") { model.move(profile, offset: 1) }
            Button("Open profile") { model.open(profile) }
            Divider()
            Button("Hide tab") { var p = profile; p.tabVisible = false; model.update(p) }
        }
    }
    private func presentation(for profile: Profile) -> FloatingTabPresentation {
        FloatingTabPresentation(state: model.opening.contains(profile.id) ? .launching : (model.runtime[profile.id]?.state ?? .unknown))
    }
    private func activate(_ profile: Profile) {
        let presentation = presentation(for: profile)
        guard presentation.allowsActivation else { return }
        model.activateFloatingTab(profile)
    }
}

struct FloatingTabPresentation: Equatable {
    let state: ProcessState
    var action: String { state == .open ? "Focus" : "Open" }
    var allowsActivation: Bool { state == .closed || state == .open }
    var opacity: Double { state == .closed ? 0.62 : state == .unknown || state == .unresponsive ? 0.74 : 1 }
    var detail: String {
        switch state {
        case .open: "Running native instance. Click to select."
        case .closed: "Confirmed closed native instance. Click to open."
        case .launching: "Opening native instance."
        case .unknown: "Native instance state could not be verified. Open the manager for details."
        case .unresponsive: "Native instance is not responding. Open the manager for details."
        }
    }
}

private struct FloatingTrafficLight: View {
    var color: Color
    var symbol: String
    var label: String
    var stripHovered: Bool
    var enabled=true
    var action: () -> Void
    @State private var hovering=false
    var body: some View {
        Button(action:action) {
            ZStack {
                Circle().fill(stripHovered ? color.opacity(enabled ? 0.9 : 0.3) : Color.gray.opacity(enabled ? 0.75 : 0.4))
                if hovering && enabled {
                    Image(systemName:symbol).font(.system(size:7,weight:.bold)).foregroundStyle(.black.opacity(0.7))
                }
            }.frame(width:12,height:12).frame(width:14,height:24)
        }
        .buttonStyle(.plain).disabled(!enabled).onHover { hovering=$0 }
        .help(label).accessibilityLabel(label)
    }
}

import SwiftUI

struct QuickSwitcherView: View {
    var model: AppModel
    var onDismiss: () -> Void
    @State private var query = ""
    @State private var snapshot: [Profile] = []
    @State private var selected: UUID?
    @FocusState private var focused: Bool
    @State private var focusTask: Task<Void, Never>?
    private var matches: [Profile] {
        snapshot.filter { profile in
            query.isEmpty || profile.name.localizedCaseInsensitiveContains(query) || (profile.observedAccount?.localizedCaseInsensitiveContains(query) ?? false) || model.deck.tasks.contains { $0.profileID == profile.id && $0.title.localizedCaseInsensitiveContains(query) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Switch to a profile or task…", text: $query).textFieldStyle(.plain).font(.title3).focused($focused).onSubmit(activate)
                Button { dismissSwitcher() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Close quick switcher")
            }.padding(20)
            Divider()
            if matches.isEmpty { EmptyNotice(title: "No matches", symbol: "magnifyingglass", detail: "Search profile names, account labels or available task titles.").frame(height: 210) }
            else {
                List(selection: $selected) {
                    ForEach(matches) { profile in
                        HStack(spacing: 12) {
                            ProfileGlyph(profile: profile).font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.headline)
                                Text(profile.observedAccount ?? profile.authMode.rawValue).font(.caption).foregroundStyle(.secondary)
                                if let title = matchingTask(profile) { Text(title).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text("Open profile").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(profile.id).contentShape(Rectangle()).onTapGesture(count: 2) { selected = profile.id; activate() }
                    }
                }.listStyle(.plain).frame(height: 300)
            }
            HStack { Text("↑ ↓ Navigate"); Spacer(); Text("↵ Open profile"); Text("esc Close") }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width: 600)
        .onAppear(perform: resetForPresentation)
        .onReceive(NotificationCenter.default.publisher(for: .deckSwitcherPresented)) { _ in resetForPresentation() }
        .onDisappear { focusTask?.cancel(); focused = false }
        .onChange(of: query) { selected = matches.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { activate(); return .handled }
        .onExitCommand(perform: dismissSwitcher)
    }
    private func resetForPresentation() {
        focusTask?.cancel()
        focused = false
        query = ""
        snapshot = DeckLogic.sorted(model.deck.profiles, query: "", order: model.order, showHidden: false, tasks: model.deck.tasks, usage: model.deck.usage)
        selected = snapshot.first?.id
        // The panel is key before this notification. Reassert SwiftUI focus on its next update.
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
    }
    private func dismissSwitcher() {
        focusTask?.cancel(); focused = false; onDismiss()
    }
    private func matchingTask(_ profile: Profile) -> String? { guard !query.isEmpty else { return nil }; return model.deck.tasks.first { $0.profileID == profile.id && $0.title.localizedCaseInsensitiveContains(query) }?.title }
    private func move(_ offset: Int) { guard !matches.isEmpty else { return }; let index = matches.firstIndex { $0.id == selected } ?? 0; selected = matches[max(0, min(matches.count - 1, index + offset))].id }
    private func activate() { if let profile = matches.first(where: { $0.id == selected }) ?? matches.first { model.open(profile); dismissSwitcher() } }
}

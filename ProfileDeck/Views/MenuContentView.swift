import SwiftUI
import AppKit

struct MenuContentView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var profileOrder: [UUID] = []
    @State private var search = ""
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool
    @State private var menuWindow = MenuWindowContext()
    @State private var screenHeight: CGFloat = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame.height ?? 700
    @State private var headerHeight: CGFloat = 58
    @State private var footerHeight: CGFloat = 32
    private var profiles: [Profile] {
        let current = Dictionary(uniqueKeysWithValues: model.deck.profiles.map { ($0.id, $0) })
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return profileOrder.compactMap { current[$0] }.filter {
            !$0.hidden && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.observedAccount?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }
    private func windows(_ profile: Profile) -> [UsageWindow] {
        profile.menuWindows(from: model.deck.usage.first { $0.profileID == profile.id })
    }
    private func rowHeight(_ profile: Profile) -> CGFloat {
        let snapshot = model.deck.usage.first { $0.profileID == profile.id }
        return MenuProfileCardLayout.minimumHeight(meterRows: meterRows(profile),
            hasResetCredit: profile.hasMenuUsagePreview(for: snapshot) && resetCreditStatus(profile, now: Date()) != nil)
    }
    private func meterRows(_ profile: Profile) -> Int {
        let snapshot = model.deck.usage.first { $0.profileID == profile.id }
        return MenuProfileCardLayout.meterRows(
            showsUsage: profile.hasMenuUsagePreview(for: snapshot),
            hasAPISpend: snapshot?.apiSpend != nil,
            windowCount: windows(profile).count
        )
    }
    private func resetCreditStatus(_ profile: Profile, now: Date) -> String? {
        ResetCreditStatus.label(profile: profile, usage: model.deck.usage, now: now)
    }
    private var naturalHeight: CGFloat {
        profiles.reduce(CGFloat.zero) { $0 + rowHeight($1) } + CGFloat(max(0, profiles.count - 1)) * MenuPopoverLayout.rowSpacing
    }
    private var listHeight: CGFloat {
        MenuPopoverLayout.listHeight(naturalHeight: naturalHeight, screenHeight: screenHeight,
            chromeHeight: headerHeight + footerHeight + 2 * MenuPopoverLayout.outerPadding + 3 * MenuPopoverLayout.sectionSpacing + 1)
    }
    var body: some View {
        VStack(spacing: MenuPopoverLayout.sectionSpacing) {
            header.onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { headerHeight = $0 }
            ScrollViewReader { scroll in
                Group {
                    if profiles.isEmpty {
                        Text(profileOrder.isEmpty ? "Add profiles in the manager to get started." : "No matching profiles")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 64)
                    } else if naturalHeight > listHeight {
                        ScrollView { rows }.frame(height: listHeight)
                            .accessibilityLabel("Profiles, scroll for more")
                    } else {
                        rows // No scroll container at all when every profile fits.
                    }
                }
                .onChange(of: selectedID) { if let selectedID { scroll.scrollTo(selectedID) } }
            }
            Divider()
            footer.onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { footerHeight = $0 }
        }
        .padding(MenuPopoverLayout.outerPadding).frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(MenuScreenReader(context: menuWindow, onScreenHeight: { screenHeight = $0 }, onPresent: prepareForPresentation))
        .onAppear(perform: prepareForPresentation)
        .onChange(of: search) { selectedID = profiles.first?.id }
        .onChange(of: profiles.map(\.id)) { if !profiles.contains(where: { $0.id == selectedID }) { selectedID = profiles.first?.id } }
        .onExitCommand { menuWindow.dismiss() }
    }
    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Profile Deck").font(.headline)
                Spacer()
                Text("\(profiles.count) \(profiles.count == 1 ? "profile" : "profiles")").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Find a profile", text: $search).textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(activateSelection)
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        }
    }
    private var rows: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: MenuPopoverLayout.rowSpacing) {
                ForEach(profiles) { profile in
                    let usage = usageText(profile, now: context.date)
                    let snapshot = model.deck.usage.first { $0.profileID == profile.id }
                    MenuProfileRow(profile: profile, status: usage.summary, detail: usage.detail,
                                   showsUsage: profile.hasMenuUsagePreview(for: snapshot),
                                   spend: snapshot?.apiSpend, apiFresh: snapshot?.error == nil, meters: windows(profile), fresh: snapshot?.isFresh(at: context.date) ?? false,
                                   resetCreditStatus: resetCreditStatus(profile, now: context.date),
                                   isOpen: model.runtime[profile.id]?.state == .open,
                                   selected: selectedID == profile.id, height: rowHeight(profile)) { activate(profile) }
                        .id(profile.id)
                        .contextMenu { UsagePreviewControls(model: model, profileID: profile.id) }
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: showManager) {
                Label("Open manager", systemImage: "macwindow").frame(maxWidth: .infinity)
            }.controlSize(.large)
            Button {
                menuWindow.dismiss()
                NotificationCenter.default.post(name: .deckToggleTabs, object: nil)
            } label: {
                Label(model.deck.settings.showFloatingTabs ? "Hide tabs" : "Show tabs", systemImage: "rectangle.split.3x1")
            }
            .controlSize(.large)
            .help(model.deck.settings.showFloatingTabs ? "Hide floating account tabs" : "Show floating account tabs")
            .accessibilityLabel(model.deck.settings.showFloatingTabs ? "Hide floating account tabs" : "Show floating account tabs")
        }
    }
    private func prepareForPresentation() {
        profileOrder = DeckLogic.manuallyOrdered(model.deck.profiles).filter { !$0.hidden }.map(\.id)
        search = ""; selectedID = nil
        Task { @MainActor in await Task.yield(); searchFocused = true }
        Task { await model.refresh() }
    }
    private func moveSelection(_ direction: Int) {
        guard !profiles.isEmpty else { return }
        let index = selectedID.flatMap { id in profiles.firstIndex { $0.id == id } }
        let next = index.map { max(0, min(profiles.count - 1, $0 + direction)) } ?? (direction > 0 ? 0 : profiles.count - 1)
        selectedID = profiles[next].id
    }
    private func activateSelection() { if let profile = profiles.first(where: { $0.id == selectedID }) ?? profiles.first { activate(profile) } }
    private func activate(_ profile: Profile) {
        menuWindow.dismiss()
        model.open(profile, onFailure: showManager)
    }
    private func showManager() { menuWindow.dismiss(); openWindow(id: "manager"); showProfileDeckManager() }
    private func usageText(_ profile: Profile, now: Date) -> (summary: String, detail: String) {
        let snapshot = model.deck.usage.first { $0.profileID == profile.id }
        let unread = model.deck.tasks.contains { $0.profileID == profile.id && $0.unread } ? "Unread update · " : ""
        guard profile.hasMenuUsagePreview(for: snapshot) else { return ("", "") }
        if let spend = snapshot?.apiSpend {
            let today = spend.currentDayAvailable ? amount(spend.todayUSD, currency: spend.currency) : "Pending"
            let month = amount(spend.monthUSD, currency: spend.currency)
            let partial = snapshot?.error != nil || spend.warning != nil ? "Partial · " : ""
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let dayLabel = utc.isDate(spend.fetchedAt, inSameDayAs: now) ? "today" : utcDate(spend.fetchedAt, format: "MMM d")
            let monthLabel = utc.isDate(spend.fetchedAt, equalTo: now, toGranularity: .month) ? "month" : utcDate(spend.fetchedAt, format: "MMM yyyy")
            return ("\(today) \(dayLabel) · \(month) \(monthLabel)",
                    unread + partial + "Org spend · UTC · " + age(spend.fetchedAt, now: now))
        }
        if (snapshot?.observedAuthMode ?? profile.verifiedAuthMode ?? profile.authMode) == .apiKey {
            if profile.billingSourceID != nil {
                return ("API spending unavailable", unread + (snapshot?.error ?? "Check the linked source in the manager"))
            }
            return ("API spending not linked", unread + "Choose a spending source in the manager")
        }
        if let snapshot, let window = snapshot.windows.first,
           window.usedPercent.isFinite, (0...100).contains(window.usedPercent) {
            let freshness = snapshot.error != nil ? "Partial · " : (snapshot.isFresh(at: now) ? "" : "Cached · ")
            return ("Usage consumed", unread + freshness + age(snapshot.observedAt, now: now))
        }
        return ("Usage unavailable", unread + (snapshot?.error ?? "Refresh to check this account"))
    }
    private func amount(_ value: Double?, currency: String) -> String {
        guard let value, value.isFinite else { return "Pending" }
        return value.formatted(.currency(code: currency))
    }
    private func utcDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "Check time unavailable" }
        if seconds < 60 { return "just checked" }
        if seconds < 3600 { return "checked \(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "checked \(Int(seconds / 3600))h ago" }
        return "checked \(Int(seconds / 86_400))d ago"
    }
}

enum MenuProfileCardLayout {
    static let titleHeight: CGFloat = 17
    static let meterHeight: CGFloat = 30
    static let detailHeight: CGFloat = 14
    static let resetCreditHeight: CGFloat = 25
    static let verticalPadding: CGFloat = 20
    static let contentSpacing: CGFloat = 5
    static let noUsageHeight: CGFloat = 48

    static func meterRows(showsUsage: Bool, hasAPISpend: Bool, windowCount: Int) -> Int {
        guard showsUsage else { return 0 }
        return hasAPISpend ? 1 : max(1, windowCount)
    }

    static func minimumHeight(meterRows: Int, hasResetCredit: Bool = false) -> CGFloat {
        guard meterRows > 0 else { return noUsageHeight }
        return verticalPadding + titleHeight + contentSpacing
            + CGFloat(meterRows) * meterHeight + contentSpacing + detailHeight
            + (hasResetCredit ? resetCreditHeight : 0)
    }
}

private struct MenuProfileRow: View {
    var profile: Profile
    var status: String
    var detail: String
    var showsUsage: Bool
    var spend: APISpendSnapshot?
    var apiFresh: Bool
    var meters: [UsageWindow]
    var fresh: Bool
    var resetCreditStatus: String?
    var isOpen: Bool
    var selected: Bool
    var height: CGFloat
    var activate: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: activate) {
            HStack(alignment: .top, spacing: 10) {
                ProfileGlyph(profile: profile).font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(short(profile.name)).font(.body.weight(.semibold)).lineLimit(1)
                        if profile.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true) }
                        Spacer(minLength: 4)
                        Text(isOpen ? "Focus" : "Open").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    if showsUsage {
                        VStack(alignment: .leading, spacing: 0) {
                            if let spend {
                                APIUsageMeter(spend: spend, isFresh: apiFresh && spend.warning == nil && Date().timeIntervalSince(spend.fetchedAt) < 900)
                                    .frame(minHeight: MenuProfileCardLayout.meterHeight, alignment: .top)
                            } else if meters.isEmpty {
                                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    .frame(minHeight: MenuProfileCardLayout.meterHeight, alignment: .top)
                            } else {
                                ForEach(meters) { meter in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 4) {
                                            Text(meterTitle(meter)).lineLimit(1)
                                            Spacer(minLength: 4)
                                            if let reset = meter.resetsAt {
                                                Text(reset > Date() ? "Resets " + reset.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) : "Reset pending")
                                                    .lineLimit(1).fixedSize()
                                            }
                                        }.font(.caption2).foregroundStyle(.secondary)
                                        AllowanceMeter(window: meter, isFresh: fresh)
                                    }
                                    .frame(minHeight: MenuProfileCardLayout.meterHeight, alignment: .top)
                                }
                            }
                        }
                        Text(spend == nil ? detail : status + " · " + detail)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if let resetCreditStatus {
                            HStack(spacing: 5) {
                                Image(systemName: "ticket.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                                Text(resetCreditStatus)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.22), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                            .help("Earned account reset credits are separate from the timed usage-window reset above. Profile Deck never redeems them automatically.")
                        }
                    }
                }
            }
            .padding(10)
            .frame(minHeight: height, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(hovering || selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel("\(isOpen ? "Focus" : "Open") \(profile.name)")
        .accessibilityValue(accessibilitySummary)
        .help("\(profile.name) · \(profile.observedAccount ?? profile.authMode.rawValue)\n\(status)\n\(detail)")
    }
    private var accessibilitySummary: String {
        var values = [status]
        if let spend {
            if let percent = spend.budgetUsedPercent {
                values.append("\(spend.budgetLabel): \(Int(percent.rounded())) percent used")
            } else { values.append(spend.budgetUnavailableReason) }
        }
        values += meters.map { "\(meterTitle($0)): \(Int($0.usedPercent.rounded())) percent used" }
        if let resetCreditStatus { values.append(resetCreditStatus) }
        return (values + [detail]).joined(separator: ". ")
    }
    private func meterTitle(_ window: UsageWindow) -> String {
        let name = window.bucketName ?? (window.id.hasPrefix("codex:") ? "Codex" : "")
        return name.isEmpty ? window.label : window.label + " · " + name
    }
    private func short(_ value: String) -> String { value.count > 30 ? String(value.prefix(27)) + "…" : value }
}

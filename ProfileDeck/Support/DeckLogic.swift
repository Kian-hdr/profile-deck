import Foundation

nonisolated enum DeckLogic {
    static func sorted(_ profiles: [Profile], query: String, order: ProfileOrder, showHidden: Bool, tasks: [TaskObservation], usage: [UsageSnapshot], now: Date = Date()) -> [Profile] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.filter { profile in (showHidden || !profile.hidden) && (text.isEmpty || (profile.name + " " + (profile.observedAccount ?? "") + " " + profile.authMode.rawValue).localizedStandardContains(text) || tasks.contains(where: { $0.profileID == profile.id && $0.title.localizedStandardContains(text) })) }.sorted { a,b in
            // Manual order is the one shared ordering across the manager, menu
            // and floating tabs. Favourites remain metadata, not a hidden second
            // ordering rule, while this explicit sort is selected.
            if order == .manual {
                if a.manualOrder != b.manualOrder { return a.manualOrder < b.manualOrder }
                return a.id.uuidString < b.id.uuidString
            }
            if a.favorite != b.favorite { return a.favorite }
            if !a.favorite {
                if order == .recent, a.lastFocused != b.lastFocused { return (a.lastFocused ?? .distantPast) > (b.lastFocused ?? .distantPast) }
                if order == .attention {
                    func priority(_ p:Profile) -> Int { if tasks.contains(where: { $0.profileID == p.id && ($0.state == .input || $0.unread) }) { return 0 }; if tasks.contains(where: { $0.profileID == p.id && $0.state == .running }) { return 1 }; return 2 }
                    if priority(a) != priority(b) { return priority(a) < priority(b) }
                }
                if order == .allowance, a.authMode == b.authMode {
                    let ua = usage.first { $0.profileID == a.id && $0.isFresh(at: now) }
                    let ub = usage.first { $0.profileID == b.id && $0.isFresh(at: now) }
                    if (ua != nil) != (ub != nil) { return ua != nil }
                    // Only equal authenticated accounts/bucket shapes are numerically comparable.
                    if let ua, let ub, ua.accountID == ub.accountID, ua.accountID != nil,
                       ua.windows.map(\.id).sorted() == ub.windows.map(\.id).sorted() {
                        let av = ua.windows.map(\.remaining).min() ?? 0; let bv = ub.windows.map(\.remaining).min() ?? 0
                        if av != bv { return av > bv }
                    }
                }
            }
            if a.manualOrder != b.manualOrder { return a.manualOrder < b.manualOrder }
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func manuallyOrdered(_ profiles: [Profile]) -> [Profile] {
        profiles.sorted {
            if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Reorders only the supplied visible slots. Profiles excluded by a filter
    /// remain at their original global positions, preventing a filtered drag
    /// from silently moving hidden or unrelated accounts.
    static func manualReordering(_ profiles: [Profile], moving movingID: UUID, before beforeID: UUID?, visibleIDs: [UUID]) -> [Profile]? {
        let ordered = manuallyOrdered(profiles)
        let existing = Set(ordered.map(\.id))
        let visible = visibleIDs.filter { existing.contains($0) }
        guard visible.contains(movingID), Set(visible).count == visible.count else { return nil }
        var reordered = visible
        guard let source = reordered.firstIndex(of: movingID) else { return nil }
        reordered.remove(at: source)
        let destination = beforeID.flatMap { reordered.firstIndex(of: $0) } ?? reordered.endIndex
        reordered.insert(movingID, at: destination)

        let visibleSet = Set(visible)
        let slots = ordered.indices.filter { visibleSet.contains(ordered[$0].id) }
        guard slots.count == reordered.count else { return nil }
        var replacement = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        for (slot, id) in zip(slots, reordered) {
            var profile = replacement[id]!
            profile.manualOrder = slot
            replacement[id] = profile
        }
        return profiles.compactMap { replacement[$0.id] }
    }
    static func resetDescription(_ window: UsageWindow, now: Date = Date()) -> String {
        guard let reset = window.resetsAt else { return "Reset unavailable" }
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "Reset awaiting confirmation" }
        let minutes = Int(ceil(seconds / 60)); return minutes >= 60 ? "Resets in \(minutes / 60)h \(minutes % 60)m" : "Resets in \(minutes)m"
    }
    static func notificationKeys(snapshot: UsageSnapshot, settings: DeckSettings, now: Date = Date()) -> [(String, Int)] {
        guard snapshot.isFresh(at: now), let account = snapshot.accountID else { return [] }
        return snapshot.windows.flatMap { window -> [(String, Int)] in
            guard let reset = window.resetsAt, reset > now else { return [] }
            return [settings.warningThreshold, settings.criticalThreshold, 100].filter { window.usedPercent >= Double($0) }.map { ("usage|\(account)|\(window.id)|\(Int(reset.timeIntervalSince1970))|\($0)", $0) }
        }
    }
    static func validateProfile(_ profile: Profile, against profiles:[Profile]) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, profile.name.count <= 100 else { throw DeckError.message("Enter a profile name of 1 to 100 characters.") }
        guard profile.homePath.hasPrefix("/"), profile.dataPath.hasPrefix("/"), profile.canonicalHome != profile.canonicalData else { throw DeckError.message("Choose different absolute folders for profile configuration and application data.") }
        let roots = [profile.canonicalHome, profile.canonicalData]
        guard !roots.contains("/"), !roots.contains(FileManager.default.homeDirectoryForCurrentUser.path) else { throw DeckError.message("Choose dedicated profile folders, not your home folder or disk root.") }
        func overlaps(_ a:String,_ b:String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
        guard !overlaps(roots[0], roots[1]) else { throw DeckError.message("Profile folders must not contain one another.") }
        for other in profiles where other.id != profile.id {
            if roots.contains(where: { overlaps($0,other.canonicalHome) || overlaps($0,other.canonicalData) }) { throw DeckError.message("That folder overlaps an existing profile. Choose isolated folders.") }
        }
    }
}

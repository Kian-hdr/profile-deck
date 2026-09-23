import SwiftUI

/// Presentation preferences only. Never changes provider limits or monitoring.
struct UsagePreviewControls: View {
    var model: AppModel
    var profileID: UUID
    var body: some View {
        if let profile = model.deck.profiles.first(where: { $0.id == profileID }) {
            let windows = model.deck.usage.first { $0.profileID == profileID }?.displayWindows ?? []
            Toggle("Show usage preview", isOn: Binding(get: { profile.showsMenuUsage }, set: { enabled in
                update { $0.showMenuUsage = enabled }
            }))
            ForEach(windows) { window in
                Toggle(title(window), isOn: Binding(get: {
                    !(profile.hiddenMenuUsageWindowIDs ?? []).contains(window.id)
                }, set: { visible in
                    update {
                        var hidden = $0.hiddenMenuUsageWindowIDs ?? []
                        if visible { hidden.remove(window.id) } else { hidden.insert(window.id) }
                        $0.hiddenMenuUsageWindowIDs = hidden
                    }
                })).disabled(!profile.showsMenuUsage)
            }
            if !(profile.hiddenMenuUsageWindowIDs ?? []).isEmpty {
                Button("Show all limits") { update { $0.hiddenMenuUsageWindowIDs = []; $0.showMenuUsage = true } }
            }
        }
    }
    private func title(_ window: UsageWindow) -> String {
        let bucket = window.bucketName ?? (window.id.hasPrefix("codex:") ? "Codex" : "Account")
        return bucket + " · " + window.label
    }
    private func update(_ change: (inout Profile) -> Void) {
        guard var current = model.deck.profiles.first(where: { $0.id == profileID }) else { return }
        change(&current)
        model.update(current)
    }
}

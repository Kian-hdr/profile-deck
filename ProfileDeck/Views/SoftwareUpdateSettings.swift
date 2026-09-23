import SwiftUI

struct SoftwareUpdateSettings: View {
    private var updates: SoftwareUpdateStore { .shared }
    var body: some View {
        Section("Software updates") {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates || !updates.isConfigured)
            Toggle("Automatically check for updates", isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .disabled(!updates.isConfigured)
            Toggle("Automatically download updates", isOn: Binding(get: { updates.automaticDownloads }, set: { updates.setAutomaticDownloads($0) }))
                .disabled(!updates.isConfigured || !updates.automaticChecks)
            Text(updates.isConfigured
                 ? "Signed updates download automatically and can install when you quit. Restarting waits for Profile Deck's open editors and saves; your native account apps keep running."
                 : "In-app updates are unavailable in this release. Download future verified releases from GitHub or upgrade with Homebrew.")
                .font(.caption).foregroundStyle(.secondary)
            if let date = updates.lastCheck { LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened)) }
            if let status = updates.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

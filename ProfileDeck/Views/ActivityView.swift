import SwiftUI

struct ActivityView: View {
    var model: AppModel
    @State private var filter: TaskState?
    @State private var profileID: UUID?
    @State private var search = ""
    private var tasks: [TaskObservation] {
        model.deck.tasks.filter { (filter == nil || $0.state == filter) && (profileID == nil || $0.profileID == profileID) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }.sorted { $0.observedAt > $1.observedAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "Activity", subtitle: "Task observations stay separate from application process state.")
            TextField("Search task titles", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Profile", selection: $profileID) { Text("All profiles").tag(Optional<UUID>.none); ForEach(model.deck.profiles) { Text($0.name).tag(Optional($0.id)) } }
                Picker("Status", selection: $filter) { Text("All states").tag(Optional<TaskState>.none); ForEach(TaskState.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) } }
            }
            if tasks.isEmpty {
                EmptyNotice(title: "Native task status unavailable", symbol: "waveform.path", detail: "No matching verified task observations are available. Your profiles can still run independently. An open app does not prove a task is running or finished.")
            } else {
                List(tasks) { task in
                    HStack(alignment: .top) {
                        Image(systemName: task.unread ? "circle.fill" : "circle").font(.caption).accessibilityLabel(task.unread ? "Unread" : "Read")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title).fontWeight(.medium)
                            Text("\(model.deck.profiles.first { $0.id == task.profileID }?.name ?? "Missing profile") · \(task.state.rawValue)").foregroundStyle(.secondary)
                            Text(task.observedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if task.unread { Button("Mark read") { model.markRead(task) } }
                        if let profile = model.deck.profiles.first(where: { $0.id == task.profileID }) { Button("Open profile") { model.open(profile) } }
                    }.padding(.vertical, 6)
                        .listRowBackground(model.deck.settings.usesHighContrastDark ? Color.black : nil)
                }.scrollContentBackground(model.deck.settings.usesHighContrastDark ? .hidden : .automatic)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct UsageDetailView: View {
    var snapshot: UsageSnapshot?
    var authMode: AuthMode
    var body: some View {
        if let snapshot, let spend = snapshot.apiSpend {
            apiSpending(spend, snapshot: snapshot)
        } else if let snapshot, !snapshot.windows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(snapshot.error != nil ? "Partial reading · refresh needed" : (snapshot.isFresh() ? "Provider-reported" : "Cached · refresh needed"))
                    .font(.caption).foregroundStyle(.secondary)
                if let plan = snapshot.planName { Text("ChatGPT \(PlanDisplayName.format(plan))").font(.callout.weight(.medium)) }
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bucketTitle(window)).font(.caption).foregroundStyle(.secondary)
                        if window.usedPercent.isFinite, (0...100).contains(window.usedPercent) {
                            HStack { Text(window.label); Spacer(); Text("Used").font(.caption).foregroundStyle(.secondary) }
                            AllowanceMeter(window: window, isFresh: snapshot.isFresh())
                        } else {
                            Text("This usage window is unavailable.").font(.callout)
                        }
                        if let reset = window.resetsAt {
                            if reset > Date() { Text("Resets \(reset, style: .relative)").font(.caption) }
                            else { Text("Reset awaiting provider confirmation").font(.caption) }
                            Text(reset.formatted(.dateTime.month().day().hour().minute().timeZone())).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("\(snapshot.source) · checked \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if let error = snapshot.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text((snapshot?.observedAuthMode ?? authMode) == .apiKey ? "API organization costs are unavailable." : "Usage is unavailable for this account.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = snapshot?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func bucketTitle(_ window: UsageWindow) -> String {
        if let name = window.bucketName, !name.isEmpty { return name }
        let identifier = window.id.split(separator: ":").dropLast().joined(separator: ":")
        if identifier == "codex" { return "Codex" }
        if identifier == "legacy" || identifier.isEmpty { return "Account usage" }
        return identifier
    }

    private func apiSpending(_ spend: APISpendSnapshot, snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spend.sourceName).font(.callout.weight(.medium))
            Text("Organization-wide API spending").font(.caption).foregroundStyle(.secondary)
            Text("Includes all API activity in the selected organization, across profiles and projects.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(utcDate(spend.fetchedAt, format: "MMM d, yyyy")) · UTC")
                Spacer()
                Text(spend.currentDayAvailable ? amount(spend.todayUSD, currency: spend.currency) : "Not available yet")
                    .monospacedDigit()
            }
            HStack {
                Text("\(utcDate(spend.fetchedAt, format: "MMMM yyyy")) · UTC")
                Spacer()
                Text(amount(spend.monthUSD, currency: spend.currency)).monospacedDigit()
            }
            APIUsageMeter(spend: spend, isFresh: snapshot.error == nil && spend.warning == nil && Date().timeIntervalSince(spend.fetchedAt) < 900)
            Text("This is spending, not remaining credit. Refresh Prompt Balance to fetch newer costs.").font(.caption).foregroundStyle(.secondary)
            Text("Costs may arrive later than the activity that generated them.").font(.caption).foregroundStyle(.secondary)
            if let through = spend.costsThrough {
                Text("Costs through \(utcDate(through, format: "MMM d, yyyy HH:mm")) UTC")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(snapshot.source) · checked \(spend.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if Date().timeIntervalSince(spend.fetchedAt) >= 180 {
                Text("Cached spending · refresh to check for newer costs").font(.caption).foregroundStyle(.secondary)
            }
            if let warning = spend.warning { Text(warning).font(.caption).foregroundStyle(.secondary) }
            if let error = snapshot.error, error != spend.warning { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func amount(_ value: Double?, currency: String) -> String {
        guard let value, value.isFinite else { return "Not available yet" }
        return value.formatted(.currency(code: currency))
    }

    private func utcDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

import Foundation

enum AuthMode: String, Codable, CaseIterable, Sendable { case subscription = "ChatGPT", apiKey = "API key" }
enum ProcessState: String, Codable, Sendable { case closed = "Closed", launching = "Opening", open = "Open", unknown = "Unknown", unresponsive = "Not responding" }
enum HealthState: String, Codable, CaseIterable, Sendable { case shared = "Shared", pending = "Refresh needed", signIn = "Sign-in needed", unavailable = "Unavailable", conflict = "Conflict", error = "Error", unchecked = "Not checked" }
enum TaskState: String, Codable, CaseIterable, Sendable { case running = "Running", input = "Needs input", completed = "Completed", failed = "Failed", interrupted = "Interrupted", unavailable = "Unavailable" }
enum IntegrationKind: String, Codable, CaseIterable, Sendable { case plugin = "Plugins", mcp = "MCP servers", connector = "Connectors" }
enum ProfileOrder: String, Codable, CaseIterable, Sendable { case manual = "Manual order", attention = "Attention first", recent = "Recently active", allowance = "Available allowance" }
enum AppSection: String, CaseIterable, Codable, Sendable {
    case profiles = "Profiles", activity = "Activity", world = "Shared World", integrations = "Integrations", handoffs = "Handoffs", diagnostics = "Diagnostics", settings = "Settings"
    var symbol: String { switch self { case .profiles: "person.crop.rectangle.stack"; case .activity: "waveform.path"; case .world: "globe"; case .integrations: "puzzlepiece.extension"; case .handoffs: "arrow.right.arrow.left"; case .diagnostics: "stethoscope"; case .settings: "gearshape" } }
}
struct Profile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var color = "blue"
    var authMode: AuthMode = .subscription
    var homePath: String
    var dataPath: String
    var appPath = "/Applications/ChatGPT.app"
    var favorite = false
    var hidden = false
    var tabVisible = true
    var manualOrder = 0
    var lastFocused: Date?
    var observedAccount: String?
    var verifiedAuthMode: AuthMode?
    var identityCheckedAt: Date?
    var billingSourceID: String?
    var showMenuUsage: Bool?
    var hiddenMenuUsageWindowIDs: Set<String>?
    var hasLinkedAPIBilling: Bool { (verifiedAuthMode ?? authMode) == .apiKey && billingSourceID != nil }
    var showsMenuUsage: Bool { showMenuUsage ?? true }
    func menuWindows(from snapshot: UsageSnapshot?) -> [UsageWindow] {
        guard showsMenuUsage else { return [] }
        return (snapshot?.displayWindows ?? []).filter { !(hiddenMenuUsageWindowIDs ?? []).contains($0.id) }
    }
    func hasMenuUsagePreview(for snapshot: UsageSnapshot?) -> Bool {
        showsMenuUsage && ((snapshot?.displayWindows.isEmpty ?? true) || !menuWindows(from: snapshot).isEmpty)
    }
    var createdByDeck = false
    var startAtLogin = false
    var muted = false
    var snoozedUntil: Date?
    var createdAt = Date()
    var canonicalHome: String { URL(fileURLWithPath: homePath).standardizedFileURL.resolvingSymlinksInPath().path }
    var canonicalData: String { URL(fileURLWithPath: dataPath).standardizedFileURL.resolvingSymlinksInPath().path }
}
struct Capability: Identifiable, Codable, Sendable {
    var id: String
    var available: Bool
    var detail: String
    var checkedAt = Date()
}
struct NativeWindow: Identifiable, Codable, Sendable { var id: Int; var title: String }
struct RuntimeSnapshot: Codable, Sendable {
    var profileID: UUID
    var state: ProcessState = .unknown
    var pid: Int32?
    var processStart: String?
    var appVersion: String?
    var windows: [NativeWindow] = []
    var capabilities: [Capability] = []
    var checkedAt = Date()
    var detail = "Not checked"
}
struct SharedWorld: Codable, Sendable {
    var version = 1
    var sourceHome: String
    var workspacePaths: [String] = []
    var memoryOwnerID: UUID?
    var revision = UUID().uuidString
    var managedMCPNames: [String] = []
    var managedPreferenceKeys: [String] = ["model", "model_reasoning_effort", "model_verbosity", "personality", "instructions", "developer_instructions"]
    var updatedAt = Date()
    static var initial: SharedWorld { SharedWorld(sourceHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path) }
}
struct SharedResource: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var sourcePath: String
    var targetPath: String
    var state: HealthState
    var detail: String
    var revision: String?
}
struct SharedInspection: Codable, Sendable {
    var profileID: UUID
    var resources: [SharedResource]
    var checkedAt = Date()
    var summary: HealthState { resources.contains(where: { $0.state == .conflict || $0.state == .error }) ? .conflict : resources.contains(where: { $0.state != .shared }) ? .pending : .shared }
}
struct IntegrationStatus: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var kind: IntegrationKind
    var source = ""
    var version: String?
    var desiredEnabled = true
    var profileID: UUID?
    var installed: HealthState = .unchecked
    var discovery: HealthState = .unchecked
    var authorization: HealthState = .unchecked
    var compatibility: HealthState = .unchecked
    var functional: HealthState = .unchecked
    var refresh: HealthState = .unchecked
    var detail = ""
    var checkedAt = Date()
}
struct UsageWindow: Identifiable, Codable, Sendable {
    var id: String
    var usedPercent: Double
    var durationMinutes: Int?
    var resetsAt: Date?
    var bucketName: String?
    var label: String { switch durationMinutes { case 300: "5-hour"; case 10080: "Weekly"; case .some(let n): "\(n)-minute"; case nil: "Usage window" } }
    var usedFraction: Double { usedPercent.isFinite ? min(1, max(0, usedPercent / 100)) : 0 }
    var remaining: Double { max(0, 100 - usedPercent) }
}
struct BillingSource: Identifiable, Sendable { var id: String; var name: String }
struct APISpendSnapshot: Codable, Sendable {
    var sourceID: String
    var sourceName: String
    var todayUSD: Double?
    var monthUSD: Double?
    var fetchedAt: Date
    var costsThrough: Date?
    var currentDayAvailable: Bool
    var warning: String?
    var currency = "USD"
    var budgetAmountUSD: Double? = nil
    var budgetUsedUSD: Double? = nil
    var budgetKind: String? = nil
    var budgetAsOf: Date? = nil
    var budgetUnavailableDetail: String? = nil
    var budgetUnavailableReason: String { budgetUnavailableDetail ?? "Set a budget or starting credit in Prompt Balance." }
    var budgetLabel: String {
        if budgetKind == "creditBalance", let asOf = budgetAsOf {
            return "Credit used · as of \(asOf.formatted(date: .abbreviated, time: .shortened))"
        }
        return budgetKind == "creditBalance" ? "Starting credit" : "Monthly budget"
    }
    var budgetUsedPercent: Double? {
        guard let amount = budgetAmountUSD, let used = budgetUsedUSD,
              amount.isFinite, amount > 0, used.isFinite else { return nil }
        return min(100, max(0, used / amount * 100))
    }
}
struct UsageSnapshot: Codable, Sendable {
    var profileID: UUID
    var accountID: String?
    var windows: [UsageWindow] = []
    var observedAt = Date()
    var source = "Native provider"
    var error: String?
    var observedAuthMode: AuthMode?
    var accountLabel: String?
    var planName: String?
    // A separate, account-scoped entitlement. Nil means the service did not verify it.
    var resetCreditsAvailable: Int?
    var apiSpend: APISpendSnapshot?
    var displayWindows: [UsageWindow] {
        guard observedAuthMode != .apiKey, apiSpend == nil else { return [] }
        return windows.filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
    }
    func isFresh(at now: Date = Date()) -> Bool {
        let age=now.timeIntervalSince(observedAt)
        return observedAuthMode != .apiKey && apiSpend == nil && error == nil && age >= 0 && age < 180 && !windows.isEmpty && windows.allSatisfy {
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && ($0.durationMinutes.map { $0 > 0 } ?? true)
        }
    }
}
struct TaskObservation: Identifiable, Codable, Sendable {
    var id: String
    var profileID: UUID
    var turnID: String
    var title: String
    var state: TaskState
    var unread = false
    var observedAt = Date()
}
enum TransactionState: String, Codable, Sendable { case pending = "Pending", applied = "Applied", failed = "Failed", conflict = "Conflict", restored = "Restored" }
struct ConfigurationTransaction: Identifiable, Codable, Sendable {
    var id = UUID()
    var profileID: UUID
    var title: String
    var detail: String
    var state: TransactionState = .pending
    var createdAt = Date()
    var recoveryPath: String?
    var safeToLaunch: Bool? = nil
}
enum HandoffState: String, Codable, CaseIterable, Sendable { case draft = "Draft", ready = "Ready", submitted = "Submitted", unconfirmed = "Delivery unconfirmed", acknowledged = "Acknowledged" }
enum HandoffContextLinkKind: String, Codable, CaseIterable, Sendable {
    case none
    case sharedConversation
    case privateThread
    case unsupported

    static func classify(_ value: String?) -> Self {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .none }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else { return .unsupported }
        let host = components.host?.lowercased()
        let path = components.path.lowercased()
        if scheme == "https", host == "chatgpt.com", path.hasPrefix("/share/") { return .sharedConversation }
        if scheme == "codex" || scheme == "chatgpt" || (scheme == "https" && host == "chatgpt.com" && path.hasPrefix("/c/")) { return .privateThread }
        return .unsupported
    }

    var isTransferable: Bool { self == .none || self == .sharedConversation }

    var editorDetail: String {
        switch self {
        case .none:
            "Optional. Add a reviewed ChatGPT shared-conversation link when chat-only context must accompany this brief."
        case .sharedConversation:
            "This shared conversation snapshot will be included in the copied continuation brief. The destination still starts its own private conversation."
        case .privateThread:
            "Private thread deep links are scoped to the source profile and cannot be transferred. Create a ChatGPT shared-conversation link in the source profile instead."
        case .unsupported:
            "Use a ChatGPT shared-conversation link beginning with https://chatgpt.com/share/, or leave this blank and capture the necessary context in the brief."
        }
    }
}
struct Handoff: Identifiable, Codable, Sendable {
    var id = UUID()
    var title = "New handoff"
    var sourceProfileID: UUID?
    var destinationProfileID: UUID?
    var workspacePath = ""
    var objective = ""
    var progress = ""
    var filesAndChecks = ""
    var nextSteps = ""
    var pendingApprovals = ""
    var backgroundJobs = ""
    /// A user-approved snapshot URL only. Profile Deck never fetches or reads it.
    var sourceContextLink: String? = nil
    var ownershipReleased = false
    var state: HandoffState = .draft
    var updatedAt = Date()
    var sourceContextKind: HandoffContextLinkKind { HandoffContextLinkKind.classify(sourceContextLink) }
    var canTransferSourceContext: Bool { sourceContextKind.isTransferable }
    var rendered: String {
        let context: String
        switch sourceContextKind {
        case .none:
            context = "No shared conversation was attached. Treat this reviewed brief as the complete transferred context."
        case .sharedConversation:
            context = "Read this user-approved shared conversation snapshot before continuing:\n\(sourceContextLink!.trimmingCharacters(in: .whitespacesAndNewlines))\n\nIt provides reference context only. Continue in a separate destination conversation and verify workspace state before editing."
        case .privateThread:
            context = "A private source-thread link was supplied but deliberately omitted. It is scoped to the source profile. Ask for a ChatGPT shared-conversation link or capture the missing context in this brief."
        case .unsupported:
            context = "The supplied source link is not a transferable ChatGPT shared-conversation link and was deliberately omitted. Capture the relevant context in this brief."
        }
        return "# \(title)\n\n## Objective\n\(objective)\n\n## Source conversation context\n\(context)\n\n## Verified progress\n\(progress)\n\n## Workspace\n\(workspacePath)\n\n## Files and checks\n\(filesAndChecks)\n\n## Next steps and unresolved decisions\n\(nextSteps)\n\n## Pending approvals\n\(pendingApprovals)\n\n## Background jobs\n\(backgroundJobs)\n\n## Ownership\n\(ownershipReleased ? "Source ownership explicitly released for this handoff." : "Ownership has not been released. Do not begin overlapping edits.")\n"
    }
}
struct DiagnosticEvent: Identifiable, Codable, Sendable { var id = UUID(); var date = Date(); var category: String; var message: String }
struct DeckSettings: Codable, Sendable {
    var appearance = "System"
    // Legacy storage key retained so existing opt-in becomes the floating-tabs choice.
    var highContrastDark: Bool?
    var usesHighContrastTabs: Bool { highContrastDark == true }
    // Existing manager call sites stay on native appearance while the scoped
    // styling helpers are retired independently of this preference migration.
    var usesHighContrastDark: Bool { false }
    var showFloatingTabs = false
    var notificationsEnabled = false
    var completionAlerts = true
    var inputAlerts = true
    var failureAlerts = true
    var usageAlerts = true
    var sound = false
    var launchAtLogin = true
    // Optional for decoding installations created before default-on startup.
    var launchAtLoginInitialized: Bool?
    var shortcutKeyCode: UInt32 = 49
    var shortcutModifiers: UInt32 = 6144
    var warningThreshold = 80
    var criticalThreshold = 95
    var refreshSeconds = 60
}
struct PersistedDeck: Codable, Sendable {
    var schemaVersion = 1
    var profiles: [Profile] = []
    var lastSelectedProfileID: UUID?
    var world = SharedWorld.initial
    var settings = DeckSettings()
    var integrations: [IntegrationStatus] = []
    var handoffs: [Handoff] = []
    var archivedHandoffs: [Handoff] = []
    var transactions: [ConfigurationTransaction] = []
    var tasks: [TaskObservation] = []
    var usage: [UsageSnapshot] = []
    var notifications: Set<String> = []
    var diagnostics: [DiagnosticEvent] = []
    var onboardingComplete = false
}
enum DeckError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

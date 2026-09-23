import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Vercel Dark seeds verified in the installed official desktop bundle:
/// app.asar/webview/assets/vercel-dark-fe3b20ba4c28.js:1.
/// Derived surface/border values follow app-initial-a498f911edeb.js:1,
/// Njs/Mjs/Fjs: contrast 50 maps to 0.383333. Native SF fonts/controls remain.
enum DeckVercelPalette {
    static let surface=hex(0x000000)
    static let panel=hex(0x0A0A0A)
    static let control=hex(0x131313)
    static let elevated=hex(0x1A1A1A)
    static let secondarySurface=hex(0x0E0E0E)
    static let ink=hex(0xEDEDED)
    static let secondaryInk=ink.opacity(0.688)
    static let tertiaryInk=ink.opacity(0.470)
    static let accent=hex(0x006EFE)
    static let accentText=hex(0x5BA2FE)
    static let selection=hex(0x00193B)
    static let selectionHover=hex(0x001B3F)
    static let border=ink.opacity(0.075)
    static let heavyBorder=ink.opacity(0.143)
    static let focusBorder=accentText.opacity(0.738)
    static func hex(_ rgb: UInt32) -> Color {
        Color(.sRGB,red:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255,opacity:1)
    }
}

private struct DeckHighContrastDarkKey: EnvironmentKey {
    static let defaultValue=false
}
extension EnvironmentValues {
    var deckHighContrastDark: Bool {
        get { self[DeckHighContrastDarkKey.self] }
        set { self[DeckHighContrastDarkKey.self]=newValue }
    }
}
private struct DeckHighContrastGroupBoxStyle: GroupBoxStyle {
    @Environment(\.deckHighContrastDark) private var enabled
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if enabled {
            VStack(alignment:.leading,spacing:10) {
                configuration.label.font(.headline)
                configuration.content
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(DeckVercelPalette.secondarySurface,in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(DeckVercelPalette.border,lineWidth:1))
        } else { DefaultGroupBoxStyle().makeBody(configuration:configuration) }
    }
}
private struct DeckHighContrastContent: ViewModifier {
    var enabled: Bool
    @Environment(\.colorScheme) private var inheritedScheme
    func body(content: Content) -> some View {
        content.groupBoxStyle(DeckHighContrastGroupBoxStyle())
            .environment(\.deckHighContrastDark,enabled)
            .environment(\.colorScheme,enabled ? .dark : inheritedScheme)
            .foregroundStyle(enabled ? DeckVercelPalette.ink : Color.primary)
            .tint(enabled ? DeckVercelPalette.accent : nil)
    }
}
extension View {
    /// Apply only to manager/panel content, never the menu-bar popover.
    func deckHighContrastContent(enabled: Bool) -> some View {
        modifier(DeckHighContrastContent(enabled:enabled))
    }
    func deckHighContrastSurface(enabled: Bool, surface: Color = DeckVercelPalette.surface) -> some View {
        background(enabled ? surface : Color.clear)
            .deckHighContrastContent(enabled:enabled)
    }
    @ViewBuilder func deckHighContrastDialog(enabled: Bool) -> some View {
        if enabled { self.presentationBackground(DeckVercelPalette.panel).deckHighContrastSurface(enabled:true,surface:DeckVercelPalette.panel) }
        else { self }
    }
}

enum PlanDisplayName {
    static func format(_ raw: String) -> String {
        raw.components(separatedBy:CharacterSet(charactersIn:"_-")).filter { !$0.isEmpty }.joined(separator:" ").capitalized
    }
}

struct PageHeading: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct HealthLabel: View {
    var state: HealthState
    var body: some View { Label(state.rawValue, systemImage: symbol).foregroundStyle(state == .error || state == .conflict ? Color.orange : Color.secondary).font(.caption) }
    private var symbol: String { switch state { case .shared: "checkmark.circle"; case .pending: "arrow.clockwise"; case .signIn: "key"; case .conflict, .error: "exclamationmark.triangle"; case .unavailable: "minus.circle"; case .unchecked: "questionmark.circle" } }
}
struct ProfileGlyph: View {
    var profile: Profile
    var body: some View { Image(systemName: "person.crop.rectangle").foregroundStyle(tint).accessibilityHidden(true) }
    private var tint: Color { switch profile.color { case "green": .green; case "orange": .orange; case "purple": .purple; case "pink": .pink; case "gray": .secondary; default: .blue } }
}
struct PathPicker: View {
    var title: String
    @Binding var path: String
    var body: some View {
        HStack {
            TextField(title, text: $path).textFieldStyle(.roundedBorder)
            Button("Choose…") { Task { if let url = await DeckPanels.open(directory: true) { path = url.path } } }
        }
    }
}
@MainActor enum DeckPanels {
    static func open(directory: Bool = false) async -> URL? {
        let panel = NSOpenPanel(); panel.appearance = NSApp.keyWindow?.effectiveAppearance; panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        if !directory { panel.allowedContentTypes = [.json] }
        return await panel.begin() == .OK ? panel.url : nil
    }
    static func save(name: String, type: UTType = .json) async -> URL? {
        let panel = NSSavePanel(); panel.appearance = NSApp.keyWindow?.effectiveAppearance; panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        return await panel.begin() == .OK ? panel.url : nil
    }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func openPath(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
}
struct EmptyNotice: View {
    var title: String
    var symbol: String
    var detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
    }
}
struct SheetFooter: View {
    var title: String = "Save"
    var enabled = true
    var busy = false
    var cancel: () -> Void
    var action: () -> Void
    var body: some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(busy)
            Button(title, action: action).keyboardShortcut(.defaultAction).disabled(!enabled || busy)
        }.padding()
    }
}

enum UsageMeterTint: Equatable {
    case green, yellow, orange, red
    static func forUsedPercent(_ usedPercent: Double) -> UsageMeterTint {
        if usedPercent >= 95 { return .red }
        if usedPercent >= 80 { return .orange }
        if usedPercent >= 50 { return .yellow }
        return .green
    }
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        }
    }
}

/// Provider-reported usage fills from empty to full. A cached reading keeps its
/// last verified percentage and usage colour; freshness belongs in the label,
/// help and accessibility value rather than being misrepresented as zero use.
struct AllowanceMeter: View {
    var window: UsageWindow
    var isFresh: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color { UsageMeterTint.forUsedPercent(window.usedPercent).color }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint).frame(width: geometry.size.width * window.usedFraction)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: window.usedFraction)
            }
        }.frame(height: 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.label) usage consumed\(isFresh ? "" : ", cached reading")")
            .accessibilityValue("\(Int(window.usedPercent.rounded())) percent")
            .help("\(Int(window.usedPercent.rounded()))% used\(isFresh ? "" : " · cached reading")")
    }
}

/// Uses the selected source's configured budget, never subscription quota.
struct APIUsageMeter: View {
    var spend: APISpendSnapshot
    var isFresh: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let percent = spend.budgetUsedPercent {
                HStack {
                    Text(spend.budgetLabel).lineLimit(1)
                    Spacer()
                    Text("\(Int(percent.rounded()))% used").monospacedDigit().fixedSize()
                }.font(.caption2).foregroundStyle(.secondary)
                AllowanceMeter(window: UsageWindow(id: "api-budget", usedPercent: percent), isFresh: isFresh && Date().timeIntervalSince(spend.budgetAsOf ?? spend.fetchedAt) < 900)
                    .accessibilityLabel(spend.budgetLabel + " usage")
            } else {
                Text(spend.budgetUnavailableReason).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }.help(spend.budgetUsedPercent == nil ? spend.budgetUnavailableReason : spend.budgetLabel)
    }
}

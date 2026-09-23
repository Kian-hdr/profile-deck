import SwiftUI
import AppKit

struct ShortcutRecorder: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?
    var body: some View {
        HStack {
            Text("Global shortcut")
            Spacer()
            Button(recording ? "Press a shortcut…" : label) { recording ? stop() : start() }.onDisappear { stop() }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    private var label: String {
        var text = ""
        if modifiers & 4096 != 0 { text += "⌃" }; if modifiers & 2048 != 0 { text += "⌥" }; if modifiers & 512 != 0 { text += "⇧" }; if modifiers & 256 != 0 { text += "⌘" }
        return text + (keyCode == 49 ? "Space" : "Key \(keyCode)")
    }
    private func start() {
        recording = true; error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { stop(); return }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { error = "Include Control, Option or Command"; return }
                var value: UInt32 = 0
                if flags.contains(.command) { value |= 256 }; if flags.contains(.shift) { value |= 512 }; if flags.contains(.option) { value |= 2048 }; if flags.contains(.control) { value |= 4096 }
                keyCode = UInt32(event.keyCode); modifiers = value; stop()
            }
            return nil
        }
    }
    private func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false }
}

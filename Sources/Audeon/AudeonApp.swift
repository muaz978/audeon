import SwiftUI
import AppKit

@main
struct AudeonApp: App {
    @StateObject private var store = MixerStore()

    var body: some Scene {
        WindowGroup("Audeon") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Native menu + keyboard shortcuts (free on macOS).
            CommandGroup(replacing: .newItem) {
                Button("Save Preset...") { store.requestSavePreset() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu("Routing") {
                Button(store.allMuted ? "Unmute All" : "Mute All") { store.toggleMuteAll() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Clear Solo") { store.clearSolo() }
                    .disabled(!store.anySolo)
                Divider()
                Button("Disconnect All") { store.routes.removeAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Refresh Devices") { store.deviceManager.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        // Menu bar control for quick muting without raising the window.
        MenuBarExtra("Audeon", systemImage: store.allMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
            MenuBarContent()
                .environmentObject(store)
        }
    }
}

/// Compact menu bar panel: master mute and per-route quick mute.
private struct MenuBarContent: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        Button(store.allMuted ? "Unmute All" : "Mute All") { store.toggleMuteAll() }
        if store.anySolo {
            Button("Clear Solo") { store.clearSolo() }
        }
        Divider()
        if store.routes.isEmpty {
            Text("No routes")
        } else {
            ForEach(store.routes) { route in
                let inName = store.deviceManager.endpoint(forUID: route.inputUID)?.name ?? "?"
                let outName = store.deviceManager.endpoint(forUID: route.outputUID)?.name ?? "?"
                Button {
                    store.toggleMute(route.id)
                } label: {
                    Text("\(route.isMuted ? "Muted" : "On"): \(inName) to \(outName)")
                }
            }
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

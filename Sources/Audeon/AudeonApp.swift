import SwiftUI
import AppKit

@main
struct AudeonApp: App {
    @StateObject private var store = MixerStore()

    var body: some Scene {
        WindowGroup("Audeon") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Routing") {
                Button("Refresh Devices & Apps") {
                    store.deviceManager.refresh(); store.appManager.refresh()
                }.keyboardShortcut("r", modifiers: .command)
                Button("Disconnect All") { store.connections.removeAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Audeon", systemImage: "slider.horizontal.3") {
            Button("Open Audeon") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Refresh Devices & Apps") {
                store.deviceManager.refresh(); store.appManager.refresh()
            }
            Divider()
            Button("Quit Audeon") { NSApplication.shared.terminate(nil) }
        }
    }
}

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: MixerStore
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RoutingCanvasView()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $store.showSettings) { SettingsView().environmentObject(store) }
        .onAppear { Appearance.apply(appearance) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            mainMenu
            Text("Audeon").font(.headline)
            Spacer()
            if store.pendingSourceID != nil {
                Text("Now click an output pin to connect")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { store.pendingSourceID = nil }.controlSize(.small)
            }
            Button { store.deviceManager.refresh(); store.appManager.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button { store.showSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The menu button next to the title, in the spirit of the Mixline menu.
    private var mainMenu: some View {
        Menu {
            Button("Settings...") { store.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
            Button("Refresh Devices & Apps") {
                store.deviceManager.refresh(); store.appManager.refresh()
            }.keyboardShortcut("r", modifiers: .command)
            Button("Open Sound Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("Quit Audeon") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

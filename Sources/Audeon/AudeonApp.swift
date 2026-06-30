import SwiftUI
import AppKit

@main
struct AudeonApp: App {
    @StateObject private var store = MixerStore()

    var body: some Scene {
        WindowGroup("Audeon") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 620)
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

        // Compact control panel in the menu bar.
        MenuBarExtra("Audeon", systemImage: "slider.horizontal.3") {
            MenuBarPanel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// A small window-style menu bar panel to tweak each input's volume, mute, and
/// boost without opening the main window.
private struct MenuBarPanel: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Audeon").font(.headline)
                Spacer()
                Button("Open") { NSApp.activate(ignoringOtherApps: true) }
                    .controlSize(.small)
            }
            Divider()
            if store.inputs.isEmpty {
                Text("No inputs added yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.inputs) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle().fill(store.color(forPin: source.pinKey).color).frame(width: 7, height: 7)
                                    Text(store.title(for: source)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Button {
                                        store.updateInput(source.id) { $0.isMuted.toggle() }
                                    } label: {
                                        Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .foregroundStyle(source.isMuted ? .red : .primary)
                                    }.buttonStyle(.borderless)
                                }
                                HStack(spacing: 6) {
                                    Slider(value: Binding(get: { source.volume },
                                                          set: { v in store.updateInput(source.id) { $0.volume = v } }), in: 0...1)
                                    .controlSize(.mini)
                                    ForEach(1...4, id: \.self) { n in
                                        Button("\(n)x") { store.setBoost(Double(n), for: source.id) }
                                            .buttonStyle(.borderless)
                                            .font(.system(size: 10, weight: Int(source.boost) == n ? .bold : .regular))
                                            .foregroundStyle(Int(source.boost) == n ? store.color(forPin: source.pinKey).color : .secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider()
            HStack {
                Button("Refresh") { store.deviceManager.refresh(); store.appManager.refresh() }
                    .controlSize(.small)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

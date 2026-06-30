import SwiftUI
import AppKit

@main
struct AudeonApp: App {
    @StateObject private var store = MixerStore()

    var body: some Scene {
        WindowGroup("Audeon") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1060, minHeight: 660)
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

/// A compact window-style menu bar panel mirroring the main quick controls:
/// per input volume, mute, boost, and EQ toggle.
private struct MenuBarPanel: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("Audeon").font(.headline)
                Spacer()
                Button("Open") { NSApp.activate(ignoringOtherApps: true) }.controlSize(.small)
            }
            Divider()
            if store.inputs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No inputs yet").font(.subheadline.weight(.medium))
                    Text("Open Audeon and use Add input to route a device or app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.inputs) { source in inputRow(source) }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Button { store.deviceManager.refresh(); store.appManager.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.controlSize(.small)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private func inputRow(_ source: InputSource) -> some View {
        let color = store.color(forPin: source.pinKey).color
        let connected = store.connectedOutputs(for: source.id).count
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color.opacity(store.isActive(source) ? 1 : 0.4)).frame(width: 8, height: 8)
                Text(store.title(for: source)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !store.isActive(source) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Spacer()
                Text(connected == 0 ? "Not routed" : "\(connected) out")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button { store.updateInput(source.id) { $0.isMuted.toggle() } } label: {
                    Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(source.isMuted ? .red : .primary)
                }.buttonStyle(.borderless)
                Slider(value: Binding(get: { source.volume },
                                      set: { v in store.updateInput(source.id) { $0.volume = v } }), in: 0...1)
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("Boost").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(1...4, id: \.self) { n in
                    Button("\(n)x") { store.setBoost(Double(n), for: source.id) }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .tint(Int(source.boost) == n ? color : .gray)
                }
                Spacer()
                Toggle("EQ", isOn: Binding(get: { source.eqEnabled }, set: { _ in store.toggleEQ(for: source.id) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }
}

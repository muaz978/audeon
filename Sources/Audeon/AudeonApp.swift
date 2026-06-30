import SwiftUI
import AppKit

@main
struct AudeonApp: App {
    @StateObject private var store = MixerStore.shared

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

        // A real window for the quick controls. Windows observe the shared store
        // reliably, unlike a MenuBarExtra window-style panel.
        Window("Quick Controls", id: "quickControls") {
            QuickControlsView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        // The menu bar item is a plain menu (always reliable) that opens the
        // quick controls window or the main window.
        MenuBarExtra("Audeon", systemImage: "slider.horizontal.3") {
            MenuBarMenu()
        }
    }
}

/// The menu shown from the menu bar icon. Plain buttons, which always render.
private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Quick Controls...") {
            openWindow(id: "quickControls")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Audeon") { NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Refresh Devices & Apps") {
            MixerStore.shared.deviceManager.refresh()
            MixerStore.shared.appManager.refresh()
        }
        Divider()
        Button("Quit Audeon") { NSApplication.shared.terminate(nil) }
    }
}

/// Compact quick-controls window mirroring the main controls: per input and
/// output volume and mute, plus boost and EQ for inputs.
private struct QuickControlsView: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("Quick Controls").font(.headline)
                Spacer()
                Button { NSApp.activate(ignoringOtherApps: true) } label: {
                    Image(systemName: "macwindow")
                }.help("Open the main window")
            }
            Divider()
            if store.inputs.isEmpty && store.outputs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing added yet").font(.subheadline.weight(.medium))
                    Text("Open Audeon and use Add input or Add output.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.inputs.isEmpty {
                            Text("INPUTS").font(.caption2.bold()).foregroundStyle(.secondary)
                            ForEach(store.inputs) { inputRow($0) }
                        }
                        if !store.outputs.isEmpty {
                            Text("OUTPUTS").font(.caption2.bold()).foregroundStyle(.secondary)
                            ForEach(store.outputs) { outputRow($0) }
                        }
                    }
                }
                .frame(maxHeight: 420)
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

    @ViewBuilder
    private func outputRow(_ output: OutputTarget) -> some View {
        let color = store.color(forPin: output.pinKey).color
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.fill").font(.system(size: 11)).foregroundStyle(color)
                Text(store.deviceManager.endpoint(forUID: output.uid)?.name ?? "Output")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            HStack(spacing: 8) {
                Button { store.updateOutput(output.id) { $0.isMuted.toggle() } } label: {
                    Image(systemName: output.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(output.isMuted ? .red : .primary)
                }.buttonStyle(.borderless)
                Slider(value: Binding(get: { output.volume },
                                      set: { v in store.updateOutput(output.id) { $0.volume = v } }), in: 0...1)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }
}

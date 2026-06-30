import SwiftUI
import AppKit

@main
struct AudeonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    }
}

/// Owns the menu bar status item and a popover anchored to it. Built with
/// AppKit so the popover reliably drops down from the icon and observes the
/// shared store, which the SwiftUI MenuBarExtra panel did not do here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: QuickControlsView().environmentObject(MixerStore.shared))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Audeon")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// The quick controls shown in the menu bar popover. Mirrors the main controls
/// and can also change which outputs each input is routed to.
private struct QuickControlsView: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("Audeon").font(.headline)
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil); break }
                } label: {
                    Label("Open", systemImage: "macwindow")
                }.controlSize(.small)
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
                .frame(maxHeight: 400)
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
        let connectedCount = store.connectedOutputs(for: source.id).count
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color.opacity(store.isActive(source) ? 1 : 0.4)).frame(width: 8, height: 8)
                Text(store.title(for: source)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !store.isActive(source) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Spacer()
                routeMenu(source)
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

    /// Menu to connect or disconnect this input from each output.
    private func routeMenu(_ source: InputSource) -> some View {
        let count = store.connectedOutputs(for: source.id).count
        return Menu {
            if store.outputs.isEmpty {
                Text("Add an output first")
            } else {
                ForEach(store.outputs) { o in
                    let on = store.isConnected(sourceID: source.id, outputID: o.id)
                    Button {
                        store.toggleConnection(sourceID: source.id, outputID: o.id)
                    } label: {
                        Label(store.deviceManager.endpoint(forUID: o.uid)?.name ?? "Output",
                              systemImage: on ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        } label: {
            Text(count == 0 ? "Route" : "\(count) out").font(.system(size: 10))
        }
        .menuStyle(.borderlessButton).fixedSize()
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

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

/// Owns the menu bar status item and a popover anchored to it, built with AppKit
/// so the popover reliably drops down from the icon and observes the shared store.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 560)
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

// MARK: - Quick controls popover (SoundSource-style)

private struct QuickControlsView: View {
    @EnvironmentObject var store: MixerStore
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.inputs.isEmpty && store.outputs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !store.inputs.isEmpty {
                            sectionHeader("APPLICATIONS & DEVICES")
                            ForEach(store.inputs) { inputRow($0) }
                        }
                        if !store.outputs.isEmpty {
                            sectionHeader("OUTPUTS")
                            ForEach(store.outputs) { outputRow($0) }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            Divider()
            footer
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
            Text("Audeon").font(.headline)
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil); break }
            } label: { Image(systemName: "macwindow") }
            .buttonStyle(.borderless).help("Open the main window")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button { store.deviceManager.refresh(); store.appManager.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }.controlSize(.small)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing added yet").font(.subheadline.weight(.medium))
            Text("Open Audeon and use Add input or Add output.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }

    // MARK: Input row

    @ViewBuilder
    private func inputRow(_ source: InputSource) -> some View {
        let color = store.color(forPin: source.pinKey).color
        let isOpen = expanded.contains(source.id)
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                icon(for: source, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.title(for: source)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack(spacing: 3) {
                        if !store.isActive(source) {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 8)).foregroundStyle(.orange)
                        }
                        Text(store.isActive(source) ? "Active" : "Inactive")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                muteButton(isMuted: source.isMuted) { store.updateInput(source.id) { $0.isMuted.toggle() } }
                Slider(value: Binding(get: { source.volume },
                                      set: { v in store.updateInput(source.id) { $0.volume = v } }), in: 0...1)
                    .controlSize(.small).tint(.green).frame(width: 92)
                percent(source.volume)
                routeMenu(source)
                Button { toggle(source.id) } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 11))
                }.buttonStyle(.borderless)
            }
            if isOpen { fxPanel(source, color: color) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        Divider().padding(.leading, 14)
    }

    private func fxPanel(_ source: InputSource, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Volume Overdrive").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ForEach(1...4, id: \.self) { n in
                    Button("\(n)x") { store.setBoost(Double(n), for: source.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(Int(source.boost) == n ? color : .gray)
                }
            }
            HStack {
                Toggle("10-Band EQ", isOn: Binding(get: { source.eqEnabled }, set: { _ in store.toggleEQ(for: source.id) }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11, weight: .medium))
                Spacer()
                Menu("Preset") {
                    ForEach(AudioEQ.presets, id: \.name) { p in
                        Button(p.name) { store.applyEQPreset(p.gains, for: source.id) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<AudioEQ.bandCount, id: \.self) { i in
                    VStack(spacing: 2) {
                        vSlider(Binding(get: { source.eq.indices.contains(i) ? source.eq[i] : 0 },
                                        set: { store.setEQBand(i, $0, for: source.id) }))
                        Text(AudioEQ.shortLabel(forFrequency: AudioEQ.frequencies[i]))
                            .font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(source.eqEnabled ? 1 : 0.4)
            .disabled(!source.eqEnabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Output row

    @ViewBuilder
    private func outputRow(_ output: OutputTarget) -> some View {
        let color = store.color(forPin: output.pinKey).color
        HStack(spacing: 10) {
            Image(systemName: "hifispeaker.fill").font(.system(size: 14)).frame(width: 22).foregroundStyle(color)
            Text(store.deviceManager.endpoint(forUID: output.uid)?.name ?? "Output")
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            muteButton(isMuted: output.isMuted) { store.updateOutput(output.id) { $0.isMuted.toggle() } }
            Slider(value: Binding(get: { output.volume },
                                  set: { v in store.updateOutput(output.id) { $0.volume = v } }), in: 0...1)
                .controlSize(.small).tint(.green).frame(width: 92)
            percent(output.volume)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        Divider().padding(.leading, 14)
    }

    // MARK: Pieces

    private func icon(for source: InputSource, color: Color) -> some View {
        Group {
            if let img = store.icon(for: source) {
                Image(nsImage: img).resizable().frame(width: 22, height: 22).opacity(store.isActive(source) ? 1 : 0.5)
            } else {
                Image(systemName: "mic.fill").font(.system(size: 14)).frame(width: 22).foregroundStyle(color)
            }
        }
    }

    private func muteButton(isMuted: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(isMuted ? .red : .primary)
        }.buttonStyle(.borderless)
    }

    private func percent(_ v: Double) -> some View {
        Text("\(Int(v * 100))%").font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
    }

    private func routeMenu(_ source: InputSource) -> some View {
        let connected = store.connectedOutputs(for: source.id)
        let label: String = connected.isEmpty ? "Route"
            : (connected.count == 1 ? (store.deviceManager.endpoint(forUID: connected[0].uid)?.name ?? "1 out")
                                    : "\(connected.count) outs")
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
            Text(label).font(.system(size: 10)).lineLimit(1).frame(maxWidth: 64)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func vSlider(_ value: Binding<Double>) -> some View {
        Slider(value: value, in: -12...12)
            .controlSize(.mini).tint(.green)
            .frame(width: 72).rotationEffect(.degrees(-90)).frame(width: 22, height: 76)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

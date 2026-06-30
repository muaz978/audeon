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
/// so the popover reliably drops from the icon and observes the shared store.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 600)
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
    @State private var systemOpen = true
    @State private var appsOpen = true
    @State private var muteMemory: [String: Float] = [:]   // device uid -> volume before mute

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    systemSection
                    appsSection
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 460)
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
            .buttonStyle(.borderless).help("Open main window")
            Button { MixerStore.shared.showSettings = true; NSApp.activate(ignoringOtherApps: true) } label: {
                Image(systemName: "gearshape")
            }.buttonStyle(.borderless).help("Settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            addMenu
            Spacer()
            Button { store.deviceManager.refresh(); store.appManager.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.borderless).help("Refresh")
            Button("Quit") { NSApplication.shared.terminate(nil) }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var addMenu: some View {
        Menu {
            let usedDevices = Set(store.inputs.compactMap { $0.deviceUID })
            let usedApps = Set(store.inputs.compactMap { $0.appBundleID })
            Section("Audio devices") {
                ForEach(store.deviceManager.inputs.filter { !usedDevices.contains($0.uid) }) { d in
                    Button(d.name) { store.addDeviceInput(uid: d.uid) }
                }
            }
            Section("Applications") {
                ForEach(store.appManager.apps.filter { !usedApps.contains($0.bundleID) }) { app in
                    Button(app.name) { store.addAppInput(bundleID: app.bundleID, name: app.name) }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }.menuStyle(.borderlessButton).fixedSize().controlSize(.small)
    }

    // MARK: System section

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("System", isOpen: $systemOpen)
            if systemOpen {
                VStack(spacing: 0) {
                    systemRow("Output", icon: "speaker.wave.2.fill", scope: .output,
                              currentUID: store.systemAudio.defaultOutputUID,
                              devices: store.deviceManager.outputs) { store.systemAudio.setDefaultOutput($0) }
                    Divider().padding(.leading, 38)
                    systemRow("Input", icon: "mic.fill", scope: .input,
                              currentUID: store.systemAudio.defaultInputUID,
                              devices: store.deviceManager.inputs) { store.systemAudio.setDefaultInput($0) }
                    Divider().padding(.leading, 38)
                    systemRow("Sound Effects", icon: "bell.fill", scope: .output,
                              currentUID: store.systemAudio.defaultSystemOutputUID,
                              devices: store.deviceManager.outputs) { store.systemAudio.setDefaultSystemOutput($0) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func systemRow(_ label: String, icon: String, scope: EndpointKind,
                           currentUID: String?, devices: [AudioEndpoint],
                           onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            Text(label).font(.system(size: 13, weight: .medium)).frame(width: 96, alignment: .leading)
            if let uid = currentUID {
                muteButton(uid: uid, scope: scope)
                Slider(value: deviceVolumeBinding(uid: uid, scope: scope), in: 0...1)
                    .controlSize(.small).tint(.green).frame(width: 92)
                percent(deviceVolumeBinding(uid: uid, scope: scope).wrappedValue)
            } else {
                Spacer()
            }
            Spacer(minLength: 4)
            deviceMenu(currentUID: currentUID, devices: devices, onSelect: onSelect)
        }
        .padding(.vertical, 7)
    }

    // MARK: Applications section

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Applications", isOpen: $appsOpen)
            if appsOpen {
                if store.inputs.isEmpty {
                    Text("Use Add below to bring in a device or app.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.inputs.enumerated()), id: \.element.id) { idx, source in
                            if idx > 0 { Divider().padding(.leading, 38) }
                            appRow(source)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    @ViewBuilder
    private func appRow(_ source: InputSource) -> some View {
        let color = store.color(forPin: source.pinKey).color
        let isOpen = expanded.contains(source.id)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { store.removeInput(source.id) } label: {
                    Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow)
                }.buttonStyle(.borderless).help("Remove from list")
                appIcon(source, color: color)
                Text(store.title(for: source)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(store.isActive(source) ? 1 : 0.6)

                muteButton2(isMuted: source.isMuted) { store.updateInput(source.id) { $0.isMuted.toggle() } }
                Slider(value: Binding(get: { source.volume },
                                      set: { v in store.updateInput(source.id) { $0.volume = v } }), in: 0...1)
                    .controlSize(.small).tint(.green).frame(width: 84)
                percent(source.volume)
                Button("\(Int(source.boost))x") { cycleBoost(source) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(source.boost > 1 ? color : .gray)
                    .help("Volume Overdrive")
                redirectMenu(source)
                Button { toggle(source.id) } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.right").font(.system(size: 11))
                }.buttonStyle(.borderless).help("Effects")
            }
            if isOpen { eqPanel(source, color: color) }
        }
        .padding(.vertical, 7)
    }

    private func eqPanel(_ source: InputSource, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
            .opacity(source.eqEnabled ? 1 : 0.4).disabled(!source.eqEnabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { isOpen.wrappedValue.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 10))
                Text(title).font(.system(size: 13, weight: .bold))
                Spacer()
            }
        }.buttonStyle(.plain).padding(.bottom, 6)
    }

    private func appIcon(_ source: InputSource, color: Color) -> some View {
        Group {
            if let img = store.icon(for: source) {
                Image(nsImage: img).resizable().frame(width: 20, height: 20).opacity(store.isActive(source) ? 1 : 0.5)
            } else {
                Image(systemName: "mic.fill").font(.system(size: 13)).frame(width: 20).foregroundStyle(color)
            }
        }
    }

    private func muteButton2(isMuted: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(isMuted ? .red : .primary)
        }.buttonStyle(.borderless)
    }

    private func percent(_ v: Double) -> some View {
        Text("\(Int(v * 100))%").font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
    }

    private func deviceMenu(currentUID: String?, devices: [AudioEndpoint],
                            onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(devices) { d in Button(d.name) { onSelect(d.uid) } }
        } label: {
            Text(devices.first { $0.uid == currentUID }?.name ?? "Default")
                .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 120, alignment: .trailing)
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private func redirectMenu(_ source: InputSource) -> some View {
        let connected = store.connectedDeviceUIDs(for: source.id)
        let label: String = connected.isEmpty ? "No Redirect"
            : (connected.count == 1 ? (store.deviceManager.endpoint(forUID: connected.first!)?.name ?? "1 device")
                                    : "\(connected.count) devices")
        return Menu {
            Button { store.clearRoutes(for: source.id) } label: {
                Label("No Redirect", systemImage: connected.isEmpty ? "checkmark" : "")
            }
            Divider()
            ForEach(store.deviceManager.outputs) { d in
                Button { store.toggleRouteToDevice(sourceID: source.id, deviceUID: d.uid) } label: {
                    Label(d.name, systemImage: connected.contains(d.uid) ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.forward").font(.system(size: 9))
                Text(label).font(.system(size: 11)).lineLimit(1)
            }.frame(maxWidth: 116, alignment: .trailing)
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private func vSlider(_ value: Binding<Double>) -> some View {
        Slider(value: value, in: -12...12).controlSize(.mini).tint(.green)
            .frame(width: 74).rotationEffect(.degrees(-90)).frame(width: 22, height: 78)
    }

    // MARK: System device volume + mute

    private func deviceVolumeBinding(uid: String, scope: EndpointKind) -> Binding<Double> {
        Binding(
            get: {
                let v = scope == .input ? store.deviceManager.inputVolume(forUID: uid)
                                        : store.deviceManager.outputVolume(forUID: uid)
                return Double(v ?? 0)
            },
            set: { nv in
                if scope == .input { store.deviceManager.setInputVolume(Float(nv), forUID: uid) }
                else { store.deviceManager.setOutputVolume(Float(nv), forUID: uid) }
            })
    }

    private func muteButton(uid: String, scope: EndpointKind) -> some View {
        let current = scope == .input ? store.deviceManager.inputVolume(forUID: uid)
                                      : store.deviceManager.outputVolume(forUID: uid)
        let isMuted = (current ?? 0) <= 0.0001
        return Button {
            if isMuted {
                let restore = muteMemory[uid] ?? 0.5
                if scope == .input { store.deviceManager.setInputVolume(restore, forUID: uid) }
                else { store.deviceManager.setOutputVolume(restore, forUID: uid) }
            } else {
                muteMemory[uid] = current
                if scope == .input { store.deviceManager.setInputVolume(0, forUID: uid) }
                else { store.deviceManager.setOutputVolume(0, forUID: uid) }
            }
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(isMuted ? .red : .primary)
        }.buttonStyle(.borderless)
    }

    private func cycleBoost(_ source: InputSource) {
        let next = source.boost >= 4 ? 1.0 : source.boost + 1
        store.setBoost(next, for: source.id)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

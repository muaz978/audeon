import SwiftUI
import AppKit

/// Anchor positions of each endpoint connector dot, keyed by endpoint uid,
/// collected via preferences so the overlay can draw routing lines.
struct ConnectorAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [String: Anchor<CGPoint>],
                       nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: MixerStore
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.mode == .apps {
                AppsView()
            } else {
                routingArea
                Divider()
                RouteInspectorView()
                    .frame(height: 190)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $store.showSavePresetSheet) { savePresetSheet }
        .sheet(isPresented: $store.showSettings) { SettingsView() }
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(spacing: 12) {
            mainMenu
            Text("Audeon").font(.headline)

            Picker("", selection: $store.mode) {
                ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if store.mode == .routing {
                if !store.presets.isEmpty {
                    Menu("Presets") {
                        ForEach(store.presets) { preset in
                            Button(preset.name) { store.loadPreset(preset) }
                        }
                        Divider()
                        ForEach(store.presets) { preset in
                            Button("Delete \(preset.name)", role: .destructive) {
                                store.deletePreset(preset.id)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button { store.requestSavePreset() } label: {
                    Label("Save Preset", systemImage: "square.and.arrow.down")
                }
            }
            Button { store.deviceManager.refresh(); store.appManager.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The menu button next to the title, in the spirit of SoundSource's menu.
    private var mainMenu: some View {
        Menu {
            Button("Settings...") { store.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Apps & System") { store.mode = .apps }
            Button("Device Routing") { store.mode = .routing }
            Divider()
            Button("Refresh Devices & Apps") {
                store.deviceManager.refresh(); store.appManager.refresh()
            }
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

    // MARK: - Routing canvas

    private var routingArea: some View {
        HStack(alignment: .top, spacing: 0) {
            EndpointColumnView(kind: .input)
                .frame(maxWidth: .infinity)
            Divider()
            EndpointColumnView(kind: .output)
                .frame(maxWidth: .infinity)
        }
        .overlayPreferenceValue(ConnectorAnchorKey.self) { anchors in
            GeometryReader { proxy in
                ConnectionsOverlay(anchors: anchors, proxy: proxy)
            }
            .allowsHitTesting(false)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Save preset sheet

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Preset").font(.headline)
            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { store.showSavePresetSheet = false; presetName = "" }
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    store.saveCurrentAsPreset(named: name.isEmpty ? "Untitled" : name)
                    store.showSavePresetSheet = false
                    presetName = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

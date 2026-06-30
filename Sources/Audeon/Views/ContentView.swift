import SwiftUI

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
            routingArea
            Divider()
            RouteInspectorView()
                .frame(height: 190)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $store.showSavePresetSheet) { savePresetSheet }
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(spacing: 12) {
            Label("Audeon", systemImage: "slider.horizontal.3")
                .font(.headline)
            Text("\(store.deviceManager.inputs.count) in / \(store.deviceManager.outputs.count) out / \(store.routes.count) routes")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

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
            Button { store.deviceManager.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

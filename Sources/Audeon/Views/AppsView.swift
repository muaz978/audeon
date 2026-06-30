import SwiftUI

/// The "Apps & System" workspace, modeled on the SoundSource layout: a System
/// section for the default devices, and an Applications section that lists every
/// running app with per-app volume and a redirect target.
struct AppsView: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                systemSection
                applicationsSection
            }
            .padding(16)
        }
    }

    // MARK: - System

    private var systemSection: some View {
        SectionCard(title: "SYSTEM") {
            DeviceRow(
                icon: "speaker.wave.2.fill",
                title: "Output",
                devices: store.deviceManager.outputs,
                selectedUID: store.systemAudio.defaultOutputUID,
                onSelect: { store.systemAudio.setDefaultOutput($0) },
                scope: .output,
                showRate: true
            )
            Divider().padding(.leading, 44)
            DeviceRow(
                icon: "mic.fill",
                title: "Input",
                devices: store.deviceManager.inputs,
                selectedUID: store.systemAudio.defaultInputUID,
                onSelect: { store.systemAudio.setDefaultInput($0) },
                scope: .input,
                showRate: true
            )
            Divider().padding(.leading, 44)
            DeviceRow(
                icon: "bell.fill",
                title: "Sound Effects",
                devices: store.deviceManager.outputs,
                selectedUID: store.systemAudio.defaultSystemOutputUID,
                onSelect: { store.systemAudio.setDefaultSystemOutput($0) },
                scope: .output,
                showRate: false
            )
        }
    }

    // MARK: - Applications

    private var applicationsSection: some View {
        SectionCard(title: "APPLICATIONS") {
            if store.appManager.apps.isEmpty {
                Text("No applications detected yet. Open an app that plays sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(store.appManager.apps.enumerated()), id: \.element.id) { idx, app in
                    if idx > 0 { Divider().padding(.leading, 44) }
                    AppRow(app: app)
                }
            }
        }
    }
}

// MARK: - Section container

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            VStack(spacing: 0) { content }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

// MARK: - System device row

private struct DeviceRow: View {
    @EnvironmentObject var store: MixerStore
    let icon: String
    let title: String
    let devices: [AudioEndpoint]
    let selectedUID: String?
    let onSelect: (String) -> Void
    let scope: EndpointKind
    let showRate: Bool

    private var selectedName: String {
        guard let uid = selectedUID else { return "Default" }
        return devices.first { $0.uid == uid }?.name ?? "Unknown"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 100, alignment: .leading)

            if let uid = selectedUID {
                DeviceVolumeSlider(uid: uid, scope: scope)
                    .frame(maxWidth: 170)
                if showRate { SampleRateMenu(uid: uid) }
            }

            Spacer()

            Menu {
                ForEach(devices) { d in
                    Button(d.name) { onSelect(d.uid) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedName).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .frame(minWidth: 180, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 8)
    }
}

private struct DeviceVolumeSlider: View {
    @EnvironmentObject var store: MixerStore
    let uid: String
    let scope: EndpointKind
    @State private var value: Double = 0
    @State private var hasControl = true

    private func read() -> Float? {
        scope == .input ? store.deviceManager.inputVolume(forUID: uid)
                        : store.deviceManager.outputVolume(forUID: uid)
    }
    private func write(_ v: Float) {
        if scope == .input { store.deviceManager.setInputVolume(v, forUID: uid) }
        else { store.deviceManager.setOutputVolume(v, forUID: uid) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: scope == .input ? "mic.fill" : "speaker.fill")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if hasControl {
                Slider(value: $value, in: 0...1)
                    .controlSize(.small)
                    .onChange(of: value) { write(Float($0)) }
                Text("\(Int(value * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("No software volume")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            if let v = read() { value = Double(v); hasControl = true }
            else { hasControl = false }
        }
        .id(uid)
    }
}

private struct SampleRateMenu: View {
    @EnvironmentObject var store: MixerStore
    let uid: String
    @State private var rate: Double = 0
    @State private var available: [Double] = []

    var body: some View {
        Menu {
            ForEach(available, id: \.self) { r in
                Button(label(r)) { store.deviceManager.setSampleRate(r, forUID: uid); rate = r }
            }
        } label: {
            Text(rate > 0 ? label(rate) : "Rate")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear {
            available = store.deviceManager.availableSampleRates(forUID: uid)
            rate = store.deviceManager.sampleRate(forUID: uid) ?? 0
        }
        .id(uid)
    }

    private func label(_ r: Double) -> String { "\(Int(r / 1000)) kHz" }
}

// MARK: - Application row

private struct AppRow: View {
    @EnvironmentObject var store: MixerStore
    let app: AudioApp

    private var redirect: AppRedirect { store.redirect(for: app.bundleID) }

    private var redirectName: String {
        guard let uid = redirect.outputUID else { return "No Redirect" }
        return store.deviceManager.outputs.first { $0.uid == uid }?.name ?? "Unknown"
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: "app.dashed").frame(width: 26, height: 26).foregroundStyle(.secondary)
            }
            Text(app.name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { redirect.volume },
                        set: { store.setAppVolume($0, for: app.bundleID) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                Text("\(Int(redirect.volume * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .frame(maxWidth: 200)

            Spacer()

            Menu {
                Button("No Redirect") { store.setAppOutput(nil, for: app.bundleID) }
                Divider()
                ForEach(store.deviceManager.outputs) { d in
                    Button(d.name) { store.setAppOutput(d.uid, for: app.bundleID) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: redirect.outputUID == nil ? "arrow.up" : "arrow.turn.up.right")
                        .font(.system(size: 9))
                    Text(redirectName).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .frame(minWidth: 180, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 8)
    }
}

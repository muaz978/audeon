import SwiftUI
import AppKit
import ServiceManagement

/// Tabbed settings, in the spirit of the SoundSource Settings window.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "switch.2") }
            DevicesTab().tabItem { Label("Devices", systemImage: "hifispeaker.2") }
            AppearanceTab().tabItem { Label("Appearance", systemImage: "eye") }
            AudioTab().tabItem { Label("Audio", systemImage: "hifispeaker") }
        }
        .frame(width: 480, height: 460)
    }
}

/// Per-device controls, in the spirit of SoundSource's Audio Devices window:
/// nickname, volume, sample rate, and Left/Right channel mapping.
private struct DevicesTab: View {
    @EnvironmentObject var store: MixerStore
    @State private var selectedUID: String?

    private struct Entry: Identifiable { let uid: String; let name: String; let isInput: Bool; let isOutput: Bool; var id: String { uid } }

    private var devices: [Entry] {
        var map: [String: Entry] = [:]
        for d in store.deviceManager.outputs { map[d.uid] = Entry(uid: d.uid, name: d.name, isInput: false, isOutput: true) }
        for d in store.deviceManager.inputs {
            if let e = map[d.uid] { map[d.uid] = Entry(uid: d.uid, name: e.name, isInput: true, isOutput: true) }
            else { map[d.uid] = Entry(uid: d.uid, name: d.name, isInput: true, isOutput: false) }
        }
        return map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Picker("Device", selection: $selectedUID) {
                Text("Choose...").tag(String?.none)
                ForEach(devices) { Text($0.name).tag(String?.some($0.uid)) }
            }
            if let uid = selectedUID, let entry = devices.first(where: { $0.uid == uid }) {
                detail(entry)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { if selectedUID == nil { selectedUID = store.systemAudio.defaultOutputUID ?? devices.first?.uid } }
    }

    @ViewBuilder
    private func detail(_ entry: Entry) -> some View {
        Section("General") {
            TextField("Nickname", text: Binding(
                get: { store.deviceNicknames[entry.uid] ?? "" },
                set: { store.setNickname($0, forUID: entry.uid) }))
            Text("Original name: \(entry.name)").font(.caption).foregroundStyle(.secondary)
        }
        if entry.isOutput {
            Section("Output") {
                volumeRow(uid: entry.uid, scope: .output)
                sampleRateRow(uid: entry.uid)
                channelRow(uid: entry.uid)
            }
        }
        if entry.isInput {
            Section("Input") {
                volumeRow(uid: entry.uid, scope: .input)
            }
        }
        Section {
            Text("Balance, a maximum-volume cap, and custom icons are not available yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func volumeRow(uid: String, scope: EndpointKind) -> some View {
        let value = scope == .input ? store.deviceManager.inputVolume(forUID: uid)
                                    : store.deviceManager.outputVolume(forUID: uid)
        return HStack {
            Text("Volume")
            Slider(value: Binding(
                get: { Double(value ?? 0) },
                set: { v in
                    if scope == .input { store.deviceManager.setInputVolume(Float(v), forUID: uid) }
                    else { store.deviceManager.setOutputVolume(Float(v), forUID: uid) }
                }), in: 0...1)
            .disabled(value == nil)
            Text(value == nil ? "n/a" : "\(Int((value ?? 0) * 100))%")
                .font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    private func sampleRateRow(uid: String) -> some View {
        let rates = store.deviceManager.availableSampleRates(forUID: uid)
        let current = store.deviceManager.sampleRate(forUID: uid) ?? 0
        return Picker("Sample Rate", selection: Binding(
            get: { current },
            set: { store.deviceManager.setSampleRate($0, forUID: uid) })) {
            if rates.isEmpty { Text("\(Int(current)) Hz").tag(current) }
            ForEach(rates, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
        }
    }

    @ViewBuilder
    private func channelRow(uid: String) -> some View {
        let count = max(2, store.deviceManager.outputChannelCount(forUID: uid))
        let pref = store.deviceManager.preferredStereoChannels(forUID: uid) ?? (1, 2)
        HStack {
            Text("Left Channel")
            Picker("", selection: Binding(
                get: { pref.left },
                set: { store.deviceManager.setPreferredStereoChannels(left: $0, right: pref.right, forUID: uid) })) {
                ForEach(1...count, id: \.self) { Text("\($0)").tag($0) }
            }.labelsHidden().frame(width: 70)
            Spacer()
            Text("Right Channel")
            Picker("", selection: Binding(
                get: { pref.right },
                set: { store.deviceManager.setPreferredStereoChannels(left: pref.left, right: $0, forUID: uid) })) {
                ForEach(1...count, id: \.self) { Text("\($0)").tag($0) }
            }.labelsHidden().frame(width: 70)
        }
    }
}

private struct GeneralTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start Audeon at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            Section("Permissions") {
                Button("Show Welcome & Permissions") {
                    NotificationCenter.default.post(name: .audeonShowOnboarding, object: nil)
                }
            }
            Section("Software update") {
                Text("Audeon is distributed on GitHub. New versions appear on the Releases page.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check for Updates") { open("https://github.com/muaz978/audeon/releases") }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AppearanceTab: View {
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearance) {
                    Text("Match System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, v in Appearance.apply(v) }
            }
            Section {
                Text("The menu bar item gives quick access without opening the window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AudioTab: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        Form {
            Section("Audio processing") {
                Text("Application audio is captured with Core Audio process taps and replayed directly to the chosen output with drift compensation, so latency stays low.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                Button("Open Microphone Settings") {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
                Button("Open Sound Settings") {
                    open("x-apple.systempreferences:com.apple.preference.sound")
                }
            }
            Section("Maintenance") {
                Button("Clean up leftover Audeon devices") {
                    AppRedirectEngine.cleanupLeakedAggregates()
                    store.deviceManager.refresh()
                }
                Text("Removes any private capture devices left behind by an unexpected quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Applies the chosen theme to the whole app.
enum Appearance {
    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }
}

private func open(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
}

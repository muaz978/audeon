import SwiftUI
import AppKit

/// The Settings sheet reached from the menu button, mirroring SoundSource's
/// Settings / Permissions / About entries.
struct SettingsView: View {
    @EnvironmentObject var store: MixerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audeon").font(.headline)
                    Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Group {
                Text("System defaults").font(.subheadline.bold())
                defaultPicker("Output", store.deviceManager.outputs, store.systemAudio.defaultOutputUID) {
                    store.systemAudio.setDefaultOutput($0)
                }
                defaultPicker("Input", store.deviceManager.inputs, store.systemAudio.defaultInputUID) {
                    store.systemAudio.setDefaultInput($0)
                }
                defaultPicker("Sound Effects", store.deviceManager.outputs, store.systemAudio.defaultSystemOutputUID) {
                    store.systemAudio.setDefaultSystemOutput($0)
                }
            }

            Divider()

            Group {
                Text("Permissions").font(.subheadline.bold())
                Text("Audeon needs Microphone access to read input devices, and it captures application audio with Core Audio process taps.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Microphone Settings") {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    }
                    Button("Open Sound Settings") {
                        open("x-apple.systempreferences:com.apple.preference.sound")
                    }
                }
            }

            Divider()

            Group {
                Text("Project").font(.subheadline.bold())
                HStack {
                    Button("Repository") { open("https://github.com/muaz978/audeon") }
                    Button("Releases") { open("https://github.com/muaz978/audeon/releases") }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
    }

    private func defaultPicker(_ label: String, _ devices: [AudioEndpoint], _ selected: String?, _ onSelect: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 100, alignment: .leading)
            Menu(devices.first { $0.uid == selected }?.name ?? "Default") {
                ForEach(devices) { d in Button(d.name) { onSelect(d.uid) } }
            }
            .fixedSize()
            Spacer()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

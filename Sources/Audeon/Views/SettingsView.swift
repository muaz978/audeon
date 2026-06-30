import SwiftUI
import AppKit
import ServiceManagement

/// Tabbed settings, in the spirit of the SoundSource Settings window.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "switch.2") }
            AppearanceTab().tabItem { Label("Appearance", systemImage: "eye") }
            AudioTab().tabItem { Label("Audio", systemImage: "hifispeaker") }
        }
        .frame(width: 460, height: 360)
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

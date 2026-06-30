import SwiftUI
import AppKit
import AVFoundation

/// First-run welcome and permissions screen, in the spirit of SoundSource's
/// System Permissions window.
struct OnboardingView: View {
    @EnvironmentObject var store: MixerStore
    @State private var recheck = false   // toggling re-reads live status

    private var micGranted: Bool {
        _ = recheck
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    private var captureAvailable: Bool {
        if #available(macOS 14.2, *) { return true } else { return false }
    }
    private var blackHoleInstalled: Bool {
        _ = recheck
        return store.deviceManager.outputs.contains { $0.name.localizedCaseInsensitiveContains("blackhole") }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 34))
                Text("Welcome to Audeon").font(.title2.bold())
                Text("Route any device or app to any output. A couple of permissions get the most out of it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            permissionCard(
                icon: "mic.fill", title: "Microphone Access", tag: "Required",
                detail: "Audeon needs Microphone access to read your audio devices and to capture application audio.",
                enabled: micGranted,
                action: micGranted ? nil : { requestMic() }, actionTitle: "Enable")

            permissionCard(
                icon: "waveform", title: "Application Audio Capture", tag: "Required",
                detail: captureAvailable
                    ? "Per-app capture uses Core Audio process taps. No driver to install."
                    : "Per-app capture needs macOS 14.2 or later. The rest of Audeon still works.",
                enabled: captureAvailable, action: nil, actionTitle: "")

            permissionCard(
                icon: "antenna.radiowaves.left.and.right", title: "Virtual Output for OBS", tag: "Optional",
                detail: blackHoleInstalled
                    ? "BlackHole is installed. Route apps to it and select it as a source in OBS, Discord, or Zoom."
                    : "To send audio into OBS, Discord, or Zoom, install the free BlackHole driver, then route apps to it.",
                enabled: blackHoleInstalled,
                action: blackHoleInstalled ? nil : { open("https://existential.audio/blackhole/") },
                actionTitle: "Get BlackHole")

            HStack {
                Button("Recheck") { recheck.toggle(); store.deviceManager.refresh() }
                Spacer()
                Button("Get Started") { NSApplication.shared.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func permissionCard(icon: String, title: String, tag: String, detail: String,
                                enabled: Bool, action: (() -> Void)?, actionTitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(tag).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if enabled {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Enabled").font(.caption).foregroundStyle(.green)
                    } else if let action {
                        Button(actionTitle, action: action).controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }

    private func requestMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { recheck.toggle() } }
        default:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}

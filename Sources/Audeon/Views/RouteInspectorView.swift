import SwiftUI

/// The bottom panel: one strip per active route with volume, mute, a live
/// level meter, and disconnect. This is MIXLINE's "independent volume control
/// per submix" plus one-button monitoring.
struct RouteInspectorView: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("MIXER").font(.caption.bold()).foregroundStyle(.secondary)

                if !store.routes.isEmpty {
                    Button(store.allMuted ? "Unmute All" : "Mute All") {
                        store.toggleMuteAll()
                    }
                    .controlSize(.small)
                    if store.anySolo {
                        Button("Clear Solo") { store.clearSolo() }
                            .controlSize(.small)
                    }
                }

                Spacer()
                if let err = store.router.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if store.routes.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.routes) { route in
                            RouteStrip(route: route)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Click an input, then click an output, to create a route.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RouteStrip: View {
    @EnvironmentObject var store: MixerStore
    let route: Route

    private var inName: String { store.deviceManager.endpoint(forUID: route.inputDeviceUID)?.name ?? "?" }
    private var outName: String { store.deviceManager.endpoint(forUID: route.outputDeviceUID)?.name ?? "?" }
    private var reading: MeterReading { store.router.levels[route.id] ?? .silent }
    private var color: Color { store.color(for: route.inputDeviceUID).color }
    private var dimmed: Bool { route.isMuted || (store.anySolo && !route.isSoloed) }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 2) {
                Text(inName).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                Image(systemName: "arrow.down").font(.system(size: 8)).foregroundStyle(.secondary)
                Text(outName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 110)

            HStack(spacing: 8) {
                meter
                Slider(
                    value: Binding(
                        get: { route.volume },
                        set: { v in store.updateRoute(route.id) { $0.volume = v } }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .frame(width: 70)
            }

            HStack(spacing: 10) {
                Button {
                    store.toggleMute(route.id)
                } label: {
                    Image(systemName: route.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(route.isMuted ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .help(route.isMuted ? "Unmute" : "Mute")

                Button {
                    store.toggleSolo(route.id)
                } label: {
                    Text("S")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(route.isSoloed ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(route.isSoloed ? "Unsolo" : "Solo")

                Button(role: .destructive) {
                    store.removeRoute(route.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Disconnect")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    private var meter: some View {
        VStack(spacing: 3) {
            // Clip indicator: lights red when the signal hit full scale.
            Circle()
                .fill(reading.clip && !dimmed ? Color.red : Color.secondary.opacity(0.25))
                .frame(width: 6, height: 6)

            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(meterColor)
                        .frame(height: geo.size.height * CGFloat(dimmed ? 0 : reading.level))
                }
            }
            .frame(width: 8)
        }
        .frame(width: 14, height: 44)
        .animation(.linear(duration: 0.05), value: reading.level)
    }

    /// Green into the working range, amber as it approaches full scale.
    private var meterColor: Color {
        if reading.peakDB > -3 { return .red }
        if reading.peakDB > -12 { return .orange }
        return color
    }
}

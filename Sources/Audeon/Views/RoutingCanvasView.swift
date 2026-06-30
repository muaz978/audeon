import SwiftUI
import AppKit

/// Reports each pin's center in the shared "canvas" coordinate space.
struct PinFramesKey: PreferenceKey {
    static var defaultValue: [String: CGPoint] = [:]
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The Mixline-style routing canvas: Add input (device or app) on the left, Add
/// output (device) on the right, and drag a pin to an output to connect. Several
/// inputs can connect to one output and one input to several outputs.
struct RoutingCanvasView: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        VStack(spacing: 0) {
            menuBar
            ZStack {
                CableLayer()
                HStack(alignment: .top, spacing: 0) {
                    column(title: "INPUTS") {
                        ForEach(store.inputs) { InputCard(source: $0) }
                        if store.inputs.isEmpty { placeholder("Use Add input to add a device or app.") }
                    }
                    Spacer(minLength: 0)
                    column(title: "OUTPUTS", trailing: true) {
                        ForEach(store.outputs) { OutputCard(output: $0) }
                        if store.outputs.isEmpty { placeholder("Use Add output to add a device.") }
                    }
                }
            }
            .coordinateSpace(name: "canvas")
            .onPreferenceChange(PinFramesKey.self) { store.pinFrames = $0 }
        }
    }

    private func column<C: View>(title: String, trailing: Bool = false, @ViewBuilder content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 12) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                content()
            }
            .padding(16)
        }
        .frame(width: 380)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).padding(.vertical, 8)
    }

    // MARK: - Add menus

    private var menuBar: some View {
        HStack(alignment: .top) {
            addInputMenu.frame(width: 380, alignment: .leading)
            Spacer(minLength: 0)
            addOutputMenu.frame(width: 380, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var addInputMenu: some View {
        Menu {
            let usedDevices = Set(store.inputs.compactMap { if case .device(let u) = $0.kind { return u } else { return nil } })
            let usedApps = Set(store.inputs.compactMap { if case .app(let b) = $0.kind { return b } else { return nil } })
            Section("Audio devices") {
                ForEach(store.deviceManager.inputs.filter { !usedDevices.contains($0.uid) }) { d in
                    Button(d.name) { store.addDeviceInput(uid: d.uid) }
                }
            }
            Section("Applications") {
                ForEach(store.appManager.apps.filter { !usedApps.contains($0.bundleID) }) { app in
                    Button(app.name) { store.addAppInput(bundleID: app.bundleID) }
                }
            }
        } label: {
            Label("Add input", systemImage: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var addOutputMenu: some View {
        Menu {
            let used = Set(store.outputs.map { $0.uid })
            Section("Devices") {
                ForEach(store.deviceManager.outputs.filter { !used.contains($0.uid) }) { d in
                    Button(d.name) { store.addOutput(uid: d.uid) }
                }
            }
        } label: {
            Label("Add output", systemImage: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Cables

private struct CableLayer: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        ZStack {
            ForEach(store.connections) { conn in
                if let source = store.inputs.first(where: { $0.id == conn.sourceID }),
                   let output = store.outputs.first(where: { $0.id == conn.outputID }),
                   let p1 = store.pinFrames[source.pinKey],
                   let p2 = store.pinFrames[output.pinKey] {
                    cable(p1, p2)
                        .stroke(store.color(forPin: source.pinKey).color.opacity(0.9),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            // Live drag cable.
            if let sid = store.dragSourceID,
               let source = store.inputs.first(where: { $0.id == sid }),
               let p1 = store.pinFrames[source.pinKey],
               let p2 = store.dragPoint {
                cable(p1, p2)
                    .stroke(store.color(forPin: source.pinKey).color.opacity(0.6),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 5]))
            }
        }
        .allowsHitTesting(false)
    }

    private func cable(_ p1: CGPoint, _ p2: CGPoint) -> Path {
        var path = Path()
        let dx = (p2.x - p1.x) * 0.5
        path.move(to: p1)
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + dx, y: p1.y),
                      control2: CGPoint(x: p2.x - dx, y: p2.y))
        return path
    }
}

// MARK: - Pin

private struct Pin: View {
    @EnvironmentObject var store: MixerStore
    let key: String
    let color: Color
    var highlighted: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.white.opacity(highlighted ? 1 : 0.7),
                                           lineWidth: highlighted ? 3 : 1.5))
            .background(GeometryReader { g in
                Color.clear.preference(
                    key: PinFramesKey.self,
                    value: [key: CGPoint(x: g.frame(in: .named("canvas")).midX,
                                         y: g.frame(in: .named("canvas")).midY)]
                )
            })
            .contentShape(Rectangle().inset(by: -10))
    }
}

// MARK: - Input card

private struct InputCard: View {
    @EnvironmentObject var store: MixerStore
    let source: InputSource

    private var color: Color { store.color(forPin: source.pinKey).color }
    private var connectedCount: Int { store.connections.filter { $0.sourceID == source.id }.count }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.title(for: source)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(store.subtitle(for: source)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    colorMenu
                    Button { store.removeInput(source.id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
                volumeRow
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))

            pin
        }
    }

    private var icon: some View {
        Group {
            if let img = store.icon(for: source) {
                Image(nsImage: img).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "mic.fill").frame(width: 22, height: 22).foregroundStyle(color)
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Button { store.updateInput(source.id) { $0.isMuted.toggle() } } label: {
                Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(source.isMuted ? .red : .primary)
            }.buttonStyle(.borderless)
            Slider(value: Binding(
                get: { source.volume },
                set: { v in store.updateInput(source.id) { $0.volume = v } }), in: 0...1)
            .controlSize(.small)
            Text("\(Int(source.volume * 100))%")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var colorMenu: some View {
        Menu {
            ForEach(ChannelColor.allCases) { c in
                Button(String(describing: c).capitalized) { store.setColor(c, forPin: source.pinKey) }
            }
        } label: {
            Image(systemName: "paintpalette").font(.system(size: 10)).foregroundStyle(.secondary)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var pin: some View {
        Pin(key: source.pinKey, color: color, highlighted: store.pendingSourceID == source.id || store.dragSourceID == source.id)
            .onTapGesture { store.handleSourcePinTap(source.id) }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
                    .onChanged { v in store.dragSourceID = source.id; store.dragPoint = v.location }
                    .onEnded { v in store.endDrag(at: v.location, from: source.id) }
            )
            .help(connectedCount > 0 ? "\(connectedCount) connected" : "Drag to an output, or click then click an output")
    }
}

// MARK: - Output card

private struct OutputCard: View {
    @EnvironmentObject var store: MixerStore
    let output: OutputTarget

    private var color: Color { store.color(forPin: output.pinKey).color }
    private var name: String { store.deviceManager.endpoint(forUID: output.uid)?.name ?? "Output" }

    var body: some View {
        HStack(spacing: 10) {
            pin
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "hifispeaker.fill").frame(width: 22, height: 22).foregroundStyle(color)
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    colorMenu
                    Button { store.removeOutput(output.id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
                HStack(spacing: 8) {
                    Button { store.updateOutput(output.id) { $0.isMuted.toggle() } } label: {
                        Image(systemName: output.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(output.isMuted ? .red : .primary)
                    }.buttonStyle(.borderless)
                    Slider(value: Binding(
                        get: { output.volume },
                        set: { v in store.updateOutput(output.id) { $0.volume = v } }), in: 0...1)
                    .controlSize(.small)
                    Text("\(Int(output.volume * 100))%")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
        }
    }

    private var colorMenu: some View {
        Menu {
            ForEach(ChannelColor.allCases) { c in
                Button(String(describing: c).capitalized) { store.setColor(c, forPin: output.pinKey) }
            }
        } label: {
            Image(systemName: "paintpalette").font(.system(size: 10)).foregroundStyle(.secondary)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var pin: some View {
        Pin(key: output.pinKey, color: color, highlighted: store.pendingSourceID != nil || store.dragSourceID != nil)
            .onTapGesture { store.handleOutputPinTap(output.id) }
    }
}

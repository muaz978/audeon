import SwiftUI
import AppKit

/// Reports each pin's center in the shared "canvas" coordinate space.
struct PinFramesKey: PreferenceKey {
    static var defaultValue: [String: CGPoint] = [:]
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The Mixline-style routing canvas.
struct RoutingCanvasView: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        VStack(spacing: 0) {
            menuBar
            ZStack {
                CableLayer()
                HStack(alignment: .top, spacing: 0) {
                    column(trailing: false) {
                        ForEach(store.inputs) { source in
                            InputCard(source: source)
                                .transition(.scale.combined(with: .opacity))
                                .opacity(store.draggingCardID == source.id ? 0.5 : 1)
                        }
                        if store.inputs.isEmpty { placeholder("Use Add input to add a device or app.") }
                    }
                    Spacer(minLength: 0)
                    column(trailing: true) {
                        ForEach(store.outputs) { output in
                            OutputCard(output: output)
                                .transition(.scale.combined(with: .opacity))
                                .opacity(store.draggingCardID == output.id ? 0.5 : 1)
                        }
                        if store.outputs.isEmpty { placeholder("Use Add output to add a device.") }
                    }
                }
                ConnectionDeleteControl()
            }
            .coordinateSpace(name: "canvas")
            .onPreferenceChange(PinFramesKey.self) { store.pinFrames = $0 }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.inputs)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.outputs)
            .animation(.easeInOut(duration: 0.2), value: store.connections)
        }
    }

    private func column<C: View>(trailing: Bool, @ViewBuilder content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 12) {
                Text(trailing ? "OUTPUTS" : "INPUTS").font(.caption.bold()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                content()
            }
            .padding(16)
        }
        .frame(width: 400)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).padding(.vertical, 8)
    }

    // MARK: - Add menus

    private var menuBar: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                addInputMenu
                Button {
                    withAnimation { store.hideInactiveApps.toggle() }
                } label: {
                    Image(systemName: store.hideInactiveApps ? "line.3.horizontal.decrease.circle.fill"
                                                             : "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .help("Hide inactive applications")
            }
            .frame(width: 400, alignment: .leading)
            Spacer(minLength: 0)
            addOutputMenu.frame(width: 400, alignment: .trailing)
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
                ForEach(store.appManager.apps.filter { app in
                    !usedApps.contains(app.bundleID) && (!store.hideInactiveApps || app.isActive)
                }) { app in
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

// MARK: - Drag handle for reordering

/// A grip the user drags up or down to reorder a card. Uses the canvas
/// coordinate space and the pin geometry, so it works reliably inside the
/// scrolling columns where system drag and drop does not.
private struct DragHandle: View {
    @EnvironmentObject var store: MixerStore
    let cardID: UUID
    let reorder: (UUID, CGFloat) -> Void

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .help("Drag to reorder")
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        store.draggingCardID = cardID
                        withAnimation(.easeInOut(duration: 0.15)) { reorder(cardID, v.location.y) }
                    }
                    .onEnded { _ in store.draggingCardID = nil }
            )
    }
}

// MARK: - Cables

private struct CableShape: Shape {
    let p1: CGPoint
    let p2: CGPoint
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = (p2.x - p1.x) * 0.5
        path.move(to: p1)
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + dx, y: p1.y),
                      control2: CGPoint(x: p2.x - dx, y: p2.y))
        return path
    }
}

private struct CableLayer: View {
    @EnvironmentObject var store: MixerStore

    var body: some View {
        ZStack {
            ForEach(store.connections) { conn in
                if let source = store.inputs.first(where: { $0.id == conn.sourceID }),
                   let output = store.outputs.first(where: { $0.id == conn.outputID }),
                   let p1 = store.pinFrames[source.pinKey],
                   let p2 = store.pinFrames[output.pinKey] {
                    let selected = store.selectedConnectionID == conn.id
                    let color = store.color(forPin: source.pinKey).color
                    ZStack {
                        CableShape(p1: p1, p2: p2)
                            .stroke(color.opacity(selected ? 1 : 0.9),
                                    style: StrokeStyle(lineWidth: selected ? 5 : 3, lineCap: .round))
                            .shadow(color: color.opacity(0.4), radius: selected ? 4 : 0)
                            .allowsHitTesting(false)
                        CableShape(p1: p1, p2: p2)
                            .stroke(Color.white.opacity(0.001), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                            .contentShape(CableShape(p1: p1, p2: p2).stroke(style: StrokeStyle(lineWidth: 22, lineCap: .round)))
                            .onTapGesture { store.selectedConnectionID = conn.id }
                    }
                }
            }
            if let sid = store.dragSourceID,
               let source = store.inputs.first(where: { $0.id == sid }),
               let p1 = store.pinFrames[source.pinKey],
               let p2 = store.dragPoint {
                CableShape(p1: p1, p2: p2)
                    .stroke(store.color(forPin: source.pinKey).color.opacity(0.6),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 5]))
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ConnectionDeleteControl: View {
    @EnvironmentObject var store: MixerStore
    var body: some View {
        if let id = store.selectedConnectionID,
           let conn = store.connections.first(where: { $0.id == id }),
           let source = store.inputs.first(where: { $0.id == conn.sourceID }),
           let output = store.outputs.first(where: { $0.id == conn.outputID }),
           let p1 = store.pinFrames[source.pinKey],
           let p2 = store.pinFrames[output.pinKey] {
            let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            HStack(spacing: 8) {
                Button(role: .destructive) { store.disconnect(id) } label: { Label("Delete", systemImage: "scissors") }
                Button("Cancel") { store.selectedConnectionID = nil }
            }
            .controlSize(.small)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(radius: 6, y: 2)
            .position(mid)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Pin

private struct Pin: View {
    let key: String
    let color: Color
    var highlighted: Bool = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.white.opacity(highlighted ? 1 : 0.7), lineWidth: highlighted ? 3 : 1.5))
            .scaleEffect(highlighted ? 1.2 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: highlighted)
            .background(GeometryReader { g in
                Color.clear.preference(key: PinFramesKey.self,
                    value: [key: CGPoint(x: g.frame(in: .named("canvas")).midX,
                                         y: g.frame(in: .named("canvas")).midY)])
            })
            .contentShape(Rectangle().inset(by: -10))
    }
}

// MARK: - Input card

private struct InputCard: View {
    @EnvironmentObject var store: MixerStore
    let source: InputSource
    @State private var expanded = false

    private var color: Color { store.color(forPin: source.pinKey).color }
    private var connected: [OutputTarget] { store.connectedOutputs(for: source.id) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if !connected.isEmpty { connectedRow }
                volumeRow
                if expanded { ProcessingPanel(source: source) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.35)))
            .frame(width: 320)

            Pin(key: source.pinKey, color: color,
                highlighted: store.pendingSourceID == source.id || store.dragSourceID == source.id)
                .onTapGesture { store.handleSourcePinTap(source.id) }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
                    .onChanged { v in store.dragSourceID = source.id; store.dragPoint = v.location }
                    .onEnded { v in store.endDrag(at: v.location, from: source.id) })
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            DragHandle(cardID: source.id) { store.reorderInput($0, toNearY: $1) }
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(store.title(for: source)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(connected.isEmpty ? store.subtitle(for: source) : "\(connected.count) output\(connected.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
                    .foregroundStyle(source.eqEnabled || source.boost > 1 ? color : .secondary)
            }.buttonStyle(.borderless).help("EQ and boost")
            colorMenu
            Button { withAnimation { store.removeInput(source.id) } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.borderless)
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

    private var connectedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(connected) { o in
                HStack(spacing: 6) {
                    Circle().fill(store.color(forPin: o.pinKey).color).frame(width: 6, height: 6)
                    Text(store.deviceManager.endpoint(forUID: o.uid)?.name ?? "Output")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { withAnimation { store.disconnect(sourceID: source.id, outputID: o.id) } } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.buttonStyle(.borderless).help("Disconnect this output")
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Button { store.updateInput(source.id) { $0.isMuted.toggle() } } label: {
                Image(systemName: source.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(source.isMuted ? .red : .primary)
            }.buttonStyle(.borderless)
            Slider(value: Binding(get: { source.volume }, set: { v in store.updateInput(source.id) { $0.volume = v } }), in: 0...1)
                .controlSize(.small)
            Text("\(Int(source.volume * 100))%").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    private var colorMenu: some View {
        Menu {
            ForEach(ChannelColor.allCases) { c in
                Button(String(describing: c).capitalized) { store.setColor(c, forPin: source.pinKey) }
            }
        } label: { Image(systemName: "paintpalette").font(.system(size: 10)).foregroundStyle(.secondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - Boost + EQ panel

private struct ProcessingPanel: View {
    @EnvironmentObject var store: MixerStore
    let source: InputSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Text("Boost").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(1...4, id: \.self) { n in
                    Button("\(n)x") { store.setBoost(Double(n), for: source.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: Int(source.boost) == n ? .bold : .regular))
                        .foregroundStyle(Int(source.boost) == n ? store.color(forPin: source.pinKey).color : .secondary)
                }
            }
            HStack {
                Toggle("10-Band EQ", isOn: Binding(get: { source.eqEnabled }, set: { _ in store.toggleEQ(for: source.id) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10, weight: .semibold))
                Spacer()
                Menu("Presets") {
                    ForEach(AudioEQ.presets, id: \.name) { p in
                        Button(p.name) { store.applyEQPreset(p.gains, for: source.id) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 10))
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<AudioEQ.bandCount, id: \.self) { i in
                    VStack(spacing: 2) {
                        VerticalSlider(value: Binding(
                            get: { source.eq.indices.contains(i) ? source.eq[i] : 0 },
                            set: { store.setEQBand(i, $0, for: source.id) }))
                        Text(AudioEQ.shortLabel(forFrequency: AudioEQ.frequencies[i]))
                            .font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(source.eqEnabled ? 1 : 0.4)
            .disabled(!source.eqEnabled)
        }
    }
}

private struct VerticalSlider: View {
    @Binding var value: Double
    var body: some View {
        Slider(value: $value, in: -12...12)
            .controlSize(.mini)
            .frame(width: 78)
            .rotationEffect(.degrees(-90))
            .frame(width: 22, height: 82)
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
            Pin(key: output.pinKey, color: color,
                highlighted: store.pendingSourceID != nil || store.dragSourceID != nil)
                .onTapGesture { store.handleOutputPinTap(output.id) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DragHandle(cardID: output.id) { store.reorderOutput($0, toNearY: $1) }
                    Image(systemName: "hifispeaker.fill").frame(width: 22, height: 22).foregroundStyle(color)
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    colorMenu
                    Button { withAnimation { store.removeOutput(output.id) } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
                HStack(spacing: 8) {
                    Button { store.updateOutput(output.id) { $0.isMuted.toggle() } } label: {
                        Image(systemName: output.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(output.isMuted ? .red : .primary)
                    }.buttonStyle(.borderless)
                    Slider(value: Binding(get: { output.volume }, set: { v in store.updateOutput(output.id) { $0.volume = v } }), in: 0...1)
                        .controlSize(.small)
                    Text("\(Int(output.volume * 100))%").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.35)))
            .frame(width: 320)
        }
    }

    private var colorMenu: some View {
        Menu {
            ForEach(ChannelColor.allCases) { c in
                Button(String(describing: c).capitalized) { store.setColor(c, forPin: output.pinKey) }
            }
        } label: { Image(systemName: "paintpalette").font(.system(size: 10)).foregroundStyle(.secondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

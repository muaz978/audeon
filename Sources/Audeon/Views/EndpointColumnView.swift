import SwiftUI

/// One side of the routing canvas: inputs on the left, outputs on the right.
/// Mirrors MIXLINE's "inputs left / outputs right" layout.
struct EndpointColumnView: View {
    @EnvironmentObject var store: MixerStore
    let kind: EndpointKind

    private var endpoints: [AudioEndpoint] {
        kind == .input ? store.deviceManager.inputs : store.deviceManager.outputs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind == .input ? "INPUTS" : "OUTPUTS")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(endpoints) { endpoint in
                        EndpointCard(endpoint: endpoint)
                    }
                    if endpoints.isEmpty {
                        Text("No \(kind == .input ? "input" : "output") devices found")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

private struct EndpointCard: View {
    @EnvironmentObject var store: MixerStore
    let endpoint: AudioEndpoint

    private var isInput: Bool { endpoint.kind == .input }
    private var color: Color { store.color(for: endpoint.uid).color }

    private var isLinking: Bool { store.linkingFromInput == endpoint.uid }
    private var routeCount: Int {
        isInput ? store.routes(forInput: endpoint.uid).count
                : store.routes(forOutput: endpoint.uid).count
    }

    var body: some View {
        HStack(spacing: 10) {
            if !isInput { connector }   // outputs: dot on the leading edge

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(endpoint.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    colorPicker
                    if routeCount > 0 {
                        Text("\(routeCount) route\(routeCount == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)

            if isInput { connector }    // inputs: dot on the trailing edge
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(isLinking ? 0.28 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(isLinking ? 0.9 : 0.35),
                              lineWidth: isLinking ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { tap() }
    }

    private var connector: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
            .anchorPreference(key: ConnectorAnchorKey.self, value: .center) {
                [endpoint.uid: $0]
            }
            .onTapGesture { tap() }
    }

    private var colorPicker: some View {
        Menu {
            ForEach(ChannelColor.allCases) { c in
                Button {
                    store.setColor(c, for: endpoint.uid)
                } label: {
                    Label(String(describing: c).capitalized, systemImage: "circle.fill")
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func tap() {
        if isInput {
            store.beginLink(fromInput: endpoint.uid)
        } else {
            store.completeLink(toOutput: endpoint.uid)
        }
    }
}

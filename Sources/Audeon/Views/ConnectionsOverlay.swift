import SwiftUI

/// Draws the routing lines between input and output connector dots, the way
/// MIXLINE draws its audio routes across the canvas.
struct ConnectionsOverlay: View {
    @EnvironmentObject var store: MixerStore
    let anchors: [String: Anchor<CGPoint>]
    let proxy: GeometryProxy

    var body: some View {
        ZStack {
            ForEach(store.routes) { route in
                if let from = anchors[route.inputUID],
                   let to = anchors[route.outputUID] {
                    let p1 = proxy[from]
                    let p2 = proxy[to]
                    routePath(p1, p2)
                        .stroke(
                            store.color(for: route.inputDeviceUID).color.opacity(route.isMuted ? 0.25 : 0.9),
                            style: StrokeStyle(lineWidth: route.isMuted ? 1.5 : 2.5,
                                               lineCap: .round,
                                               dash: route.isMuted ? [4, 4] : [])
                        )
                }
            }
        }
    }

    /// A smooth horizontal Bezier between two connector points.
    private func routePath(_ p1: CGPoint, _ p2: CGPoint) -> Path {
        var path = Path()
        let dx = (p2.x - p1.x) * 0.5
        path.move(to: p1)
        path.addCurve(
            to: p2,
            control1: CGPoint(x: p1.x + dx, y: p1.y),
            control2: CGPoint(x: p2.x - dx, y: p2.y)
        )
        return path
    }
}

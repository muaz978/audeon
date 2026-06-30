import Foundation
import SwiftUI
import Combine

/// Top-level app state for the Mixline-style routing canvas: added input sources
/// (devices or apps), added output devices, and the cables between them. Owns the
/// audio engines and keeps them in sync with the graph.
@MainActor
final class MixerStore: ObservableObject {
    @Published var inputs: [InputSource] = [] { didSet { schedulePersist(); applyGraph() } }
    @Published var outputs: [OutputTarget] = [] { didSet { schedulePersist(); applyGraph() } }
    @Published var connections: [Connection] = [] { didSet { schedulePersist(); applyGraph() } }
    @Published var colors: [String: ChannelColor] = [:] { didSet { schedulePersist() } }

    // Transient connect interaction.
    @Published var pendingSourceID: UUID?          // click a source pin, then an output pin
    @Published var dragSourceID: UUID?             // drag in progress from this source
    @Published var dragPoint: CGPoint?             // live drag location, canvas space
    @Published var pinFrames: [String: CGPoint] = [:]   // pinKey -> center in canvas space

    @Published var showSettings: Bool = false

    /// The cable the user clicked, showing its delete control.
    @Published var selectedConnectionID: UUID?

    /// Hide apps that are not currently producing audio, in the Add input list.
    @Published var hideInactiveApps: Bool = false

    /// The card being dragged for reordering.
    @Published var draggingCardID: UUID?

    let deviceManager: AudioDeviceManager
    let router: AudioRouter
    let systemAudio: SystemAudioController
    let appManager: AppAudioManager
    let appRedirectEngine: AppRedirectEngine

    private var persistWork: DispatchWorkItem?
    private let saveURL: URL
    private var cancellables = Set<AnyCancellable>()

    init() {
        let dm = AudioDeviceManager()
        self.deviceManager = dm
        self.router = AudioRouter(deviceManager: dm)
        self.systemAudio = SystemAudioController(deviceManager: dm)
        self.appManager = AppAudioManager()
        self.appRedirectEngine = AppRedirectEngine(deviceManager: dm)
        self.saveURL = Self.defaultSaveURL()
        load()
        applyGraph()

        for child in [dm.objectWillChange.eraseToAnyPublisher(),
                      router.objectWillChange.eraseToAnyPublisher(),
                      systemAudio.objectWillChange.eraseToAnyPublisher(),
                      appManager.objectWillChange.eraseToAnyPublisher(),
                      appRedirectEngine.objectWillChange.eraseToAnyPublisher()] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        // Re-apply when the running app list changes, so an app source activates
        // as soon as its process appears.
        appManager.$apps.sink { [weak self] _ in self?.applyGraph() }.store(in: &cancellables)
    }

    // MARK: - Adding and removing cards

    func addDeviceInput(uid: String) {
        guard !inputs.contains(where: { $0.kind == .device(uid) }) else { return }
        inputs.append(InputSource(kind: .device(uid)))
    }

    func addAppInput(bundleID: String, name: String? = nil) {
        guard !inputs.contains(where: { $0.kind == .app(bundleID) }) else { return }
        inputs.append(InputSource(kind: .app(bundleID), displayName: name))
    }

    /// An app source is active when its process is running; a device source when
    /// the device is present. Inactive cards stay on the canvas and reconnect
    /// automatically when the app reopens or the device returns.
    func isActive(_ source: InputSource) -> Bool {
        switch source.kind {
        case .app(let b): return appManager.apps.contains { $0.bundleID == b }
        case .device(let u): return deviceManager.deviceID(forUID: u) != nil
        }
    }

    /// Inputs to show on the canvas, honoring the hide-inactive filter.
    var visibleInputs: [InputSource] {
        hideInactiveApps ? inputs.filter { isActive($0) } : inputs
    }

    func removeInput(_ id: UUID) {
        inputs.removeAll { $0.id == id }
        connections.removeAll { $0.sourceID == id }
    }

    func addOutput(uid: String) {
        guard !outputs.contains(where: { $0.uid == uid }) else { return }
        outputs.append(OutputTarget(uid: uid))
    }

    func removeOutput(_ id: UUID) {
        outputs.removeAll { $0.id == id }
        connections.removeAll { $0.outputID == id }
    }

    // MARK: - Connections

    func isConnected(sourceID: UUID, outputID: UUID) -> Bool {
        connections.contains { $0.sourceID == sourceID && $0.outputID == outputID }
    }

    func connect(sourceID: UUID, outputID: UUID) {
        guard !isConnected(sourceID: sourceID, outputID: outputID) else { return }
        connections.append(Connection(sourceID: sourceID, outputID: outputID))
    }

    func disconnect(_ id: UUID) {
        connections.removeAll { $0.id == id }
        if selectedConnectionID == id { selectedConnectionID = nil }
    }

    func disconnect(sourceID: UUID, outputID: UUID) {
        connections.removeAll { $0.sourceID == sourceID && $0.outputID == outputID }
    }

    /// The output cards a given source is currently connected to.
    func connectedOutputs(for sourceID: UUID) -> [OutputTarget] {
        let ids = connections.filter { $0.sourceID == sourceID }.map { $0.outputID }
        return outputs.filter { ids.contains($0.id) }
    }

    // MARK: - Reordering (drag)

    func moveInput(id draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let from = inputs.firstIndex(where: { $0.id == draggedID }),
              let to = inputs.firstIndex(where: { $0.id == targetID }) else { return }
        let item = inputs.remove(at: from)
        let insert = inputs.firstIndex(where: { $0.id == targetID }).map { from < to ? $0 + 1 : $0 } ?? to
        inputs.insert(item, at: min(insert, inputs.count))
    }

    func moveOutput(id draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let from = outputs.firstIndex(where: { $0.id == draggedID }),
              let to = outputs.firstIndex(where: { $0.id == targetID }) else { return }
        let item = outputs.remove(at: from)
        let insert = outputs.firstIndex(where: { $0.id == targetID }).map { from < to ? $0 + 1 : $0 } ?? to
        outputs.insert(item, at: min(insert, outputs.count))
    }

    /// Live reorder driven by a drag handle: move the dragged card next to
    /// whichever card's pin is nearest the pointer's vertical position.
    func reorderInput(_ draggedID: UUID, toNearY y: CGFloat) {
        guard let target = inputs
            .filter({ $0.id != draggedID && pinFrames[$0.pinKey] != nil })
            .min(by: { abs((pinFrames[$0.pinKey]!.y) - y) < abs((pinFrames[$1.pinKey]!.y) - y) })
        else { return }
        moveInput(id: draggedID, before: target.id)
    }

    func reorderOutput(_ draggedID: UUID, toNearY y: CGFloat) {
        guard let target = outputs
            .filter({ $0.id != draggedID && pinFrames[$0.pinKey] != nil })
            .min(by: { abs((pinFrames[$0.pinKey]!.y) - y) < abs((pinFrames[$1.pinKey]!.y) - y) })
        else { return }
        moveOutput(id: draggedID, before: target.id)
    }

    // MARK: - EQ and boost

    func setBoost(_ value: Double, for sourceID: UUID) { updateInput(sourceID) { $0.boost = value } }
    func toggleEQ(for sourceID: UUID) { updateInput(sourceID) { $0.eqEnabled.toggle() } }
    func setEQBand(_ index: Int, _ gain: Double, for sourceID: UUID) {
        updateInput(sourceID) { if index < $0.eq.count { $0.eq[index] = gain } }
    }
    func applyEQPreset(_ gains: [Double], for sourceID: UUID) {
        updateInput(sourceID) { $0.eq = gains; $0.eqEnabled = true }
    }

    // MARK: - Per-card controls

    func updateInput(_ id: UUID, _ mutate: (inout InputSource) -> Void) {
        guard let i = inputs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&inputs[i])
    }
    func updateOutput(_ id: UUID, _ mutate: (inout OutputTarget) -> Void) {
        guard let i = outputs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&outputs[i])
    }

    // MARK: - Colors

    func color(forPin key: String) -> ChannelColor {
        colors[key] ?? Self.defaultColor(for: key)
    }
    func setColor(_ c: ChannelColor, forPin key: String) { colors[key] = c }

    // MARK: - Pin geometry and drag connect

    func setPinFrame(_ key: String, _ point: CGPoint) {
        if pinFrames[key] != point { pinFrames[key] = point }
    }

    /// The output card whose pin is nearest the point, within a hit radius.
    func nearestOutput(to point: CGPoint, within radius: CGFloat = 48) -> UUID? {
        var best: (id: UUID, d: CGFloat)?
        for out in outputs {
            guard let p = pinFrames[out.pinKey] else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= radius, best == nil || d < best!.d { best = (out.id, d) }
        }
        return best?.id
    }

    func handleSourcePinTap(_ sourceID: UUID) {
        pendingSourceID = (pendingSourceID == sourceID) ? nil : sourceID
    }

    func handleOutputPinTap(_ outputID: UUID) {
        if let s = pendingSourceID {
            connect(sourceID: s, outputID: outputID)
            pendingSourceID = nil
        }
    }

    func endDrag(at point: CGPoint, from sourceID: UUID) {
        if let outID = nearestOutput(to: point) {
            connect(sourceID: sourceID, outputID: outID)
        }
        dragSourceID = nil
        dragPoint = nil
    }

    // MARK: - Engine

    private func applyGraph() {
        // Device sources drive the AVAudioEngine router; app sources drive taps.
        var routes: [Route] = []
        var taps: [AppTapRequest] = []
        let appByBundle = Dictionary(uniqueKeysWithValues: appManager.apps.map { ($0.bundleID, $0) })

        for conn in connections {
            guard let source = inputs.first(where: { $0.id == conn.sourceID }),
                  let output = outputs.first(where: { $0.id == conn.outputID }) else { continue }
            let gain = source.effectiveGain * (output.isMuted ? 0 : Float(output.volume))

            switch source.kind {
            case .device(let uid):
                routes.append(Route(
                    id: conn.id,
                    inputUID: "input:\(uid)",
                    outputUID: "output:\(output.uid)",
                    volume: Double(gain),
                    isMuted: gain == 0,
                    boost: source.boost,
                    eqEnabled: source.eqEnabled,
                    eq: source.eq
                ))
            case .app(let bundleID):
                guard let app = appByBundle[bundleID] else { continue }
                taps.append(AppTapRequest(
                    bundleID: bundleID,
                    processObject: app.processObject,
                    outputUID: output.uid,
                    volume: gain,
                    boost: source.boost,
                    eqEnabled: source.eqEnabled,
                    eq: source.eq
                ))
            }
        }
        router.apply(routes: routes)
        appRedirectEngine.apply(taps)
    }

    // MARK: - Display helpers

    func title(for source: InputSource) -> String {
        switch source.kind {
        case .device(let uid): return deviceManager.endpoint(forUID: uid)?.name ?? source.displayName ?? "Device"
        case .app(let bundleID):
            return appManager.apps.first { $0.bundleID == bundleID }?.name ?? source.displayName ?? bundleID
        }
    }

    func subtitle(for source: InputSource) -> String {
        if !isActive(source) { return "Inactive" }
        switch source.kind {
        case .device: return "Input device"
        case .app: return "Application"
        }
    }

    func icon(for source: InputSource) -> NSImage? {
        guard case .app(let bundleID) = source.kind else { return nil }
        if let img = appManager.apps.first(where: { $0.bundleID == bundleID })?.icon { return img }
        // Resolve from the installed app bundle so closed apps still show an icon.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var inputs: [InputSource]
        var outputs: [OutputTarget]
        var connections: [Connection]
        var colors: [String: Int]
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persist() {
        let payload = Persisted(
            inputs: inputs, outputs: outputs, connections: connections,
            colors: colors.mapValues { $0.rawValue }
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try FileManager.default.createDirectory(
                at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            NSLog("Audeon: persist failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let payload = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        inputs = payload.inputs
        outputs = payload.outputs
        connections = payload.connections
        colors = payload.colors.compactMapValues { ChannelColor(rawValue: $0) }
    }

    private static func defaultSaveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Audeon/graph.json")
    }

    private static func defaultColor(for key: String) -> ChannelColor {
        ChannelColor.allCases[abs(key.hashValue) % ChannelColor.allCases.count]
    }
}

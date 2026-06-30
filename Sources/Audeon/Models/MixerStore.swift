import Foundation
import SwiftUI
import Combine

/// Top-level app state for the Mixline-style routing canvas: added input sources
/// (devices or apps), added output devices, and the cables between them. Owns the
/// audio engines and keeps them in sync with the graph.
@MainActor
final class MixerStore: ObservableObject {
    /// One shared instance for the whole app. Both the main window and the menu
    /// bar panel use this, so they always observe the same routing graph.
    static let shared = MixerStore()

    @Published var inputs: [InputSource] = [] { didSet { schedulePersist(); applyGraph() } }
    @Published var outputs: [OutputTarget] = [] { didSet { schedulePersist(); applyGraph() } }
    @Published var connections: [Connection] = [] { didSet { schedulePersist(); applyGraph() } }
    @Published var colors: [String: ChannelColor] = [:] { didSet { schedulePersist() } }
    /// Optional friendly names per device uid.
    @Published var deviceNicknames: [String: String] = [:] { didSet { schedulePersist() } }
    /// Saved routing snapshots (Quick Configs / scenes).
    @Published var scenes: [MixScene] = [] { didSet { schedulePersist() } }
    /// Drives the "save scene" name sheet.
    @Published var showSaveSceneSheet: Bool = false

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
        // Re-apply when the default output changes, so "follow output" and the
        // menu bar redirects track it.
        systemAudio.$defaultOutputUID.dropFirst().sink { [weak self] _ in self?.applyGraph() }
            .store(in: &cancellables)
        // Re-establish routes when devices are plugged in or removed.
        deviceManager.$outputs.dropFirst().sink { [weak self] _ in self?.applyGraph() }
            .store(in: &cancellables)
        deviceManager.$inputs.dropFirst().sink { [weak self] _ in self?.applyGraph() }
            .store(in: &cancellables)
    }

    /// Full restart of the audio engines, used after sleep/wake.
    func reapply() {
        router.stopAll()
        appRedirectEngine.stopAll()
        deviceManager.refresh()
        appManager.refresh()
        applyGraph()
    }

    // MARK: - Scenes (Quick Configs)

    func saveScene(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        scenes.append(MixScene(name: n.isEmpty ? "Scene \(scenes.count + 1)" : n,
                            inputs: inputs, outputs: outputs, connections: connections,
                            colors: colors.mapValues { $0.rawValue }))
    }

    func loadScene(_ id: UUID) {
        guard let s = scenes.first(where: { $0.id == id }) else { return }
        // Clear any in-progress pin interaction first: it references ids from
        // the graph that is about to be replaced wholesale, and completing it
        // afterward could create a connection to a source or output that no
        // longer exists in the loaded scene.
        pendingSourceID = nil
        dragSourceID = nil
        dragPoint = nil
        selectedConnectionID = nil
        colors = s.colors.compactMapValues { ChannelColor(rawValue: $0) }
        outputs = s.outputs
        inputs = s.inputs
        connections = s.connections
    }

    func deleteScene(_ id: UUID) { scenes.removeAll { $0.id == id } }
    func requestSaveScene() { showSaveSceneSheet = true }

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
        case .app(let b): return appManager.runningBundleIDs.contains(b)
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
        // A manual connection and "follow system output" are mutually
        // exclusive (applyGraph() only ever honors one). Without this, a
        // source could carry a stale cable on the canvas that looks
        // connected while audio is actually following the system default
        // elsewhere, or vice versa after re-enabling follow mode.
        updateInput(sourceID) { if $0.followsSystemOutput { $0.followsSystemOutput = false } }
    }

    func disconnect(_ id: UUID) {
        connections.removeAll { $0.id == id }
        if selectedConnectionID == id { selectedConnectionID = nil }
    }

    func toggleConnection(sourceID: UUID, outputID: UUID) {
        if isConnected(sourceID: sourceID, outputID: outputID) {
            disconnect(sourceID: sourceID, outputID: outputID)
        } else {
            connect(sourceID: sourceID, outputID: outputID)
        }
    }

    /// Find or create an output card for a device uid.
    @discardableResult
    func ensureOutput(uid: String) -> UUID {
        if let o = outputs.first(where: { $0.uid == uid }) { return o.id }
        let o = OutputTarget(uid: uid)
        outputs.append(o)
        return o.id
    }

    /// Redirect helpers used by the menu bar (route to a hardware device).
    func connectedDeviceUIDs(for sourceID: UUID) -> Set<String> {
        Set(connectedOutputs(for: sourceID).map { $0.uid })
    }

    func toggleRouteToDevice(sourceID: UUID, deviceUID: String) {
        let outID = ensureOutput(uid: deviceUID)
        toggleConnection(sourceID: sourceID, outputID: outID)
    }

    func clearRoutes(for sourceID: UUID) {
        connections.removeAll { $0.sourceID == sourceID }
    }

    func disconnect(sourceID: UUID, outputID: UUID) {
        connections.removeAll { $0.sourceID == sourceID && $0.outputID == outputID }
    }

    /// The output cards a given source is currently connected to.
    func connectedOutputs(for sourceID: UUID) -> [OutputTarget] {
        let ids = connections.filter { $0.sourceID == sourceID }.map { $0.outputID }
        return outputs.filter { ids.contains($0.id) }
    }

    // MARK: - Live meters

    /// Live level for one source, combining every route or tap it feeds. Device
    /// routes are keyed by connection id in AudioRouter; app taps are keyed by
    /// "bundleID|outputUID" in AppRedirectEngine.
    func meterReading(for source: InputSource) -> MeterReading {
        // Following the system output uses a different routing key than a
        // manual connection in both applyGraph() and the two engines: a
        // device route is keyed by the source's own id (no Connection
        // involved), and an app tap is keyed by "bundleID|outputUID" against
        // the current default output. Both must be mirrored here exactly, or
        // a following source reads as permanently silent even while it is
        // actively routing audio.
        if source.followsSystemOutput, let def = systemAudio.defaultOutputUID {
            switch source.kind {
            case .device: return router.levels[source.id] ?? .silent
            case .app(let bundleID): return appRedirectEngine.levels["\(bundleID)|\(def)"] ?? .silent
            }
        }
        switch source.kind {
        case .device:
            let ids = connections.filter { $0.sourceID == source.id }.map { $0.id }
            return AudioMeter.combine(ids.compactMap { router.levels[$0] })
        case .app(let bundleID):
            let outs = connectedOutputs(for: source.id).map { $0.uid }
            let keys = outs.map { "\(bundleID)|\($0)" }
            return AudioMeter.combine(keys.compactMap { appRedirectEngine.levels[$0] })
        }
    }

    /// Live level for one output, combining every source feeding it. Mirrors
    /// the same follow-mode routing key as meterReading(for source:) above.
    func meterReading(for output: OutputTarget) -> MeterReading {
        var readings: [MeterReading] = []
        // Manually connected device routes: keyed by Connection id.
        for conn in connections where conn.outputID == output.id {
            if let r = router.levels[conn.id] { readings.append(r) }
        }
        for source in inputs {
            let connectedToThis = source.followsSystemOutput
                ? systemAudio.defaultOutputUID == output.uid
                : connections.contains { $0.sourceID == source.id && $0.outputID == output.id }
            guard connectedToThis else { continue }
            switch source.kind {
            case .device:
                // A non-following device route was already counted above via
                // its Connection id; only the follow-mode case (keyed by the
                // source's own id, no Connection involved) needs this lookup.
                if source.followsSystemOutput, let r = router.levels[source.id] { readings.append(r) }
            case .app(let bundleID):
                if let r = appRedirectEngine.levels["\(bundleID)|\(output.uid)"] { readings.append(r) }
            }
        }
        return AudioMeter.combine(readings)
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

    /// Live reorder driven by a drag handle. The target index is the number of
    /// other cards whose pin sits above the pointer, which is stable as the
    /// pointer moves (no oscillation or flicker between adjacent slots).
    func reorderInput(_ draggedID: UUID, toNearY y: CGFloat) {
        let others = inputs.filter { $0.id != draggedID }
        let targetIndex = others.filter { (pinFrames[$0.pinKey]?.y ?? .greatestFiniteMagnitude) < y }.count
        guard let from = inputs.firstIndex(where: { $0.id == draggedID }) else { return }
        var arr = inputs
        let item = arr.remove(at: from)
        arr.insert(item, at: min(targetIndex, arr.count))
        if arr != inputs { inputs = arr }
    }

    func reorderOutput(_ draggedID: UUID, toNearY y: CGFloat) {
        let others = outputs.filter { $0.id != draggedID }
        let targetIndex = others.filter { (pinFrames[$0.pinKey]?.y ?? .greatestFiniteMagnitude) < y }.count
        guard let from = outputs.firstIndex(where: { $0.id == draggedID }) else { return }
        var arr = outputs
        let item = arr.remove(at: from)
        arr.insert(item, at: min(targetIndex, arr.count))
        if arr != outputs { outputs = arr }
    }

    // MARK: - EQ and boost

    /// Friendly display name for a device, using a nickname when set.
    func deviceName(forUID uid: String) -> String {
        if let nick = deviceNicknames[uid], !nick.isEmpty { return nick }
        return deviceManager.endpoint(forUID: uid)?.name ?? "Unknown"
    }

    func setNickname(_ name: String, forUID uid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { deviceNicknames[uid] = nil } else { deviceNicknames[uid] = trimmed }
    }

    func toggleFavorite(_ sourceID: UUID) { updateInput(sourceID) { $0.isFavorite.toggle() } }
    func toggleFollowOutput(_ sourceID: UUID) {
        var nowFollowing = false
        updateInput(sourceID) { $0.followsSystemOutput.toggle(); nowFollowing = $0.followsSystemOutput }
        // See the matching note in connect(sourceID:outputID:): keep manual
        // connections and follow mode mutually exclusive, so the canvas never
        // shows a cable that is not where audio is actually going.
        if nowFollowing { clearRoutes(for: sourceID) }
    }

    /// Inputs with favorites first (used by the menu bar list).
    var inputsFavoritesFirst: [InputSource] {
        inputs.enumerated().sorted {
            if $0.element.isFavorite != $1.element.isFavorite { return $0.element.isFavorite }
            return $0.offset < $1.offset
        }.map { $0.element }
    }

    func setBoost(_ value: Double, for sourceID: UUID) { updateInput(sourceID) { $0.boost = value } }
    func toggleEQ(for sourceID: UUID) { updateInput(sourceID) { $0.eqEnabled.toggle() } }
    func setEQBand(_ index: Int, _ gain: Double, for sourceID: UUID) {
        updateInput(sourceID) { if index < $0.eq.count { $0.eq[index] = gain } }
    }
    func applyEQPreset(_ gains: [Double], for sourceID: UUID) {
        updateInput(sourceID) { $0.eq = gains; $0.eqEnabled = true }
    }
    func toggleMagicBoost(for sourceID: UUID) { updateInput(sourceID) { $0.magicBoost.toggle() } }

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

        func addTarget(_ source: InputSource, outputUID: String, outputVolume: Float, routeID: UUID) {
            let gain = source.effectiveGain * outputVolume
            switch source.kind {
            case .device(let uid):
                routes.append(Route(id: routeID, inputUID: "input:\(uid)", outputUID: "output:\(outputUID)",
                                    volume: Double(gain), isMuted: gain == 0, boost: source.boost,
                                    eqEnabled: source.eqEnabled, eq: source.eq, magicBoost: source.magicBoost))
            case .app(let bundleID):
                guard let app = appByBundle[bundleID] else { return }
                taps.append(AppTapRequest(bundleID: bundleID, processObject: app.processObject,
                                          outputUID: outputUID, volume: gain, boost: source.boost,
                                          eqEnabled: source.eqEnabled, eq: source.eq, magicBoost: source.magicBoost))
            }
        }

        for source in inputs {
            if source.followsSystemOutput, let def = systemAudio.defaultOutputUID {
                // Auto-route to whatever the system default output currently is.
                addTarget(source, outputUID: def, outputVolume: 1, routeID: source.id)
            } else {
                for conn in connections where conn.sourceID == source.id {
                    guard let output = outputs.first(where: { $0.id == conn.outputID }) else { continue }
                    addTarget(source, outputUID: output.uid,
                              outputVolume: output.isMuted ? 0 : Float(output.volume), routeID: conn.id)
                }
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
        if source.followsSystemOutput { return "Following system output" }
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
        var deviceNicknames: [String: String]?
        var scenes: [MixScene]?
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
            colors: colors.mapValues { $0.rawValue },
            deviceNicknames: deviceNicknames,
            scenes: scenes
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
        deviceNicknames = payload.deviceNicknames ?? [:]
        scenes = payload.scenes ?? []
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

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
    /// Optional SF Symbol name per device uid, chosen in Settings > Devices.
    @Published var customDeviceIcons: [String: String] = [:] { didSet { schedulePersist() } }
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
    /// Holds the virtual sink at unity gain while system audio capture is on.
    private lazy var sinkGuard = SinkGuard(deviceManager: deviceManager)

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
        adoptSystemAudioStateOnLaunch()
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
        // A sink that enumerates after launch (USB interface, driver just
        // installed) still gets adopted; the guard inside makes this a no-op
        // once the bridge is known to be on.
        deviceManager.$outputs.dropFirst().sink { [weak self] _ in
            self?.adoptSystemAudioStateOnLaunch()
        }.store(in: &cancellables)
    }

    /// Remove private aggregate devices left behind by an unexpected quit.
    ///
    /// Live engines are stopped first and the graph rebuilt afterwards. The
    /// cleanup helpers destroy every Audeon-prefixed aggregate they find,
    /// including the ones currently carrying audio, so calling them underneath
    /// running routes cut those routes dead and stranded their I/O procs --
    /// and the button's own description invites the user to press it while
    /// routes are live.
    func cleanUpLeftoverDevices() {
        router.stopAll()
        appRedirectEngine.stopAll()
        AppRedirectEngine.cleanupLeakedAggregates()
        AudioRouter.cleanupLeakedAggregates()
        deviceManager.refresh()
        applyGraph()
    }

    /// `isEffectivelySilent` performs synchronous CoreAudio property reads, and
    /// the routing canvas asks for it from inside a SwiftUI body that
    /// re-evaluates on every meter tick — thirty HAL round-trips a second, per
    /// output card, on the main thread. Memoized briefly: still responsive,
    /// roughly an order of magnitude fewer reads.
    func isHardwareSilent(uid: String) -> Bool {
        if let hit = silenceCache[uid], Date().timeIntervalSince(hit.at) < 0.25 { return hit.value }
        let value = deviceManager.isEffectivelySilent(forUID: uid)
        silenceCache[uid] = (value, Date())
        return value
    }

    private var silenceCache: [String: (value: Bool, at: Date)] = [:]

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

    // MARK: - System Audio bridge (MixLine/Voicemeeter-style)

    /// True while whole-system audio is being captured through the virtual sink.
    @Published private(set) var systemAudioActive = false
    /// The real output that was the system default before we redirected it, so
    /// turning the bridge off restores exactly what the user had. Persisted:
    /// an abnormal quit used to lose it, leaving the restore paths guessing.
    private var previousDefaultOutputUID: String?

    /// Surfaced when the bridge could not be turned off, or the saved graph
    /// could not be read. Nil when there is nothing to report.
    @Published var systemAudioError: String?
    @Published var loadError: String?

    /// Whether a capture sink (Audeon virtual device or BlackHole) is available.
    var systemAudioSinkAvailable: Bool { deviceManager.systemAudioSinkUID != nil }

    /// Set the virtual sink as the system default output, so everything the Mac
    /// plays lands in it, and bring it into Audeon as one labeled "System Audio"
    /// input ready to route to any real output. The user then connects that
    /// card to their speakers or headphones on the canvas.
    func enableSystemAudioCapture(label: String = "System Audio") {
        guard let sink = deviceManager.systemAudioSinkUID else { return }
        // Remember the real output we are replacing (never remember the sink
        // itself, or turning the bridge off would restore silence).
        if let current = systemAudio.defaultOutputUID, !deviceManager.isVirtualSystemAudio(current) {
            previousDefaultOutputUID = current
            schedulePersist()
        }
        guard systemAudio.setDefaultOutput(sink) else {
            systemAudioError = "Could not make \(deviceManager.endpoint(forUID: sink)?.name ?? "the capture device") the system output."
            return
        }
        systemAudioError = nil
        if !inputs.contains(where: { $0.kind == .device(sink) }) {
            inputs.append(InputSource(kind: .device(sink), displayName: label))
        }
        setNickname(label, forUID: sink)

        // One-click: route System Audio straight to the speakers the user was
        // already using, so sound keeps playing through Audeon immediately.
        // They can add more outputs afterward on the canvas.
        if let source = inputs.first(where: { $0.kind == .device(sink) }),
           let prev = previousDefaultOutputUID {
            let outputID = ensureOutput(uid: prev)
            if !isConnected(sourceID: source.id, outputID: outputID) {
                connect(sourceID: source.id, outputID: outputID)
            }
        }
        // The sink's driver-level volume and mute scale the audio it stores.
        // Pin them at unity and keep them there, or a volume key press while
        // the sink is the default output silences the entire capture.
        sinkGuard.activate(uid: sink)
        systemAudioActive = true
    }

    /// Called on launch: if the system default output is still the virtual sink
    /// and the System Audio card exists, a previous session left the bridge on
    /// (or quit unexpectedly). Reflect that in the UI state so the menu offers
    /// "Stop capturing" instead of pretending the bridge is off.
    /// Safe to call repeatedly: it adopts at most once, and only once the
    /// device list actually contains the sink. `AudioDeviceManager.refresh()`
    /// now publishes inline on the main thread, so the call from `init()`
    /// sees a populated map instead of the empty one that made this
    /// unreachable; the re-attempt on later device lists covers a sink that
    /// enumerates after launch.
    func adoptSystemAudioStateOnLaunch() {
        guard !systemAudioActive,
              let sink = deviceManager.systemAudioSinkUID,
              systemAudio.defaultOutputUID == sink,
              inputs.contains(where: { $0.kind == .device(sink) }) else { return }
        sinkGuard.activate(uid: sink)
        systemAudioActive = true
    }

    /// Every uid that could plausibly take over as the system default, best
    /// first. Each is checked against the live device map, so the list never
    /// contains the capture sink, a synthetic Output Group uid, or a device
    /// that has been unplugged since we remembered it -- all three make
    /// `setDefaultOutput` a silent no-op that strands the Mac on the sink.
    private func restoreCandidates() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ uid: String?) {
            guard let uid, deviceManager.isUsableOutput(uid), seen.insert(uid).inserted else { return }
            result.append(uid)
        }
        add(previousDefaultOutputUID)
        for output in outputs where output.groupMembers == nil { add(output.uid) }
        for output in outputs { for member in output.groupMembers ?? [] { add(member) } }
        for device in deviceManager.outputs { add(device.uid) }
        return result
    }

    /// Try each candidate until CoreAudio actually accepts one.
    @discardableResult
    private func restoreSystemOutput() -> Bool {
        for uid in restoreCandidates() where systemAudio.setDefaultOutput(uid) { return true }
        return false
    }

    /// Called when the app is quitting. With Audeon gone nothing drains the
    /// virtual sink, so leaving it as the system default would silence the
    /// whole Mac. Point the default back at a real output; keep the card and
    /// connections so the setup is one click away next launch.
    func restoreSystemOutputForQuit() {
        guard systemAudioActive else { return }
        if !restoreSystemOutput() {
            NSLog("Audeon: no usable output to restore on quit; system default left unchanged")
        }
    }

    /// Stop capturing system audio: restore the previous default output and
    /// remove the System Audio card.
    func disableSystemAudioCapture() {
        sinkGuard.deactivate()
        guard restoreSystemOutput() else {
            // Tearing the card down here would leave the Mac outputting to the
            // sink while the UI insists nothing is capturing, with no way back
            // inside the app. Keep the bridge marked active and say so.
            if let sink = deviceManager.systemAudioSinkUID { sinkGuard.activate(uid: sink) }
            systemAudioError = "Could not switch the system output back to a real device. Pick one in System Settings > Sound, then try again."
            return
        }
        systemAudioError = nil
        if let sink = deviceManager.systemAudioSinkUID,
           let source = inputs.first(where: { $0.kind == .device(sink) }) {
            removeInput(source.id)
        }
        systemAudioActive = false
    }

    /// Backwards-compatible wrapper used by the onboarding screen.
    @discardableResult
    func captureSystemAudio(usingOutputNamed nameContains: String = "blackhole",
                            label: String = "System Audio") -> Bool {
        guard systemAudioSinkAvailable else { return false }
        enableSystemAudioCapture(label: label)
        return true
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

    /// Create a named Output Group card that fans out to several devices.
    func addOutputGroup(name: String, memberUIDs: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let members = memberUIDs.filter { deviceManager.endpoint(forUID: $0) != nil }
        guard !members.isEmpty else { return }
        let groupID = UUID()
        outputs.append(OutputTarget(
            id: groupID,
            uid: "group:\(groupID.uuidString)",
            groupName: trimmed.isEmpty ? "Output Group" : trimmed,
            groupMembers: members))
    }

    /// Display name for an output card: nickname or device name for devices,
    /// the group's own name for groups.
    func outputDisplayName(_ output: OutputTarget) -> String {
        if let name = output.groupName { return name }
        return deviceName(forUID: output.uid)
    }

    /// Play a short test tone through an output card's device (or through
    /// every member of a group), bypassing the routing graph. Separates "the
    /// device cannot make sound" from "the route is not working" by ear.
    func playTestTone(for output: OutputTarget) {
        let uids = output.groupMembers ?? [output.uid]
        for uid in uids {
            if let id = deviceManager.deviceID(forUID: uid) {
                TestTonePlayer.shared.play(deviceID: id)
            }
        }
    }

    /// SF Symbol options offered in Settings for a device's custom icon.
    static let deviceIconChoices = [
        "hifispeaker.fill", "speaker.wave.2.fill", "headphones", "mic.fill",
        "earbuds", "airpodspro", "display", "tv", "gamecontroller.fill", "music.note"
    ]

    /// The SF Symbol to show for a device: the user's choice, or a default.
    func deviceIcon(forUID uid: String) -> String {
        customDeviceIcons[uid] ?? "hifispeaker.fill"
    }

    func setDeviceIcon(_ symbol: String?, forUID uid: String) {
        customDeviceIcons[uid] = symbol
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
    /// Expanded to real devices: an Output Group is one card but several
    /// destinations, and collapsing it to its own synthetic uid made the menu
    /// bar report "1 device" for a source playing to four.
    func connectedDeviceUIDs(for sourceID: UUID) -> Set<String> {
        var uids = Set<String>()
        for output in connectedOutputs(for: sourceID) {
            if let members = output.groupMembers { uids.formUnion(members) } else { uids.insert(output.uid) }
        }
        return uids
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
            // A connection to an Output Group is carried by one derived route
            // per member, not by the connection id itself. Looking only at
            // conn.id found no level and every group-routed source metered as
            // permanently silent while it was actually playing.
            let ids = connections.filter { $0.sourceID == source.id }.flatMap { conn -> [UUID] in
                guard let output = outputs.first(where: { $0.id == conn.outputID }),
                      let members = output.groupMembers else { return [conn.id] }
                return members.indices.map { Self.derivedRouteID(from: conn.id, index: $0) }
            }
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
        // Only cards actually on screen have a pin frame. Counting the hidden
        // ones gave a target index into the visible column but an insertion
        // index into the full array, so with "Hide inactive" on every downward
        // drag resolved to the same slot and appeared to do nothing. Anchor to
        // the last visible card above the pointer instead.
        let visible = visibleInputs.filter { $0.id != draggedID }
        let above = visible.filter { (pinFrames[$0.pinKey]?.y ?? .greatestFiniteMagnitude) < y }
        guard let from = inputs.firstIndex(where: { $0.id == draggedID }) else { return }
        var arr = inputs
        let item = arr.remove(at: from)
        let insert = above.last.flatMap { anchor in
            arr.firstIndex(where: { $0.id == anchor.id }).map { $0 + 1 }
        } ?? 0
        arr.insert(item, at: min(insert, arr.count))
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

        // A device reachable both as its own output card and as a member of a
        // connected group would otherwise get two independent engines feeding
        // it the same source, doubling the signal into that device.
        var claimed = Set<String>()

        func addTarget(_ source: InputSource, outputUID: String, outputVolume: Float, routeID: UUID) {
            let gain = source.effectiveGain * outputVolume
            guard claimed.insert("\(source.id)|\(outputUID)").inserted else { return }
            switch source.kind {
            case .device(let uid):
                routes.append(Route(id: routeID, inputUID: "input:\(uid)", outputUID: "output:\(outputUID)",
                                    volume: Double(gain), isMuted: gain == 0, boost: source.boost,
                                    eqEnabled: source.eqEnabled, eq: source.eq, magicBoost: source.magicBoost))
            case .app(let bundleID):
                guard let app = appByBundle[bundleID], !app.processObjects.isEmpty else { return }
                taps.append(AppTapRequest(bundleID: bundleID, processObjects: app.processObjects,
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
                    let outVolume: Float = output.isMuted ? 0 : Float(output.volume)
                    if let members = output.groupMembers {
                        // A group fans one connection out to every member
                        // device, each with its own stable derived route id.
                        for (idx, member) in members.enumerated() {
                            addTarget(source, outputUID: member, outputVolume: outVolume,
                                      routeID: Self.derivedRouteID(from: conn.id, index: idx))
                        }
                    } else {
                        addTarget(source, outputUID: output.uid,
                                  outputVolume: outVolume, routeID: conn.id)
                    }
                }
            }
        }
        router.apply(routes: routes)
        appRedirectEngine.apply(taps)
        attachRecorders()
    }

    // MARK: - Recording

    /// Sources currently being recorded to a file.
    @Published private(set) var recordingSourceIDs: Set<UUID> = []
    private var recorders: [UUID: MixRecorder] = [:]

    static var recordingsFolder: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Audeon Recordings")
    }

    func isRecording(_ sourceID: UUID) -> Bool { recordingSourceIDs.contains(sourceID) }

    /// A source can be recorded while at least one live route carries it.
    func canRecord(_ source: InputSource) -> Bool {
        source.followsSystemOutput || connections.contains { $0.sourceID == source.id }
    }

    func toggleRecording(for sourceID: UUID) {
        if let recorder = recorders[sourceID] {
            recorder.finish()
            recorders[sourceID] = nil
            recordingSourceIDs.remove(sourceID)
            attachRecorders()   // clears the now-dead slot mapping
        } else {
            guard let source = inputs.first(where: { $0.id == sourceID }), canRecord(source) else { return }
            try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let filename = "\(title(for: source)) \(formatter.string(from: Date())).caf"
            let recorder = MixRecorder(url: Self.recordingsFolder.appendingPathComponent(filename))
            recorder.start()
            recorders[sourceID] = recorder
            recordingSourceIDs.insert(sourceID)
            attachRecorders()
        }
    }

    /// Close every open recording file (used when the app quits).
    func stopAllRecordings() {
        for (_, recorder) in recorders { recorder.finish() }
        recorders.removeAll()
        recordingSourceIDs.removeAll()
    }

    func revealRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    /// Mount each active recorder on whichever engine currently carries its
    /// source. Runs after every reconciliation, because engines are rebuilt
    /// there; the recorder object survives and keeps appending to one file.
    private func attachRecorders() {
        // A source removed, or replaced by loading a scene, while it was
        // recording used to leave its recorder mounted on an engine that no
        // longer exists: the file stopped growing with no indication, the id
        // stuck in recordingSourceIDs forever, and the user could start a
        // second recording they had no way to stop.
        let live = Set(inputs.map(\.id))
        for (id, recorder) in recorders where !live.contains(id) {
            recorder.finish()
            recorders[id] = nil
            recordingSourceIDs.remove(id)
        }

        for source in inputs {
            let recorder = recorders[source.id]   // nil detaches
            switch source.kind {
            case .device:
                let routeID: UUID?
                if source.followsSystemOutput {
                    routeID = source.id
                } else if let conn = connections.first(where: { $0.sourceID == source.id }) {
                    if let out = outputs.first(where: { $0.id == conn.outputID }),
                       let members = out.groupMembers {
                        // Mount on the first member that actually has a live
                        // engine. Always taking member 0 silently dropped the
                        // whole recording whenever that member was unplugged,
                        // even though the group was still playing elsewhere.
                        routeID = members.indices
                            .map { Self.derivedRouteID(from: conn.id, index: $0) }
                            .first { router.hasEngine(routeID: $0) }
                    } else {
                        routeID = conn.id
                    }
                } else {
                    routeID = nil
                }
                if let routeID { router.setRecorder(routeID: routeID, recorder) }
            case .app(let bundleID):
                let outputUID: String?
                if source.followsSystemOutput {
                    outputUID = systemAudio.defaultOutputUID
                } else if let conn = connections.first(where: { $0.sourceID == source.id }),
                          let out = outputs.first(where: { $0.id == conn.outputID }) {
                    outputUID = out.groupMembers?.first ?? out.uid
                } else {
                    outputUID = nil
                }
                if let outputUID {
                    appRedirectEngine.setRecorder(bundleID: bundleID, outputUID: outputUID, recorder)
                }
            }
        }
    }

    /// Stable per-member route id for group fan-out: the connection id with the
    /// member index folded into the last bytes, so reconciliation reuses the
    /// same engines across applies instead of rebuilding them every time.
    private static func derivedRouteID(from base: UUID, index: Int) -> UUID {
        var bytes = base.uuid
        bytes.14 = bytes.14 &+ UInt8(truncatingIfNeeded: index &+ 1)
        bytes.15 = bytes.15 &+ UInt8(truncatingIfNeeded: (index &+ 1) &* 31)
        return UUID(uuid: bytes)
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

    /// Resolved app icons keyed by bundle id. Published so every card refreshes
    /// the moment an icon becomes available: NSRunningApplication.icon is
    /// loaded lazily by AppKit and never invalidates SwiftUI on its own, which
    /// left freshly added cards iconless until a click forced a re-render.
    @Published private var appIcons: [String: NSImage] = [:]
    /// Bundle ids with no resolvable icon. Without this the lookup was
    /// re-dispatched from every SwiftUI body evaluation, forever.
    private var iconLookupFailed: Set<String> = []

    func icon(for source: InputSource) -> NSImage? {
        guard case .app(let bundleID) = source.kind else { return nil }
        if let cached = appIcons[bundleID] { return cached }
        guard !iconLookupFailed.contains(bundleID) else { return nil }
        resolveIcon(bundleID)
        return nil
    }

    /// Resolve an icon once, off the current view update (mutating published
    /// state while SwiftUI evaluates a body is not allowed), then cache it.
    private func resolveIcon(_ bundleID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.appIcons[bundleID] == nil,
                  !self.iconLookupFailed.contains(bundleID) else { return }
            // The installed bundle lookup is deterministic and works for
            // closed apps too; the running-app icon is only a fallback.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                self.appIcons[bundleID] = NSWorkspace.shared.icon(forFile: url.path)
            } else if let img = self.appManager.apps.first(where: { $0.bundleID == bundleID })?.icon {
                self.appIcons[bundleID] = img
            } else {
                // Nothing to find. Remember that, or every future body
                // evaluation queues the same failing lookup again.
                self.iconLookupFailed.insert(bundleID)
            }
        }
    }

    // MARK: - Persistence

    /// Bumped when the shape of `Persisted` changes incompatibly.
    private static let schemaVersion = 1

    private struct Persisted: Codable {
        var version: Int?
        var previousDefaultOutputUID: String?
        var inputs: [InputSource]
        var outputs: [OutputTarget]
        var connections: [Connection]
        var colors: [String: Int]
        var deviceNicknames: [String: String]?
        var scenes: [MixScene]?
        var customDeviceIcons: [String: String]?
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Write any debounced changes out now. The 0.4 s persist debounce was
    /// simply dropped when the app terminated, so a burst of graph edits made
    /// just before Cmd-Q was lost entirely.
    func flushPendingWrites() {
        persistWork?.cancel()
        persistWork = nil
        persist()
    }

    private func persist() {
        let payload = Persisted(
            version: Self.schemaVersion,
            previousDefaultOutputUID: previousDefaultOutputUID,
            inputs: inputs, outputs: outputs, connections: connections,
            colors: colors.mapValues { $0.rawValue },
            deviceNicknames: deviceNicknames,
            scenes: scenes,
            customDeviceIcons: customDeviceIcons
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
        // No file at all is simply a first run.
        guard let data = try? Data(contentsOf: saveURL) else { return }
        let payload: Persisted
        do {
            payload = try JSONDecoder().decode(Persisted.self, from: data)
        } catch {
            // Starting from an empty graph and letting the next edit overwrite
            // the file destroyed the user's setup silently. Set the unreadable
            // copy aside instead, and say so.
            let backup = saveURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: saveURL, to: backup)
            NSLog("Audeon: could not read graph.json (%@); kept it as %@",
                  error.localizedDescription, backup.lastPathComponent)
            loadError = "Your saved setup could not be read. The old file was kept as \(backup.lastPathComponent) and Audeon started with an empty graph."
            return
        }
        if let version = payload.version, version > Self.schemaVersion {
            loadError = "This setup was saved by a newer version of Audeon. Some settings may be missing."
        }
        previousDefaultOutputUID = payload.previousDefaultOutputUID
        inputs = payload.inputs
        outputs = payload.outputs
        connections = payload.connections
        colors = payload.colors.compactMapValues { ChannelColor(rawValue: $0) }
        deviceNicknames = payload.deviceNicknames ?? [:]
        scenes = payload.scenes ?? []
        customDeviceIcons = payload.customDeviceIcons ?? [:]
    }

    private static func defaultSaveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Audeon/graph.json")
    }

    /// Swift re-seeds `String.hashValue` on every process launch, so deriving
    /// the default from it repainted every un-customized card and cable each
    /// time the app started. FNV-1a over the key's bytes is stable across runs.
    private static func stableHash(_ key: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { h = (h ^ UInt64(byte)) &* 0x1000_0000_01b3 }
        return h
    }

    private static func defaultColor(for key: String) -> ChannelColor {
        ChannelColor.allCases[Int(stableHash(key) % UInt64(ChannelColor.allCases.count))]
    }
}

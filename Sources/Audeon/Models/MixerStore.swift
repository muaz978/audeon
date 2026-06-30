import Foundation
import SwiftUI
import Combine

/// Which workspace the main window is showing.
enum AppMode: String, CaseIterable, Identifiable {
    case apps = "Apps & System"
    case routing = "Device Routing"
    var id: String { rawValue }
}

/// Top-level app state: the routing matrix, channel colors, presets, and
/// persistence. Owns the AudioRouter and pushes changes into it.
@MainActor
final class MixerStore: ObservableObject {
    @Published var routes: [Route] = [] { didSet { schedulePersist(); applyToEngine() } }
    @Published var colors: [String: ChannelColor] = [:] { didSet { schedulePersist() } }
    @Published var presets: [Preset] = [] { didSet { schedulePersist() } }

    /// Per-application volume and redirect settings, keyed by bundle id.
    @Published var appRedirects: [String: AppRedirect] = [:] { didSet { schedulePersist(); applyApps() } }

    /// The current main-window workspace.
    @Published var mode: AppMode = .apps

    /// The input endpoint currently waiting to be connected (click-to-connect).
    @Published var linkingFromInput: String?

    /// Drives the "save preset" sheet from the menu / shortcut.
    @Published var showSavePresetSheet: Bool = false

    /// Drives the Settings sheet.
    @Published var showSettings: Bool = false

    func requestSavePreset() { showSavePresetSheet = true }

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
        applyToEngine()
        applyApps()

        // Views observe this store, but live data lives in these nested objects.
        // Forward their change notifications so the UI refreshes.
        for child in [dm.objectWillChange.eraseToAnyPublisher(),
                      router.objectWillChange.eraseToAnyPublisher(),
                      systemAudio.objectWillChange.eraseToAnyPublisher(),
                      appManager.objectWillChange.eraseToAnyPublisher(),
                      appRedirectEngine.objectWillChange.eraseToAnyPublisher()] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // Re-apply per-app redirects when the app list or default output changes,
        // so a stored redirect activates as soon as its app appears.
        appManager.$apps
            .sink { [weak self] _ in self?.applyApps() }
            .store(in: &cancellables)
        systemAudio.$defaultOutputUID
            .sink { [weak self] _ in self?.applyApps() }
            .store(in: &cancellables)
    }

    // MARK: - Routing intents

    func color(for uid: String) -> ChannelColor {
        colors[uid] ?? Self.defaultColor(for: uid)
    }

    func setColor(_ color: ChannelColor, for uid: String) {
        colors[uid] = color
    }

    /// Begin or complete a click-to-connect gesture from an input dot.
    func beginLink(fromInput uid: String) {
        linkingFromInput = (linkingFromInput == uid) ? nil : uid
    }

    /// Complete a link to an output, if one is in progress.
    func completeLink(toOutput uid: String) {
        guard let inputUID = linkingFromInput else { return }
        linkingFromInput = nil
        addRoute(inputUID: inputUID, outputUID: uid)
    }

    func addRoute(inputUID: String, outputUID: String) {
        // Avoid duplicate edges.
        guard !routes.contains(where: { $0.inputUID == inputUID && $0.outputUID == outputUID }) else { return }
        routes.append(Route(inputUID: inputUID, outputUID: outputUID))
    }

    func removeRoute(_ id: UUID) {
        routes.removeAll { $0.id == id }
    }

    func updateRoute(_ id: UUID, _ mutate: (inout Route) -> Void) {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&routes[idx])
    }

    func routes(forInput uid: String) -> [Route] { routes.filter { $0.inputUID == uid } }
    func routes(forOutput uid: String) -> [Route] { routes.filter { $0.outputUID == uid } }

    // MARK: - Master controls

    var anySolo: Bool { routes.contains { $0.isSoloed && !$0.isMuted } }
    var allMuted: Bool { !routes.isEmpty && routes.allSatisfy { $0.isMuted } }

    func toggleMute(_ id: UUID) { updateRoute(id) { $0.isMuted.toggle() } }

    func toggleSolo(_ id: UUID) { updateRoute(id) { $0.isSoloed.toggle() } }

    func muteAll() { for i in routes.indices { routes[i].isMuted = true } }

    func unmuteAll() { for i in routes.indices { routes[i].isMuted = false } }

    func clearSolo() { for i in routes.indices { routes[i].isSoloed = false } }

    /// One master toggle for the menu bar: mute everything, or restore.
    func toggleMuteAll() { allMuted ? unmuteAll() : muteAll() }

    // MARK: - Presets

    func saveCurrentAsPreset(named name: String) {
        let colorDict = colors.mapValues { $0.rawValue }
        presets.append(Preset(name: name, routes: routes, colors: colorDict))
    }

    func loadPreset(_ preset: Preset) {
        colors = preset.colors.compactMapValues { ChannelColor(rawValue: $0) }
        routes = preset.routes
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
    }

    // MARK: - Per-app controls

    func redirect(for bundleID: String) -> AppRedirect {
        appRedirects[bundleID] ?? AppRedirect(bundleID: bundleID)
    }

    func setAppVolume(_ volume: Double, for bundleID: String) {
        var r = redirect(for: bundleID)
        r.volume = max(0, min(1, volume))
        store(r)
    }

    /// Pass nil to follow the system default output ("No Redirect").
    func setAppOutput(_ uid: String?, for bundleID: String) {
        var r = redirect(for: bundleID)
        r.outputUID = uid
        store(r)
    }

    private func store(_ r: AppRedirect) {
        if r.outputUID == nil && r.volume >= 0.999 {
            appRedirects[r.bundleID] = nil   // back to default, no interception
        } else {
            appRedirects[r.bundleID] = r
        }
    }

    // MARK: - Engine

    private func applyToEngine() {
        router.apply(routes: routes)
    }

    private func applyApps() {
        appRedirectEngine.apply(
            redirects: Array(appRedirects.values),
            apps: appManager.apps,
            defaultOutputUID: systemAudio.defaultOutputUID
        )
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var routes: [Route]
        var colors: [String: Int]
        var presets: [Preset]
        var appRedirects: [String: AppRedirect]?
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persist() {
        let payload = Persisted(
            routes: routes,
            colors: colors.mapValues { $0.rawValue },
            presets: presets,
            appRedirects: appRedirects
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
        routes = payload.routes
        colors = payload.colors.compactMapValues { ChannelColor(rawValue: $0) }
        presets = payload.presets
        appRedirects = payload.appRedirects ?? [:]
    }

    private static func defaultSaveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Audeon/config.json")
    }

    /// Deterministic default color so endpoints look stable before customizing.
    private static func defaultColor(for uid: String) -> ChannelColor {
        let idx = abs(uid.hashValue) % ChannelColor.allCases.count
        return ChannelColor.allCases[idx]
    }
}

import Foundation
import Combine
import CoreAudio
import FireTVIPC

/// HID input → button identification → layer resolution → action execution.
/// Also the observable model for the GUI.
public final class RemoteController: ObservableObject {
    @Published public private(set) var config: Config
    @Published public private(set) var hidStatus: HIDMonitor.Status = .stopped
    @Published public private(set) var activeLayers: [Int] = [0]
    @Published public private(set) var lastPressed: RemoteButton?
    @Published public private(set) var lastRawReport: String = "—"
    @Published public private(set) var lastUnknownCode: ButtonCode?
    @Published public private(set) var pressedNow: Set<RemoteButton> = []
    @Published public private(set) var log: [String] = []
    @Published public private(set) var executing: [String] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var shortcutNames: [String] = []
    @Published public private(set) var shortcutsLoadError: String?
    @Published public private(set) var shortcutsLoading = false
    @Published public private(set) var saveError: String?
    @Published public private(set) var startupNotices: [String] = []

    /// When set, the next unknown press is bound to this button (learn mode).
    @Published public var learningButton: RemoteButton?

    public let store: ConfigStore
    public let monitor: HIDMonitor
    public let helper = HelperClient()
    public let shortcuts: ShortcutsService
    public let executor: ActionExecutor
    public let engine: LayerEngine
    public let passthrough = PassthroughEmitter()
    private let tracker = ButtonStateTracker()
    /// True while reports come from the privileged helper (device seized → every button remappable).
    @Published public private(set) var exclusiveActive = false
    public var exclusiveRequested: Bool { config.ui.exclusiveCapture ?? false }
    /// Code of each held button, so passthrough release works even after bindings change.
    private var heldCodes: [RemoteButton: ButtonCode] = [:]
    private var exclusiveRetries = 0

    // MARK: microphone (push-to-talk into the virtual input device)
    public let mic = MicAudioEngine()
    public enum MicState: Equatable { case disabled, ready, listening, draining }
    @Published public private(set) var micState: MicState = .disabled
    @Published public private(set) var micLevel: Float = 0
    @Published public private(set) var micStats = MicAudioEngine.Stats()
    @Published public private(set) var micLastError: String?
    public var micEnabled: Bool { config.ui.micEnabled ?? true }
    private static let micButtonCode = ButtonCode(reportID: 0x02, code: 0x0221)
    private static let micAudioReport: UInt8 = 0xF0
    private static let micControlReport: UInt8 = 0xF2
    public static let driverPath = "/Library/Audio/Plug-Ins/HAL/FireTVRemoteMicrophone.driver"
    public static let deviceUID = "FireTVRemoteMicrophone_UID"
    private var saveWork: DispatchWorkItem?

    public init(store: ConfigStore = ConfigStore(url: ConfigStore.defaultURL),
                monitor: HIDMonitor = HIDMonitor(),
                shortcuts: ShortcutsService = ShortcutsService()) {
        self.store = store
        self.monitor = monitor
        self.shortcuts = shortcuts
        self.executor = ActionExecutor(shortcuts: shortcuts)

        var notices: [String] = []
        let loaded: Config
        switch store.load() {
        case .loaded(let c): loaded = c
        case .missing:
            let names = (try? shortcuts.list()) ?? []
            loaded = Config.makeDefault(existingShortcuts: names)
            if names.contains("FireTV-A1") { notices.append(String(localized: "Migrated existing FireTV-A1–A4 shortcuts to Layer 0")) }
        case .corrupted(let err, let q):
            loaded = Config.makeDefault(existingShortcuts: (try? shortcuts.list()) ?? [])
            notices.append(String(localized: "Started with defaults because config file was corrupted (\(err.localizedDescription))") + (q.map { String(localized: ". Source file:\($0.lastPathComponent)") } ?? ""))
        }
        config = loaded
        startupNotices = notices
        engine = LayerEngine(layers: loaded.layers, defaultLayer: loaded.defaultLayer)
        activeLayers = engine.activeLayers

        executor.macroLookup = { [weak self] id in self?.config.macros.first { $0.id == id } }
        executor.onEvent = { [weak self] e in self?.handleExecutor(e) }
        monitor.onEvent = { [weak self] e in self?.handleMonitor(e) }
        helper.onEvent = { [weak self] e in self?.handleMonitor(e) }
        if !notices.isEmpty { try? store.save(loaded) }
        refreshShortcuts()
        mic.onStats = { [weak self] st, state in
            guard let self else { return }
            self.micStats = st; self.micLevel = st.level
            if self.micEnabled { self.micState = state == .active ? .listening : (state == .draining ? .draining : .ready) }
        }
        if micEnabled { mic.prepare(); micState = .ready }
        if config.ui.monitoringEnabled { startSource() }
    }

    public func setMicEnabled(_ on: Bool) {
        mutate { $0.ui.micEnabled = on }
        if on { mic.prepare(); micState = .ready } else { if micState == .listening { sendMicEnable(false) }; mic.stop(); micState = .disabled }
    }
    /// Is the HAL driver bundle installed?
    public static var micDriverInstalled: Bool { FileManager.default.fileExists(atPath: driverPath + "/Contents/MacOS/FireTVRemoteMicrophone") }
    /// Is "Fire TV Remote Microphone" currently published by coreaudiod?
    public static var micDevicePresent: Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            // CoreAudio returns a +1 CFString here. Keeping it in `Unmanaged`
            // avoids both the raw-pointer warning and leaking the string.
            var uid: Unmanaged<CFString>?
            var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &sz, &uid) == noErr,
               let uid, (uid.takeRetainedValue() as String) == deviceUID { return true }
        }
        return false
    }
    private func sendMicEnable(_ on: Bool) {
        let payload: [UInt8] = [Self.micControlReport, on ? 0x01 : 0x00]
        if exclusiveActive {
            helper.setOutputReport(id: Self.micControlReport, data: payload) { [weak self] r in
                if r != 0 { self?.micLastError = String(format: String(localized: "Microphone control command failed (0x%08x)"), UInt32(bitPattern: r)); self?.appendLog(String(localized: "mic enable(\(on ? "on" : "off")) failed 0x\(String(UInt32(bitPattern: r), radix: 16))")) }
                else { self?.micLastError = nil }
            }
        } else {
            let r = monitor.setOutputReport(id: Self.micControlReport, data: payload)
            if r != kIOReturnSuccess { micLastError = String(format: String(localized: "Microphone control command failed (0x%08x)"), UInt32(bitPattern: r)); appendLog(String(localized: "mic enable(\(on ? "on" : "off")) failed 0x\(String(UInt32(bitPattern: r), radix: 16))")) }
            else { micLastError = nil }
        }
    }

    // MARK: input source (in-process vs privileged helper)

    private func startSource() {
        if exclusiveRequested && HelperClient.installState == .enabled {
            monitor.stop()
            exclusiveActive = true
            helper.start()
        } else {
            helper.stop()
            exclusiveActive = false
            monitor.start()
            if exclusiveRequested { appendLog(String(localized: "Exclusive mode unavailable (helper not approved); monitoring in normal mode")) }
        }
    }
    private func stopSource() {
        helper.stop(); monitor.stop()
        exclusiveActive = false
        releaseAll()
    }
    /// Turn exclusive capture on/off (persisted). Restarts the input source.
    public func setExclusive(_ on: Bool) {
        mutate { $0.ui.exclusiveCapture = on }
        if config.ui.monitoringEnabled { stopSource(); startSource() }
    }
    public var isMonitoring: Bool { monitor.isRunning || helper.isRunning }

    /// The connected remote's model, in normal or exclusive mode.
    public var connectedModel: FireTVRemoteModel? {
        if let m = monitor.connectedModel { return m }
        // In exclusive mode the helper only reports a status string; it sends
        // the same friendly model name used below.
        if case .connected(let name) = hidStatus {
            return FireTVRemoteModel.all.first { $0.name == name }
        }
        return nil
    }
    public var connectedProductID: Int? { monitor.connectedProductID ?? connectedModel?.productID }

    // MARK: config mutation (autosaved)

    public func mutate(_ f: (inout Config) -> Void) {
        var c = config
        f(&c)
        let issues = c.validateAndRepair()
        for i in issues { appendLog(String(localized: "Config repaired: \(i.message)")) }
        config = c
        engine.update(layers: c.layers, defaultLayer: c.defaultLayer)
        activeLayers = engine.activeLayers
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
    public func saveNow() {
        do { try store.save(config); saveError = nil } catch { saveError = error.localizedDescription; appendLog(String(localized: "Save failed: \(error.localizedDescription)")) }
    }

    public func assign(_ action: Action, to b: RemoteButton, layer: Int) {
        mutate { c in guard c.layers.indices.contains(layer) else { return }; c.layers[layer].bindings[b] = action }
    }
    public func clear(_ b: RemoteButton, layer: Int) {
        mutate { c in guard c.layers.indices.contains(layer) else { return }; c.layers[layer].bindings.removeValue(forKey: b) }
    }
    public func resetToDefaults() {
        mutate { c in c = Config.makeDefault(existingShortcuts: shortcutNames); c.ui = config.ui }
        appendLog(String(localized: "Reset to defaults"))
    }
    public func importConfig(from data: Data) throws {
        let c = try ConfigCodec.decode(data)
        mutate { $0 = c }
        appendLog(String(localized: "Config imported"))
    }
    public func exportConfig() throws -> Data { try ConfigCodec.encode(config) }

    public func setMonitoring(_ on: Bool) {
        mutate { $0.ui.monitoringEnabled = on }
        if on { startSource() } else { stopSource() }
    }

    // MARK: shortcuts

    public func refreshShortcuts() {
        shortcutsLoading = true
        shortcuts.listAsync { [weak self] r in
            DispatchQueue.main.async {
                guard let self else { return }
                self.shortcutsLoading = false
                switch r {
                case .success(let names): self.shortcutNames = names; self.shortcutsLoadError = nil
                case .failure(let e): self.shortcutsLoadError = e.localizedDescription; self.shortcutNames = []
                }
            }
        }
    }

    /// Shortcut names referenced by any binding that no longer exist.
    public var missingShortcuts: Set<String> {
        guard shortcutsLoadError == nil, !shortcutNames.isEmpty else { return [] }
        var used = Set<String>()
        for l in config.layers { for (_, a) in l.bindings { if case .shortcut(let n) = a { used.insert(n) } } }
        for m in config.macros { for s in m.steps { if case .shortcut(let n) = s.action { used.insert(n) } } }
        return used.subtracting(shortcutNames)
    }

    // MARK: button identification

    public func info(for b: RemoteButton) -> ButtonInfo { ButtonTable.info(for: b, learned: config.learnedCodes, exclusive: exclusiveActive) }

    public func button(for code: ButtonCode) -> RemoteButton? {
        if let b = config.learnedCodes.first(where: { $0.value.matches(code) })?.key { return b }
        return ButtonTable.knownCodes.first(where: { $0.value.matches(code) })?.key
    }
    /// The original macOS behaviour of a button (what "Default Behavior" re-emits in exclusive mode).
    public func defaultBehavior(of b: RemoteButton) -> String? {
        guard let c = info(for: b).code else { return nil }
        if c.reportID == ButtonTable.vendorReport { return nil }
        return PassthroughEmitter.mapping(for: c)?.label
    }

    // MARK: event plumbing

    private func handleMonitor(_ e: HIDMonitor.Event) {
        switch e {
        case .status(let s):
            hidStatus = s
            if case .connected = s {} else { releaseAll() }
            if case .blocked = s, exclusiveActive, !helper.isRunning {
                // helper died, refused, or was replaced: fall back so the remote is never left dead,
                // then try to return to exclusive mode a few times.
                appendLog(String(localized: "Exclusive mode stopped; switching to normal mode"))
                exclusiveActive = false
                monitor.start()
                if exclusiveRetries < 3 {
                    exclusiveRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        guard let self, self.config.ui.monitoringEnabled, self.exclusiveRequested, !self.exclusiveActive else { return }
                        self.appendLog(String(localized: "Attempting to return to exclusive mode (\(String(self.exclusiveRetries))/3)"))
                        self.startSource()
                    }
                }
            }
            if case .connected = s, exclusiveActive { exclusiveRetries = 0 }
        case .log(let s): appendLog(s)
        case .report(let rid, let bytes):
            if rid == Self.micAudioReport {
                var payload = bytes[...]
                if payload.first == rid { payload = payload.dropFirst() }
                mic.push(packet: Array(payload))
                return
            }
            lastRawReport = String(format: "id=0x%02x ", rid) + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            if config.ui.debugLog { appendLog(String(localized: "report \(lastRawReport)")) }
            for t in tracker.feed(decodeReport(reportID: rid, bytes: bytes)) {
                switch t {
                case .press(let code): press(code)
                case .release(let code): release(code)
                }
            }
        }
    }

    /// Public so tests and the GUI can inject synthetic reports.
    public func inject(reportID: UInt8, bytes: [UInt8]) { handleMonitor(.report(reportID: reportID, bytes: bytes)) }

    private func press(_ code: ButtonCode) {
        if micEnabled, Self.micButtonCode.matches(code) {
            // Push-to-talk: ask the remote to stream voice while the mic key is held.
            mic.start(); sendMicEnable(true)
        }
        if let learn = learningButton, button(for: code) == nil || learn != button(for: code) {
            mutate { $0.learnedCodes[learn] = code }
            learningButton = nil
            appendLog(String(localized: "Learned: \(learn.displayName) = \(String(describing: code))"))
            return
        }
        guard let b = button(for: code) else {
            lastUnknownCode = code
            appendLog(String(localized: "Unknown button \(String(describing: code))"))
            return
        }
        lastPressed = b
        pressedNow.insert(b)
        heldCodes[b] = code
        let info = info(for: b)
        guard info.restriction == .none else { return }   // not seized: macOS already handles it, never double-fire
        apply(engine.press(b), button: b)
    }

    private func release(_ code: ButtonCode) {
        if micEnabled, Self.micButtonCode.matches(code) { sendMicEnable(false); mic.stop() }
        guard let b = button(for: code) else { return }
        pressedNow.remove(b)
        apply(engine.release(b), button: b)
        heldCodes.removeValue(forKey: b)
    }

    private func releaseAll() {
        if micState == .listening { sendMicEnable(false); mic.stop() }
        _ = tracker.reset()
        pressedNow = []
        passthrough.releaseAll()
        apply(engine.releaseAll(), button: nil)
        executor.releaseAllKeys()
        heldCodes = [:]
    }

    private func apply(_ effects: [LayerEngine.Effect], button: RemoteButton?) {
        for e in effects {
            switch e {
            case .execute(.passthrough):
                // Device is seized in exclusive mode: reproduce the original key ourselves.
                if exclusiveActive, let b = button, let c = heldCodes[b] { passthrough.press(c) }
            case .execute(.key(let combo)):
                // Hold semantics: the key stays down until the remote button is released.
                executor.keyDown(combo)
            case .execute(.media(let m)):
                executor.mediaDown(m)
            case .execute(let a): executor.execute(a)
            case .release(.media(let m)):
                executor.mediaUp(m)
            case .release(.passthrough):
                if let b = button, let c = heldCodes[b] { passthrough.release(c) }
            case .release(.key(let combo)):
                executor.keyUp(combo)
            case .release: break
            case .layerStateChanged: activeLayers = engine.activeLayers
            case .defaultLayerChanged(let n):
                mutate { $0.defaultLayer = n }
                appendLog(String(localized: "Default layer changed to \(String(n))"))
            }
        }
    }

    private func handleExecutor(_ e: ActionExecutor.Event) {
        switch e {
        case .started(let s): executing.append(s); appendLog(String(localized: "Started: \(s)"))
        case .finished(let s): executing.removeAll { $0 == s }; appendLog(String(localized: "Finished: \(s)"))
        case .failed(let s, let why): executing.removeAll { $0 == s }; lastError = "\(s): \(why)"; appendLog(String(localized: "Failed: \(s) — \(why)"))
        }
    }

    public func clearError() { lastError = nil }

    private func appendLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(s)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    public func shutdown() {
        if micState == .listening { sendMicEnable(false) }
        mic.shutdown()
        passthrough.releaseAll()
        executor.releaseAllKeys()
        helper.stop()
        monitor.stop()
        saveWork?.cancel()
        saveNow()
    }
}

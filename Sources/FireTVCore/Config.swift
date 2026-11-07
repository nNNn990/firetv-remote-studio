import Foundation

public struct Layer: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var bindings: [RemoteButton: Action]
    public init(id: UUID = UUID(), name: String, bindings: [RemoteButton: Action] = [:]) {
        self.id = id; self.name = name; self.bindings = bindings
    }
    /// Binding for a button; unset means transparent on upper layers.
    public func action(for b: RemoteButton) -> Action { bindings[b] ?? .transparent }
}

public struct UISettings: Codable, Hashable {
    public var monitoringEnabled = true
    public var showOSHandledButtons = true
    public var debugLog = false
    /// Seize the remote through the privileged helper so every button can be remapped. Optional for older config files.
    public var exclusiveCapture: Bool? = nil
    /// Push-to-talk microphone into the virtual "Fire TV Remote Microphone" device. nil = enabled.
    public var micEnabled: Bool? = nil
    public init() {}
}

public struct Config: Codable, Hashable {
    public static let currentVersion = 1
    public var version = Config.currentVersion
    public var layers: [Layer]
    public var defaultLayer: Int
    public var macros: [Macro]
    public var learnedCodes: [RemoteButton: ButtonCode]
    public var ui: UISettings

    public init(layers: [Layer], defaultLayer: Int = 0, macros: [Macro] = [], learnedCodes: [RemoteButton: ButtonCode] = [:], ui: UISettings = UISettings()) {
        self.layers = layers; self.defaultLayer = defaultLayer; self.macros = macros; self.learnedCodes = learnedCodes; self.ui = ui
    }

    /// Fresh config: Layer 0..3. If `existingShortcuts` contains the legacy
    /// FireTV-A1..A4 shortcuts, A1..A4 on layer 0 are migrated to them.
    public static func makeDefault(existingShortcuts: [String] = []) -> Config {
        var base = Layer(name: "Layer 0")
        let legacy: [(RemoteButton, String)] = [(.a1, "FireTV-A1"), (.a2, "FireTV-A2"), (.a3, "FireTV-A3"), (.a4, "FireTV-A4")]
        for (b, name) in legacy where existingShortcuts.contains(name) { base.bindings[b] = .shortcut(name: name) }
        return Config(layers: [base, Layer(name: "Layer 1"), Layer(name: "Layer 2"), Layer(name: "Layer 3")])
    }

    // MARK: validation

    public struct Issue: Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Repairs what can be repaired and returns a description of each change.
    @discardableResult
    public mutating func validateAndRepair() -> [Issue] {
        var issues: [Issue] = []
        if layers.isEmpty { layers = [Layer(name: "Layer 0")]; issues.append(Issue(message: String(localized: "Layer 0 was created because the layer was empty"))) }
        if !(0..<layers.count).contains(defaultLayer) { defaultLayer = 0; issues.append(Issue(message: String(localized: "Default layer out of range; reset to 0"))) }
        let macroIDs = Set(macros.map(\.id))
        for li in layers.indices {
            for (b, a) in layers[li].bindings {
                switch a {
                case .layer(let op) where !(0..<layers.count).contains(op.layer):
                    layers[li].bindings[b] = Action.none
                    issues.append(Issue(message: String(localized: "Clear \(layers[li].name) \(b.displayName): layer \(String(op.layer)) does not exist")))
                case .macro(let id) where !macroIDs.contains(id):
                    layers[li].bindings[b] = Action.none
                    issues.append(Issue(message: String(localized: "\(b.displayName) in \(layers[li].name): macro does not exist")))
                default: break
                }
            }
            // Layer 0 cannot be transparent — there is nothing below it; treat as unset.
            if li == 0 { for (b, a) in layers[0].bindings where a.isTransparent { layers[0].bindings.removeValue(forKey: b) } }
        }
        return issues
    }

    // MARK: layer editing helpers (keep layer-index references consistent)

    public mutating func addLayer() -> Int {
        layers.append(Layer(name: "Layer \(layers.count)"))
        return layers.count - 1
    }
    public mutating func duplicateLayer(_ i: Int) -> Int? {
        guard layers.indices.contains(i) else { return nil }
        var copy = layers[i]; copy.id = UUID(); copy.name += String(localized: " (Copy)")
        layers.append(copy)
        return layers.count - 1
    }
    /// Removes a layer (never layer 0). References to it become `none`; higher references shift down.
    public mutating func removeLayer(_ i: Int) -> Bool {
        guard i > 0, layers.indices.contains(i) else { return false }
        layers.remove(at: i)
        if defaultLayer == i { defaultLayer = 0 } else if defaultLayer > i { defaultLayer -= 1 }
        for li in layers.indices {
            for (b, a) in layers[li].bindings {
                guard case .layer(let op) = a else { continue }
                if op.layer == i { layers[li].bindings[b] = Action.none }
                else if op.layer > i {
                    let n = op.layer - 1
                    let newOp: LayerOp
                    switch op {
                    case .momentary: newOp = .momentary(n)
                    case .toggle: newOp = .toggle(n)
                    case .switchTo: newOp = .switchTo(n)
                    case .setDefault: newOp = .setDefault(n)
                    }
                    layers[li].bindings[b] = .layer(newOp)
                }
            }
        }
        return true
    }
    public mutating func resetLayer(_ i: Int) { guard layers.indices.contains(i) else { return }; layers[i].bindings = [:] }
}

// MARK: - Codec

public enum ConfigCodec {
    public static func encode(_ c: Config) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(c)
    }
    public static func decode(_ d: Data) throws -> Config {
        var c = try JSONDecoder().decode(Config.self, from: d)
        c.validateAndRepair()
        return c
    }
}

/// JSON file store with atomic writes and quarantine of corrupted files.
public final class ConfigStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FireTVRemoteBridge/config.json")
    }

    public enum LoadResult { case loaded(Config), missing, corrupted(Error, quarantinedTo: URL?) }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .loaded(try ConfigCodec.decode(try Data(contentsOf: url)))
        } catch {
            let q = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            let moved = (try? FileManager.default.moveItem(at: url, to: q)) != nil
            return .corrupted(error, quarantinedTo: moved ? q : nil)
        }
    }

    public func save(_ c: Config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigCodec.encode(c).write(to: url, options: .atomic)
    }
}

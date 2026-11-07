import Foundation

public struct KeyCombo: Codable, Hashable {
    public var keyCode: UInt16          // macOS virtual key code
    public var keyName: String          // display name, e.g. "C"
    public var command = false, shift = false, option = false, control = false
    /// Function (Fn) modifier: e.g. Fn+F3 sends a real function key rather than
    /// the media key macOS maps to the same physical key.
    public var function = false
    /// Send only the selected modifiers and no regular key. Meant for hold
    /// actions: while the remote button is down the modifiers stay down.
    public var modifierOnly = false
    public init(keyCode: UInt16, keyName: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, function: Bool = false, modifierOnly: Bool = false) {
        self.keyCode = keyCode; self.keyName = keyName
        self.command = command; self.shift = shift; self.option = option; self.control = control
        self.function = function; self.modifierOnly = modifierOnly
    }
    /// Selected modifier symbols in Apple's order (fn ⌃⌥⇧⌘).
    public var modifierSymbols: String {
        var s = ""
        if function { s += "fn " }
        if control { s += "⌃" }; if option { s += "⌥" }; if shift { s += "⇧" }; if command { s += "⌘" }
        return s
    }
    public var display: String {
        if modifierOnly {
            let m = modifierSymbols.trimmingCharacters(in: .whitespaces)
            return m.isEmpty ? "Modifier" : m
        }
        return modifierSymbols + keyName
    }

    // Custom Codable so configs written before `function` / `modifierOnly` existed still decode.
    private enum CodingKeys: String, CodingKey {
        case keyCode, keyName, command, shift, option, control, function, modifierOnly
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        keyName = try c.decode(String.self, forKey: .keyName)
        command = try c.decodeIfPresent(Bool.self, forKey: .command) ?? false
        shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        option = try c.decodeIfPresent(Bool.self, forKey: .option) ?? false
        control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
        function = try c.decodeIfPresent(Bool.self, forKey: .function) ?? false
        modifierOnly = try c.decodeIfPresent(Bool.self, forKey: .modifierOnly) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(keyName, forKey: .keyName)
        try c.encode(command, forKey: .command)
        try c.encode(shift, forKey: .shift)
        try c.encode(option, forKey: .option)
        try c.encode(control, forKey: .control)
        try c.encode(function, forKey: .function)
        try c.encode(modifierOnly, forKey: .modifierOnly)
    }
}

public enum MediaKey: String, Codable, CaseIterable, Hashable {
    case playPause, next, previous, fastForward, rewind, volumeUp, volumeDown, mute
    public var displayName: String {
        switch self {
        case .playPause: return String(localized: "Play/Pause")
        case .next: return String(localized: "Next")
        case .previous: return String(localized: "Previous")
        case .fastForward: return String(localized: "Fast Forward")
        case .rewind: return String(localized: "Rewind")
        case .volumeUp: return String(localized: "Volume Up")
        case .volumeDown: return String(localized: "Volume Down")
        case .mute: return String(localized: "Mute")
        }
    }
    /// NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h
    public var nxKeyType: Int32 {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        case .fastForward: return 19
        case .rewind: return 20
        }
    }
}

public enum LayerOp: Codable, Hashable {
    case momentary(Int)   // MO(n)
    case toggle(Int)      // TG(n)
    case switchTo(Int)    // TO(n)
    case setDefault(Int)  // DF(n)
    public var layer: Int {
        switch self { case .momentary(let n), .toggle(let n), .switchTo(let n), .setDefault(let n): return n }
    }
    public var display: String {
        switch self {
        case .momentary(let n): return "MO(\(n))"
        case .toggle(let n): return "TG(\(n))"
        case .switchTo(let n): return "TO(\(n))"
        case .setDefault(let n): return "DF(\(n))"
        }
    }
}

public struct MacroStep: Codable, Hashable, Identifiable {
    public var id: UUID
    public var action: Action
    public var delayMs: Int      // delay *after* this step
    public init(id: UUID = UUID(), action: Action, delayMs: Int = 0) { self.id = id; self.action = action; self.delayMs = delayMs }
}

public struct Macro: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var steps: [MacroStep]
    public init(id: UUID = UUID(), name: String, steps: [MacroStep] = []) { self.id = id; self.name = name; self.steps = steps }
}

/// What a button does. `transparent` falls through to lower layers; `none` stops.
public indirect enum Action: Codable, Hashable {
    case none
    case transparent
    /// Keep the button's original (macOS default) behaviour. Only meaningful in exclusive mode,
    /// where the app re-emits the original key; otherwise identical to "unset".
    case passthrough
    case shortcut(name: String)
    case key(KeyCombo)
    case launchApp(path: String, name: String)
    case openURL(String)
    case media(MediaKey)
    case layer(LayerOp)
    case macro(id: UUID)

    public var display: String {
        switch self {
        case .none: return String(localized: "Disabled")
        case .transparent: return "▽"
        case .passthrough: return String(localized: "Default Behavior")
        case .shortcut(let n): return "⌘⇧ " + n
        case .key(let k): return k.display
        case .launchApp(_, let name): return String(localized: "Launch: \(name)")
        case .openURL(let u): return String(localized: "URL: \(u)")
        case .media(let m): return m.displayName
        case .layer(let op): return op.display
        case .macro: return String(localized: "Macro")
        }
    }
    public var isTransparent: Bool { if case .transparent = self { return true }; return false }
    public var layerOp: LayerOp? { if case .layer(let op) = self { return op }; return nil }
}

import Foundation
import AppKit

/// Re-emits a seized button's original macOS behaviour (keyboard key or media key),
/// including OS-style auto-repeat while held. Only used in exclusive mode.
public final class PassthroughEmitter {
    public struct Mapping: Equatable { public let label: String; let kind: Kind }
    enum Kind: Equatable { case key(CGKeyCode), media(Int32), none }

    /// HID keyboard-page usage → macOS virtual key code.
    static let keyboardUsages: [UInt16: (CGKeyCode, String)] = [
        0x28: (36, "Return"), 0x29: (53, "Esc"), 0x2A: (51, "Delete"), 0x2B: (48, "Tab"), 0x2C: (49, "Space"),
        0x4A: (115, "Home"), 0x4B: (116, "PgUp"), 0x4C: (117, "Fwd Del"), 0x4D: (119, "End"), 0x4E: (121, "PgDn"),
        0x4F: (124, "→"), 0x50: (123, "←"), 0x51: (125, "↓"), 0x52: (126, "↑"), 0x58: (76, "Enter"),
        0x3A: (122, "F1"), 0x3B: (120, "F2"), 0x3C: (99, "F3"), 0x3D: (118, "F4"), 0x3E: (96, "F5"), 0x3F: (97, "F6"),
        0x40: (98, "F7"), 0x41: (100, "F8"), 0x42: (101, "F9"), 0x43: (109, "F10"), 0x44: (103, "F11"), 0x45: (111, "F12"),
    ]
    /// HID consumer-page usage → NX media key type.
    static let consumerUsages: [UInt16: (Int32, String)] = [
        0xE9: (0, "Volume Up"), 0xEA: (1, "Volume Down"), 0xE2: (7, "Mute"), 0xCD: (16, "Play/Pause"), 0xB0: (16, "Play"), 0xB1: (16, "Pause"),
        0xB5: (17, "Next"), 0xB6: (18, "Previous"), 0xB3: (19, "Fast Forward"), 0xB4: (20, "Rewind"), 0x30: (6, "Power"),
    ]

    /// What macOS would do with this code, or nil when it does nothing (AC Home, Search, vendor keys…).
    public static func mapping(for c: ButtonCode) -> Mapping? {
        switch c.reportID {
        case ButtonTable.keyboardReport:
            if let (k, l) = keyboardUsages[c.code] { return Mapping(label: String(localized: String.LocalizationValue(l)), kind: .key(k)) }
            if c.code == 0x66 { return Mapping(label: String(localized: "Power"), kind: .media(6)) }
            return nil
        case ButtonTable.consumerReport:
            if let (m, l) = consumerUsages[c.code] ?? consumerUsages[c.code & 0xFF] { return Mapping(label: String(localized: String.LocalizationValue(l)), kind: .media(m)) }
            return nil
        default: return nil
        }
    }

    private var held: [ButtonCode: DispatchSourceTimer] = [:]
    public var initialRepeatDelay: TimeInterval = 0.4
    public var repeatInterval: TimeInterval = 0.06
    public init() {}

    public func press(_ c: ButtonCode) {
        guard let m = Self.mapping(for: c) else { return }
        release(c)
        emit(m.kind, down: true)
        // auto-repeat like a real keyboard while the button stays down
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + initialRepeatDelay, repeating: repeatInterval)
        t.setEventHandler { [weak self] in self?.emit(m.kind, down: true, isRepeat: true) }
        t.resume()
        held[c] = t
    }
    public func release(_ c: ButtonCode) {
        guard let t = held.removeValue(forKey: c) else { return }
        t.cancel()
        if let m = Self.mapping(for: c) { emit(m.kind, down: false) }
    }
    public func releaseAll() { for c in Array(held.keys) { release(c) } }

    private func emit(_ k: Kind, down: Bool, isRepeat: Bool = false) {
        switch k {
        case .key(let code):
            let src = CGEventSource(stateID: .combinedSessionState)
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
            if isRepeat { ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            ev.post(tap: .cghidEventTap)
        case .media(let key):
            if isRepeat { postMedia(key, down: true); postMedia(key, down: false); return }
            postMedia(key, down: down)
        case .none: break
        }
    }
    private func postMedia(_ key: Int32, down: Bool) {
        let flags: UInt = down ? 0xa00 : 0xb00
        let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
        if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) {
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

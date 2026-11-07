import Foundation

/// A physical button on the Fire TV (Alexa Voice) remote.
public enum RemoteButton: String, Codable, CaseIterable, Identifiable, Hashable, CodingKeyRepresentable {
    case power, mic
    case up, down, left, right, select
    case back, home, menu
    case rewind, playPause, fastForward
    case volumeUp, volumeDown, mute
    case tv
    case a1, a2, a3, a4

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .power: return String(localized: "Power")
        case .mic: return String(localized: "Microphone")
        case .up: return String(localized: "Above")
        case .down: return String(localized: "Below")
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .select: return String(localized: "OK")
        case .back: return String(localized: "Back")
        case .home: return String(localized: "Home")
        case .menu: return String(localized: "Menu")
        case .rewind: return String(localized: "Rewind")
        case .playPause: return String(localized: "Play/Pause")
        case .fastForward: return String(localized: "Fast Forward")
        case .volumeUp: return String(localized: "Volume Up")
        case .volumeDown: return String(localized: "Volume Down")
        case .mute: return String(localized: "Mute")
        case .tv: return String(localized: "Television")
        case .a1: return String(localized: "App 1 (A1)")
        case .a2: return String(localized: "App 2 (A2)")
        case .a3: return String(localized: "App 3 (A3)")
        case .a4: return String(localized: "App 4 (A4)")
        }
    }

    public var shortName: String {
        switch self {
        case .power: return "⏻"
        case .mic: return "🎤"
        case .up: return "▲"
        case .down: return "▼"
        case .left: return "◀"
        case .right: return "▶"
        case .select: return "OK"
        case .back: return "↩"
        case .home: return "⌂"
        case .menu: return "≡"
        case .rewind: return "⏪"
        case .playPause: return "⏯"
        case .fastForward: return "⏩"
        case .volumeUp: return "+"
        case .volumeDown: return "−"
        case .mute: return "🔇"
        case .tv: return "TV"
        case .a1: return "A1"
        case .a2: return "A2"
        case .a3: return "A3"
        case .a4: return "A4"
        }
    }
}

/// Identity of a button on the wire: the HID report ID plus the code byte.
public struct ButtonCode: Codable, Hashable, CustomStringConvertible {
    public var reportID: UInt8
    /// HID usage. Keyboard page: 1 byte. Consumer page: 16-bit usage (e.g. 0x0223 = AC Home).
    public var code: UInt16
    public init(reportID: UInt8, code: UInt16) { self.reportID = reportID; self.code = code }
    public var description: String { code > 0xFF ? String(format: "%02x/%04x", reportID, code) : String(format: "%02x/%02x", reportID, code) }
    /// Equality that also accepts codes learned by older builds, which stored only the low byte of consumer usages.
    public func matches(_ other: ButtonCode) -> Bool {
        guard reportID == other.reportID else { return false }
        if code == other.code { return true }
        if reportID == ButtonTable.consumerReport { return (code < 0x100 && code == other.code & 0xFF) || (other.code < 0x100 && other.code == code & 0xFF) }
        return false
    }
}

/// Why a button cannot be assigned.
public enum AssignRestriction: Equatable {
    case none
    /// Code not yet observed from the real remote; must be learned first.
    case codeUnknown
    /// The button already produces regular macOS input (keyboard/media key).
    /// Without exclusive device access (requires root) a remap would double-fire.
    case osHandled
}

public struct ButtonInfo {
    public let button: RemoteButton
    public let code: ButtonCode?
    public let restriction: AssignRestriction
}

public enum ButtonTable {
    public static let keyboardReport: UInt8 = 0x01
    public static let consumerReport: UInt8 = 0x02
    public static let vendorReport: UInt8 = 0xEF

    /// Codes confirmed from the real device (see README). Buttons missing here
    /// must be learned through the GUI before they can be identified.
    public static let knownCodes: [RemoteButton: ButtonCode] = [
        .a1: ButtonCode(reportID: 0xEF, code: 0xA1),
        .a2: ButtonCode(reportID: 0xEF, code: 0xA2),
        .a3: ButtonCode(reportID: 0xEF, code: 0xA3),
        .a4: ButtonCode(reportID: 0xEF, code: 0xA4),
        .tv: ButtonCode(reportID: 0x02, code: 0x8D),
        .mic: ButtonCode(reportID: 0x02, code: 0x0221),
        .up: ButtonCode(reportID: 0x01, code: 0x52),
        .down: ButtonCode(reportID: 0x01, code: 0x51),
        .left: ButtonCode(reportID: 0x01, code: 0x50),
        .right: ButtonCode(reportID: 0x01, code: 0x4F),
        .playPause: ButtonCode(reportID: 0x02, code: 0xCD),
    ]

    /// Consumer-page usages macOS acts on by itself.
    static let osHandledConsumer: Set<UInt16> = [0xCD, 0xB0, 0xB1, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xE2, 0xE9, 0xEA, 0x30, 0x40, 0x221, 0x223, 0x224]

    /// Does macOS already turn this code into regular input (when the device is not seized)?
    public static func isOSHandled(_ c: ButtonCode) -> Bool {
        switch c.reportID {
        case keyboardReport: return true
        case consumerReport: return osHandledConsumer.contains(c.code) || osHandledConsumer.contains(c.code & 0xFF)
        default: return false
        }
    }

    /// `exclusive`: the device is seized by our helper, so macOS never sees it and every learned button is assignable.
    public static func info(for b: RemoteButton, learned: [RemoteButton: ButtonCode], exclusive: Bool = false) -> ButtonInfo {
        let code = learned[b] ?? knownCodes[b]
        guard let code else { return ButtonInfo(button: b, code: nil, restriction: .codeUnknown) }
        return ButtonInfo(button: b, code: code, restriction: (!exclusive && isOSHandled(code)) ? .osHandled : .none)
    }
}

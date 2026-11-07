import SwiftUI
import FireTVCore

/// UI-only state for the editor window.
final class EditorState: ObservableObject {
    @Published var selectedButton: RemoteButton? = .a1
    @Published var editingLayer: Int = 0
    @Published var followRemote = true
    @Published var showLayers = false
    @Published var showMacros = false
    @Published var showDevice = false
    @Published var editingMacro: UUID?
    @Published var appearance: Appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    enum Appearance: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return String(localized: "Fit to system")
            case .dark: return String(localized: "Dark")
            case .light: return String(localized: "Light")
            }
        }
        var scheme: ColorScheme? { switch self { case .system: return nil; case .dark: return .dark; case .light: return .light } }
    }
}

/// Kind of action shown in the inspector's type picker.
enum ActionKind: String, CaseIterable, Identifiable {
    case passthrough = "Default Behavior (original function)", none = "Disabled (do nothing)", transparent = "Transparent (inherit lower layer)", shortcut = "Shortcuts", key = "Send Key", media = "Media", app = "Launch the app", url = "Open URL", layer = "Layer manipulation", macro = "Macros"
    var id: String { rawValue }
    var display: String {
        switch self {
        case .passthrough: return String(localized: "Default Behavior (original function)")
        case .none: return String(localized: "Disabled (do nothing)")
        case .transparent: return String(localized: "Transparent (inherit lower layer)")
        case .shortcut: return String(localized: "Shortcuts")
        case .key: return String(localized: "Send Key")
        case .media: return String(localized: "Media")
        case .app: return String(localized: "Launch the app")
        case .url: return String(localized: "Open URL")
        case .layer: return String(localized: "Layer manipulation")
        case .macro: return String(localized: "Macros")
        }
    }
    var icon: String {
        switch self {
        case .passthrough: return "arrow.uturn.forward"
        case .none: return "circle.slash"
        case .transparent: return "arrow.down.to.line"
        case .shortcut: return "square.2.layers.3d"
        case .key: return "keyboard"
        case .media: return "play.circle"
        case .app: return "app"
        case .url: return "link"
        case .layer: return "square.3.layers.3d"
        case .macro: return "list.bullet.rectangle"
        }
    }
    static func of(_ a: Action?) -> ActionKind {
        guard let a else { return .transparent }
        switch a {
        case .none: return .none
        case .transparent: return .transparent
        case .passthrough: return .passthrough
        case .shortcut: return .shortcut
        case .key: return .key
        case .media: return .media
        case .launchApp: return .app
        case .openURL: return .url
        case .layer: return .layer
        case .macro: return .macro
        }
    }
    /// A sensible default action when the user switches to this kind.
    func defaultAction(firstMacro: UUID?) -> Action? {
        switch self {
        case .passthrough: return .passthrough
        case .none: return Action.none
        case .transparent: return .transparent
        case .shortcut: return .shortcut(name: "")
        case .key: return .key(KeyCombo(keyCode: 36, keyName: "Return"))
        case .media: return .media(.playPause)
        case .app: return .launchApp(path: "", name: "")
        case .url: return .openURL("https://")
        case .layer: return .layer(.momentary(1))
        case .macro: return firstMacro.map { .macro(id: $0) }
        }
    }
}

import SwiftUI
import AppKit
import FireTVCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created on first access: SwiftUI evaluates the App body before the delegate's launch callbacks.
    static let controller = RemoteController()

    func applicationWillFinishLaunching(_ n: Notification) {
        // Single instance: a second copy would fight for the HID device.
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid).filter { $0 != NSRunningApplication.current }
            if let other = others.first { other.activate(); NSApp.terminate(nil); return }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { AppDelegate.controller.shutdown() }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}

@main
enum FireTVMain {
    static func main() {
        // Must run before SwiftUI/Bundle resolves Localizable.strings.
        LanguageManager.applyStoredLanguage()
        FireTVRemoteApp.main()
    }
}

struct FireTVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var editor = EditorState()

    var body: some Scene {
        WindowGroup("Fire TV Remote Studio", id: "main") {
            MainView()
                .environmentObject(AppDelegate.controller)
                .environmentObject(editor)
                .preferredColorScheme(editor.appearance.scheme)
                .tint(Theme.accent)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1040, height: 720)

        Settings {
            SettingsView()
                .environmentObject(AppDelegate.controller)
                .environmentObject(editor)
                .preferredColorScheme(editor.appearance.scheme)
                .tint(Theme.accent)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(AppDelegate.controller)
        } label: {
            Image(systemName: "tv.and.mediabox")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var ctl: RemoteController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(statusLine)
        Text("Active layers: \(ctl.activeLayers.first.map { ctl.config.layers[safe: $0]?.name ?? "\($0)" } ?? "-")")
        if let b = ctl.lastPressed { Text("Last button: \(b.displayName)") }
        Divider()
        Button("Open editor") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("e")
        Button(ctl.monitor.isRunning ? String(localized: "Stop monitoring") : String(localized: "Start monitoring")) { ctl.setMonitoring(!ctl.monitor.isRunning) }
        Divider()
        Button("Exit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    var statusLine: String {
        switch ctl.hidStatus {
        case .stopped: return String(localized: "Not monitoring")
        case .waitingForDevice: return String(localized: "○ Remote not connected (waiting)")
        case .connected(let n): return String(localized: "● \(n) Connecting")
        case .blocked: return String(localized: "⚠ Cannot open device")
        }
    }
}

import Foundation
import AppKit
import ApplicationServices

/// Executes resolved actions. Reports outcomes through `onEvent` on the main queue.
public final class ActionExecutor {
    public enum Event: Equatable {
        case started(String)
        case finished(String)
        case failed(String, String)
    }
    public let shortcuts: ShortcutsService
    public var macroLookup: (UUID) -> Macro? = { _ in nil }
    public var onEvent: (Event) -> Void = { _ in }
    private let macroQueue = DispatchQueue(label: "firetv.macro")
    private var macroRunning = false
    private let lock = NSLock()

    public init(shortcuts: ShortcutsService) { self.shortcuts = shortcuts }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent(e) } }

    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    public static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    public func execute(_ action: Action, completion: ((Bool) -> Void)? = nil) {
        switch action {
        case .none, .transparent, .layer, .passthrough:
            completion?(true)
        case .shortcut(let name):
            guard !name.isEmpty else { emit(.failed(String(localized: "Shortcuts"), String(localized: "Shortcut not selected"))); completion?(false); return }
            emit(.started("Shortcut \(name)"))
            shortcuts.run(name) { r in
                switch r {
                case .success: self.emit(.finished("Shortcut \(name)")); completion?(true)
                case .failure(let e): self.emit(.failed("Shortcut \(name)", e.localizedDescription)); completion?(false)
                }
            }
        case .key(let combo):
            guard Self.accessibilityTrusted else {
                emit(.failed(combo.display, String(localized: "Key transmission requires accessibility permissions (System Settings > Privacy & Security > Accessibility)")))
                Self.promptAccessibility(); completion?(false); return
            }
            Self.postKey(combo); emit(.finished("Key \(combo.display)")); completion?(true)
        case .launchApp(let path, let name):
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { emit(.failed(String(localized: "Launch \(name)"), String(localized: "App not found:\(path)"))); completion?(false); return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let err { self.emit(.failed(String(localized: "Launch \(name)"), err.localizedDescription)); completion?(false) }
                else { self.emit(.finished(String(localized: "Launch \(name)"))); completion?(true) }
            }
        case .openURL(let s):
            guard let url = URL(string: s), url.scheme != nil else { emit(.failed("URL", String(localized: "Invalid URL: \(s)"))); completion?(false); return }
            let ok = NSWorkspace.shared.open(url)
            emit(ok ? .finished("URL \(s)") : .failed("URL \(s)", String(localized: "Could not open"))); completion?(ok)
        case .media(let m):
            Self.postMediaKey(m.nxKeyType); emit(.finished(m.displayName)); completion?(true)
        case .macro(let id):
            guard let macro = macroLookup(id) else { emit(.failed(String(localized: "Macros"), String(localized: "Nonexistent macro"))); completion?(false); return }
            lock.lock()
            if macroRunning { lock.unlock(); emit(.failed(String(localized: "Macro \(macro.name)"), String(localized: "Another macro is running"))); completion?(false); return }
            macroRunning = true; lock.unlock()
            emit(.started(String(localized: "Macro \(macro.name)")))
            macroQueue.async {
                var ok = true
                for step in macro.steps {
                    let sem = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { self.execute(step.action) { r in if !r { ok = false }; sem.signal() } }
                    _ = sem.wait(timeout: .now() + 30)
                    if step.delayMs > 0 { Thread.sleep(forTimeInterval: Double(step.delayMs) / 1000) }
                }
                self.lock.lock(); self.macroRunning = false; self.lock.unlock()
                self.emit(.finished(String(localized: "Macro \(macro.name)"))); completion?(ok)
            }
        }
    }

    // MARK: held keys (remote button held → key held, so hold-to-talk hotkeys work)

    private var heldKeys: [KeyCombo] = []
    /// Press (and keep down) a key combo. Returns false when accessibility is missing.
    @discardableResult
    public func keyDown(_ c: KeyCombo) -> Bool {
        guard Self.accessibilityTrusted else {
            emit(.failed(c.display, String(localized: "Accessibility permission required to send keys"))); Self.promptAccessibility(); return false
        }
        if !heldKeys.contains(c) { heldKeys.append(c) }
        if c.modifierOnly { refreshModifierFlags() } else { Self.post(c, down: true, extraFlags: heldModifierFlags) }
        emit(.started(String(localized: "Key \(c.display) (pressing)"))); return true
    }
    public func keyUp(_ c: KeyCombo) {
        guard let i = heldKeys.firstIndex(of: c) else { return }
        heldKeys.remove(at: i)
        if c.modifierOnly { refreshModifierFlags() } else { Self.post(c, down: false, extraFlags: heldModifierFlags) }
        emit(.finished(String(localized: "Key \(c.display) (pressing)")))
    }
    public func releaseAllKeys() {
        let hadModifiers = heldKeys.contains { $0.modifierOnly }
        let modifiers = heldModifierFlags
        for c in heldKeys where !c.modifierOnly { Self.post(c, down: false, extraFlags: modifiers) }
        heldKeys.removeAll()
        if hadModifiers { Self.postFlagsChanged([]) }
        for (_, t) in heldMedia { t.cancel() }; for m in heldMedia.keys { Self.postMediaKey(m.nxKeyType, down: false) }; heldMedia.removeAll()
    }
    /// Modifiers currently held by modifier-only actions.
    private var heldModifierFlags: CGEventFlags {
        var flags = CGEventFlags()
        for c in heldKeys where c.modifierOnly { flags.formUnion(Self.flags(for: c)) }
        return flags
    }
    /// Post the union of every held modifier-only combo, so releasing one does
    /// not release modifiers still held by another remote button.
    private func refreshModifierFlags() {
        Self.postFlagsChanged(heldModifierFlags)
    }

    // MARK: held media keys (volume/transport repeat while the remote button stays down)
    private var heldMedia: [MediaKey: DispatchSourceTimer] = [:]
    public func mediaDown(_ m: MediaKey) {
        if heldMedia[m] != nil { return }
        Self.postMediaKey(m.nxKeyType, down: true)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.4, repeating: 0.06)
        t.setEventHandler { Self.postMediaKey(m.nxKeyType, down: true); Self.postMediaKey(m.nxKeyType, down: false) }
        t.resume(); heldMedia[m] = t
        emit(.started(String(localized: "\(m.displayName) (pressing)")))
    }
    public func mediaUp(_ m: MediaKey) {
        guard let t = heldMedia.removeValue(forKey: m) else { return }
        t.cancel(); Self.postMediaKey(m.nxKeyType, down: false); emit(.finished(String(localized: "\(m.displayName) (pressing)")))
    }
    static func postMediaKey(_ key: Int32, down: Bool) {
        let flags: UInt = down ? 0xa00 : 0xb00
        let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
        if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) {
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: key / media posting

    static func flags(for c: KeyCombo) -> CGEventFlags {
        var flags = CGEventFlags()
        if c.function { flags.insert(.maskSecondaryFn) }
        if c.command { flags.insert(.maskCommand) }
        if c.shift { flags.insert(.maskShift) }
        if c.option { flags.insert(.maskAlternate) }
        if c.control { flags.insert(.maskControl) }
        return flags
    }

    /// Set the global modifier state directly (needed when no regular key is sent).
    static func postFlagsChanged(_ flags: CGEventFlags) {
        guard let ev = CGEvent(source: nil) else { return }
        ev.type = .flagsChanged
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }

    static func post(_ c: KeyCombo, down: Bool, extraFlags: CGEventFlags = []) {
        guard !c.modifierOnly else { return }
        var flags = Self.flags(for: c)
        flags.formUnion(extraFlags)
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(c.keyCode), keyDown: down) else { return }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }

    static func postKey(_ c: KeyCombo) {
        if c.modifierOnly {
            let flags = Self.flags(for: c)
            Self.postFlagsChanged(flags)
            usleep(10_000)
            Self.postFlagsChanged([])
            return
        }
        let flags = Self.flags(for: c)
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(c.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(c.keyCode), keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
    }

    static func postMediaKey(_ key: Int32) {
        func post(_ down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true); post(false)
    }
}

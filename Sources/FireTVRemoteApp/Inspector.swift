import SwiftUI
import AppKit
import FireTVCore

/// Right-hand panel: everything about the selected button on the editing layer.
struct InspectorView: View {
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                if let b = editor.selectedButton {
                    ButtonHeader(button: b)
                    let info = ctl.info(for: b)
                    switch info.restriction {
                    case .osHandled:
                        Banner(icon: "lock.fill", text: "This button is treated as a standard key by macOS. Please enable \"Exclusive Mode\" in Settings (⌘,) to assign. Only the remote control is proprietary, and the original function can be reproduced as \"default behavior\".")
                        Button("Open settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }.controlSize(.small)
                    case .codeUnknown:
                        Banner(icon: "questionmark.circle", text: "Hid code not verified. You can assign it by “learning” it on the device screen.")
                        Button("Open device screen") { editor.showDevice = true }.controlSize(.small)
                    case .none:
                        ActionSection(button: b)
                    }
                    OtherLayersSection(button: b)
                } else {
                    VStack(spacing: Theme.s2) {
                        Image(systemName: "hand.tap").font(.system(size: 28)).foregroundStyle(Theme.text3)
                        Text("Select remote control button").font(Theme.body).foregroundStyle(Theme.text2)
                        Text("Click on screen or press button on device").font(Theme.caption).foregroundStyle(Theme.text3)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(Theme.s4)
        }
    }
}

struct ButtonHeader: View {
    let button: RemoteButton
    @EnvironmentObject var ctl: RemoteController
    var body: some View {
        let info = ctl.info(for: button)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(button.displayName).font(Theme.title)
                Spacer()
                if ctl.pressedNow.contains(button) { StatusPill(text: "Held", color: Theme.accent) }
            }
            Text(info.code.map { "HID " + $0.description } ?? String(localized: "Hid Not Learned")).font(Theme.mono).foregroundStyle(Theme.text2)
            if button == .mic && ctl.micEnabled {
                Label("Sends audio to virtual mic while held (independent of assignment)", systemImage: "mic").font(Theme.caption).foregroundStyle(Theme.text2)
            }
        }
    }
}

/// Action kind picker + kind-specific editor + test/clear.
struct ActionSection: View {
    let button: RemoteButton
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState

    var current: Action? { ctl.config.layers[safe: editor.editingLayer]?.bindings[button] }
    var kind: Binding<ActionKind> {
        Binding(get: { current == nil && editor.editingLayer == 0 ? .passthrough : ActionKind.of(current) }, set: { k in
            if k == ActionKind.of(current) { return }
            if k == .transparent && editor.editingLayer == 0 { ctl.clear(button, layer: 0); return }
            if let a = k.defaultAction(firstMacro: ctl.config.macros.first?.id) { ctl.assign(a, to: button, layer: editor.editingLayer) }
        })
    }
    var actionBinding: Binding<Action> {
        Binding(get: { current ?? (editor.editingLayer == 0 && ctl.exclusiveActive ? .passthrough : .transparent) }, set: { ctl.assign($0, to: button, layer: editor.editingLayer) })
    }
    var isSet: Bool { current != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionHeader(title: "Action · \(ctl.config.layers[safe: editor.editingLayer]?.name ?? "")")
            Picker("Type", selection: kind) {
                ForEach(ActionKind.allCases.filter { !($0 == .transparent && editor.editingLayer == 0) }) { k in
                    Label(k.display, systemImage: k.icon).tag(k)
                }
            }
            .labelsHidden().controlSize(.regular)
            .accessibilityLabel("Action type")

            ActionEditor(action: actionBinding, isSet: isSet)

            HStack(spacing: Theme.s2) {
                if let a = current, canTest(a) {
                    Button { ctl.executor.execute(a) } label: { Label("Run Test", systemImage: "play.fill") }
                        .keyboardShortcut("t", modifiers: .command)
                }
                Spacer()
                if isSet {
                    Button(role: .destructive) { ctl.clear(button, layer: editor.editingLayer) } label: { Text("Unassign") }
                        .help(editor.editingLayer == 0 ? "Reset to unset" : "Reset to unset (inherit lower layer)")
                }
            }
            .controlSize(.small)
        }
        .padding(Theme.s3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusL))
    }
    func canTest(_ a: Action) -> Bool {
        switch a {
        case .none, .transparent, .layer, .passthrough: return false
        case .shortcut(let n): return !n.isEmpty
        case .launchApp(let p, _): return !p.isEmpty
        default: return true
        }
    }
}

/// Kind-specific editor for an action value. Also used by the macro step editor.
struct ActionEditor: View {
    @Binding var action: Action
    var isSet = true
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState

    var body: some View {
        switch action {
        case .passthrough:
            if let b = editor.selectedButton, let label = ctl.defaultBehavior(of: b) {
                Text((isSet ? "" : String(localized: "Because unset")) + (ctl.exclusiveActive ? String(localized: "App reproduces original function: \(label) (including long-press repeat)") : String(localized: "macOS handles the original feature:\(label)"))).font(Theme.caption).foregroundStyle(Theme.text2)
            } else {
                Text("This button does not normally do anything on macOS (default behavior = do nothing).").font(Theme.caption).foregroundStyle(Theme.text2)
            }
        case .none:
            Text("Does nothing when pressed (original function also disabled). Lower-layer assignments are not used.").font(Theme.caption).foregroundStyle(Theme.text2)
        case .transparent:
            Text(editor.editingLayer == 0 ? String(localized: "Unset. Select a type to assign.") : String(localized: "Unset. Inherits assignment from lower valid layer.")).font(Theme.caption).foregroundStyle(Theme.text2)
        case .shortcut(let name):
            ShortcutField(name: name) { action = .shortcut(name: $0) }
        case .key(let combo):
            KeyComboEditor(combo: combo) { action = .key($0) }
        case .media(let m):
            Picker("Media", selection: Binding(get: { m }, set: { action = .media($0) })) {
                ForEach(MediaKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.labelsHidden()
            Text("Hold for continuous operation (volume changes while held)").font(Theme.caption).foregroundStyle(Theme.text2)
        case .launchApp(let path, let name):
            AppField(path: path, name: name) { p, n in action = .launchApp(path: p, name: n) }
        case .openURL(let url):
            URLField(url: url) { action = .openURL($0) }
        case .layer(let op):
            LayerOpEditor(op: op) { action = .layer($0) }
        case .macro(let id):
            HStack {
                Picker("Macros", selection: Binding(get: { id }, set: { action = .macro(id: $0) })) {
                    ForEach(ctl.config.macros) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                Button("Edit…") { editor.editingMacro = id; editor.showMacros = true }.controlSize(.small)
            }
            if ctl.config.macros.isEmpty { Text("Macro is missing. Please create from \"Macros\".").font(Theme.caption).foregroundStyle(Theme.warning) }
        }
    }
}

// MARK: - Shortcut picker

struct ShortcutField: View {
    let name: String
    let onPick: (String) -> Void
    @EnvironmentObject var ctl: RemoteController
    @State private var open = false
    var missing: Bool { !name.isEmpty && ctl.shortcutsLoadError == nil && !ctl.shortcutNames.isEmpty && !ctl.shortcutNames.contains(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack {
                    Image(systemName: "square.2.layers.3d").foregroundStyle(name.isEmpty ? Theme.text3 : Theme.accent)
                    Text(name.isEmpty ? String(localized: "Select shortcut…") : name).foregroundStyle(name.isEmpty ? Theme.text2 : Theme.text).lineLimit(1)
                    Spacer()
                    if ctl.executing.contains("Shortcut \(name)") { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.text2)
                }
                .padding(.horizontal, 8).frame(height: Theme.controlH)
                .background(Theme.panelBG, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(missing ? Theme.danger : Theme.border))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ShortcutPicker(current: name) { onPick($0); open = false }
            }
            .accessibilityLabel("Shortcut:\(name.isEmpty ? "Unset" : name)")
            if missing { Label("This shortcut does not exist", systemImage: "exclamationmark.triangle.fill").font(Theme.caption).foregroundStyle(Theme.danger) }
            if let e = ctl.shortcutsLoadError { Label(e, systemImage: "exclamationmark.triangle.fill").font(Theme.caption).foregroundStyle(Theme.danger) }
        }
    }
}

/// Searchable, keyboard-navigable list of the user's real Shortcuts.
struct ShortcutPicker: View {
    let current: String
    let onPick: (String) -> Void
    @EnvironmentObject var ctl: RemoteController
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? ctl.shortcutNames : ctl.shortcutNames.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2)
                TextField("Search for shortcut", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let s = selection ?? filtered.first { onPick(s) } }
                Button { ctl.refreshShortcuts() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Reload list").disabled(ctl.shortcutsLoading)
                if ctl.shortcutsLoading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).frame(height: 36)
            Divider()
            if let e = ctl.shortcutsLoadError {
                Banner(icon: "exclamationmark.triangle.fill", text: "Unable to fetch list:\(e)", color: Theme.danger).padding(10)
            } else if ctl.shortcutNames.isEmpty && !ctl.shortcutsLoading {
                Text("There are no shortcuts registered in the shortcut app").font(Theme.caption).foregroundStyle(Theme.text2).padding(14)
            } else if filtered.isEmpty {
                Text("No match for \"\(query)\"").font(Theme.caption).foregroundStyle(Theme.text2).padding(14)
            } else {
                List(filtered, id: \.self, selection: $selection) { n in
                    HStack {
                        Text(n).font(Theme.body).lineLimit(1)
                        Spacer()
                        if n == current { Image(systemName: "checkmark").foregroundStyle(Theme.accent).font(.system(size: 11, weight: .semibold)) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(n) }
                    .tag(n)
                }
                .listStyle(.plain)
                .onKeyPress(.return) { if let s = selection { onPick(s); return .handled }; return .ignored }
            }
            Divider()
            Text("\(String(filtered.count)) / \(String(ctl.shortcutNames.count)) items · ↑↓ to move, Return to assign").font(Theme.caption).foregroundStyle(Theme.text3)
                .padding(.horizontal, 10).frame(height: 24, alignment: .leading)
        }
        .frame(width: 320, height: 360)
        .onAppear { selection = current.isEmpty ? nil : current; searchFocused = true }
        .onChange(of: query) { _, _ in selection = filtered.first }
    }
}

// MARK: - Other editors

struct KeyComboEditor: View {
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void
    var body: some View {
        let noModifiers = !combo.function && !combo.command && !combo.shift && !combo.option && !combo.control
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("⌘", isOn: Binding(get: { combo.command }, set: { var c = combo; c.command = $0; onChange(c) }))
                Toggle("⇧", isOn: Binding(get: { combo.shift }, set: { var c = combo; c.shift = $0; onChange(c) }))
                Toggle("⌥", isOn: Binding(get: { combo.option }, set: { var c = combo; c.option = $0; onChange(c) }))
                Toggle("⌃", isOn: Binding(get: { combo.control }, set: { var c = combo; c.control = $0; onChange(c) }))
                Toggle("fn", isOn: Binding(get: { combo.function }, set: { var c = combo; c.function = $0; onChange(c) }))
                    .help("Function (Fn) modifier: Fn+F3 sends a real function key")
                Spacer()
                Text(combo.display).font(Theme.bodyStrong)
            }
            .toggleStyle(.button).controlSize(.small)
            Toggle("Modifier key only", isOn: Binding(get: { combo.modifierOnly }, set: { var c = combo; c.modifierOnly = $0; onChange(c) }))
                .toggleStyle(.checkbox).controlSize(.small)
                .help("Send only the selected modifiers; hold the remote button to keep them down")
            Picker("Key", selection: Binding(get: { combo.keyCode }, set: { code in
                if let e = KeyTable.all.first(where: { $0.code == code }) { var c = combo; c.keyCode = e.code; c.keyName = e.name; onChange(c) }
            })) {
                Section("Characters") { ForEach(KeyTable.letters) { Text($0.name).tag($0.code) } }
                Section("Numbers") { ForEach(KeyTable.digits) { Text($0.name).tag($0.code) } }
                Section("Symbols") { ForEach(KeyTable.symbols) { Text($0.name).tag($0.code) } }
                Section("Function") { ForEach(KeyTable.function) { Text($0.name).tag($0.code) } }
                Section("Operation") { ForEach(KeyTable.navigation) { Text($0.name).tag($0.code) } }
            }.labelsHidden().disabled(combo.modifierOnly)
            if combo.modifierOnly {
                Text(noModifiers ? String(localized: "Select at least one modifier above.") : String(localized: "No regular key is sent. Hold the remote button to hold the selected modifiers down (for example fn)."))
                    .font(Theme.caption).foregroundStyle(noModifiers ? Theme.warning : Theme.text2)
            } else {
                Text("Press and hold the key while pressing the button on the remote control (long press · Push-to-Talk compatible)").font(Theme.caption).foregroundStyle(Theme.text2)
            }
            if !ActionExecutor.accessibilityTrusted {
                Banner(icon: "hand.raised", text: "Accessibility permissions are required to send keys (setting → permissions).")
            }
        }
    }
}

struct AppField: View {
    let path: String
    let name: String
    let onChange: (String, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !path.isEmpty {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                    Text(name).font(Theme.body).lineLimit(1)
                } else { Text("No app selected").font(Theme.body).foregroundStyle(Theme.text2) }
                Spacer()
                Menu {
                    ForEach(runningApps, id: \.path) { a in Button(a.name) { onChange(a.path, a.name) } }
                } label: { Text("From running") }.frame(width: 90)
                Button("Select…") { pick() }
            }
            .controlSize(.small)
            if !path.isEmpty { Text(path).font(Theme.mono).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle) }
        }
    }
    var runningApps: [(name: String, path: String)] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleURL.map { (a.localizedName ?? $0.lastPathComponent, $0.path) } }.sorted { $0.0 < $1.0 }
    }
    func pick() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.applicationBundle]; p.directoryURL = URL(fileURLWithPath: "/Applications"); p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url else { return }
        onChange(u.path, u.deletingPathExtension().lastPathComponent)
    }
}

struct URLField: View {
    let url: String
    let onChange: (String) -> Void
    @State private var text = ""
    var valid: Bool { URL(string: text)?.scheme != nil && text.count > 8 }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("https://example.com", text: $text).textFieldStyle(.roundedBorder)
                .onSubmit { if valid { onChange(text) } }
                .onAppear { text = url }
                .onChange(of: url) { _, u in if u != text { text = u } }
            HStack {
                Text(text == url ? String(localized: "Saved") : (valid ? String(localized: "Save as Return") : String(localized: "Enter a valid URL"))).font(Theme.caption).foregroundStyle(text == url ? Theme.text3 : (valid ? Theme.text2 : Theme.warning))
                Spacer()
                if text != url { Button("Save") { onChange(text) }.controlSize(.small).disabled(!valid) }
            }
        }
    }
}

struct LayerOpEditor: View {
    let op: LayerOp
    let onChange: (LayerOp) -> Void
    @EnvironmentObject var ctl: RemoteController
    enum Kind: String, CaseIterable, Identifiable { case mo = "MO", tg = "TG", to = "TO", df = "DF"; var id: String { rawValue } }
    var kind: Kind { switch op { case .momentary: return .mo; case .toggle: return .tg; case .switchTo: return .to; case .setDefault: return .df } }
    func make(_ k: Kind, _ n: Int) -> LayerOp { switch k { case .mo: return .momentary(n); case .tg: return .toggle(n); case .to: return .switchTo(n); case .df: return .setDefault(n) } }
    var desc: String {
        switch kind {
        case .mo: return String(localized: "Active while held (Momentary)")
        case .tg: return String(localized: "Toggles on each press. Other TG layers are cleared; TG to default layer returns to base (Toggle)")
        case .to: return String(localized: "Enable only that layer (Switch)")
        case .df: return String(localized: "Change default layer and keep after restart (Default)")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Operation", selection: Binding(get: { kind }, set: { onChange(make($0, op.layer)) })) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Layer", selection: Binding(get: { op.layer }, set: { onChange(make(kind, $0)) })) {
                ForEach(ctl.config.layers.indices, id: \.self) { Text("\($0) · \(ctl.config.layers[$0].name)").tag($0) }
            }.labelsHidden()
            Text(desc).font(Theme.caption).foregroundStyle(Theme.text2)
        }
    }
}

/// Compact view of this button on the other layers, with jump-to-edit.
struct OtherLayersSection: View {
    let button: RemoteButton
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState
    var body: some View {
        let others = ctl.config.layers.indices.filter { $0 != editor.editingLayer }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Other Layers")
                ForEach(others, id: \.self) { i in
                    let a = ctl.config.layers[i].bindings[button]
                    Button { editor.editingLayer = i } label: {
                        HStack {
                            Text("\(i) · \(ctl.config.layers[i].name)").font(Theme.caption).foregroundStyle(Theme.text2).frame(width: 110, alignment: .leading).lineLimit(1)
                            Text(a.map(describe) ?? (i == 0 ? String(localized: "Unset") : String(localized: "Inherit"))).font(Theme.caption).foregroundStyle(a == nil ? Theme.text3 : Theme.text).lineLimit(1)
                            Spacer()
                            if ctl.activeLayers.contains(i) { Circle().fill(Theme.accent).frame(width: 5, height: 5).help("Currently enabled") }
                        }
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit this layer")
                }
            }
        }
    }
    func describe(_ a: Action) -> String {
        if case .macro(let id) = a { return "Macros:" + (ctl.config.macros.first { $0.id == id }?.name ?? "?") }
        if case .shortcut(let n) = a { return n.isEmpty ? "Shortcut not selected" : n }
        return a.display
    }
}

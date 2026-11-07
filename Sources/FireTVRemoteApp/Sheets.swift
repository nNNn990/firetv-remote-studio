import SwiftUI
import AppKit
import ServiceManagement
import FireTVCore

struct SheetFrame<Content: View>: View {
    let title: LocalizedStringKey
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.small)
            }
            .padding(.horizontal, Theme.s4).frame(height: 44)
            Divider()
            content
        }
        .frame(width: width, height: height)
    }
}

// MARK: Layers

struct LayersSheet: View {
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState
    @State private var confirmDelete: Int?
    var body: some View {
        SheetFrame(title: "Layer", width: 540, height: 360) {
            VStack(spacing: 0) {
                List {
                    ForEach(ctl.config.layers.indices, id: \.self) { i in
                        HStack(spacing: Theme.s2) {
                            Circle().fill(ctl.activeLayers.contains(i) ? Theme.accent : Theme.border).frame(width: 7, height: 7).help(ctl.activeLayers.contains(i) ? "Currently enabled" : "")
                            Text("\(i)").font(Theme.mono).foregroundStyle(Theme.text2).frame(width: 16)
                            TextField("Name", text: Binding(get: { ctl.config.layers[safe: i]?.name ?? "" },
                                                           set: { v in ctl.mutate { c in if c.layers.indices.contains(i) { c.layers[i].name = v } } }))
                                .textFieldStyle(.roundedBorder).frame(width: 160)
                            Text("\(ctl.config.layers [i] .bindings.count)").font(Theme.caption).foregroundStyle(Theme.text2).frame(width: 36)
                            if i == ctl.config.defaultLayer { Label("Default", systemImage: "star.fill").font(Theme.caption).foregroundStyle(Theme.accent).labelStyle(.titleAndIcon) }
                            else { Button("Set as default") { ctl.mutate { $0.defaultLayer = i } } }
                            Spacer()
                            Menu {
                                Button("Edit this layer") { editor.editingLayer = i; editor.showLayers = false }
                                Button("Duplicate") { ctl.mutate { _ = $0.duplicateLayer(i) } }
                                Button("Clear all assignments") { ctl.mutate { $0.resetLayer(i) } }
                                Divider()
                                Button("Delete", role: .destructive) { confirmDelete = i }.disabled(i == 0)
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
                        }
                        .controlSize(.small)
                        .padding(.vertical, 2)
                    }
                }
                Divider()
                HStack {
                    Button { ctl.mutate { _ = $0.addLayer() } } label: { Label("Add Layer", systemImage: "plus") }
                    Spacer()
                    Text("Priority is given to the number above. Unconfigured buttons inherit the lower layer.").font(Theme.caption).foregroundStyle(Theme.text3)
                }
                .controlSize(.small).padding(Theme.s3)
            }
        }
        .alert("Are you sure you want to delete layer \(String(confirmDelete ?? 0))?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let i = confirmDelete { ctl.mutate { _ = $0.removeLayer(i) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("MO/TG/TO/DF referencing this layer will be None.") }
    }
}

// MARK: Macros

struct MacrosSheet: View {
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState
    var body: some View {
        SheetFrame(title: "Macros", width: 660, height: 440) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(ctl.config.macros, selection: $editor.editingMacro) { m in
                        HStack { Text(m.name).lineLimit(1); Spacer(); Text("\(m.steps.count)").font(Theme.caption).foregroundStyle(Theme.text2) }.tag(m.id)
                    }
                    .listStyle(.inset)
                    Divider()
                    HStack {
                        Button { let m = Macro(name: "Macro\(ctl.config.macros.count + 1)"); ctl.mutate { $0.macros.append(m) }; editor.editingMacro = m.id } label: { Image(systemName: "plus") }
                        Button { if let id = editor.editingMacro { editor.editingMacro = nil; ctl.mutate { $0.macros.removeAll { $0.id == id } } } } label: { Image(systemName: "minus") }.disabled(editor.editingMacro == nil)
                        Spacer()
                    }.controlSize(.small).padding(6)
                }
                .frame(width: 220)
                Divider()
                if let id = editor.editingMacro, ctl.config.macros.contains(where: { $0.id == id }) {
                    MacroEditor(macroID: id)
                } else {
                    VStack(spacing: 6) {
                        Text("Select macro or create with +").font(Theme.body).foregroundStyle(Theme.text2)
                        Text("Run multiple actions in sequence; delay after each step").font(Theme.caption).foregroundStyle(Theme.text3)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if editor.editingMacro == nil { editor.editingMacro = ctl.config.macros.first?.id } }
    }
}

struct MacroEditor: View {
    let macroID: UUID
    @EnvironmentObject var ctl: RemoteController
    @State private var editingStep: UUID?
    var macro: Macro { ctl.config.macros.first { $0.id == macroID } ?? Macro(id: macroID, name: "") }
    func edit(_ f: (inout Macro) -> Void) { ctl.mutate { c in if let i = c.macros.firstIndex(where: { $0.id == macroID }) { f(&c.macros[i]) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack {
                TextField("Name", text: Binding(get: { macro.name }, set: { v in edit { $0.name = v } })).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
                Button { ctl.executor.execute(.macro(id: macroID)) } label: { Label("Run Test", systemImage: "play.fill") }.disabled(macro.steps.isEmpty)
            }.controlSize(.small)
            SectionHeader(title: "Step")
            List {
                ForEach(Array(macro.steps.enumerated()), id: \.element.id) { i, step in
                    HStack(spacing: Theme.s2) {
                        Text("\(i + 1)").font(Theme.mono).foregroundStyle(Theme.text2).frame(width: 18)
                        Button { editingStep = step.id } label: {
                            HStack { Image(systemName: ActionKind.of(step.action).icon).foregroundStyle(Theme.accent); Text(describe(step.action)).lineLimit(1); Spacer(); Image(systemName: "pencil").foregroundStyle(Theme.text3) }
                                .padding(.horizontal, 8).frame(height: 24).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius)).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: Binding(get: { editingStep == step.id }, set: { if !$0 { editingStep = nil } })) {
                            VStack(alignment: .leading, spacing: Theme.s3) {
                                SectionHeader(title: "Step \(String(i + 1))")
                                StepActionEditor(action: Binding(get: { step.action }, set: { a in edit { if $0.steps.indices.contains(i) { $0.steps[i].action = a } } }))
                            }.padding(Theme.s4).frame(width: 340)
                        }
                        Text("Delay").font(Theme.caption).foregroundStyle(Theme.text2)
                        TextField("ms", value: Binding(get: { step.delayMs }, set: { v in edit { if $0.steps.indices.contains(i) { $0.steps[i].delayMs = max(0, v) } } }), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                        Text("ms").font(Theme.caption).foregroundStyle(Theme.text2)
                        Button { edit { if i > 0 { $0.steps.swapAt(i, i - 1) } } } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                        Button { edit { if $0.steps.indices.contains(i) { $0.steps.remove(at: i) } } } label: { Image(systemName: "trash") }
                    }
                    .controlSize(.small)
                }
                .onMove { from, to in edit { $0.steps.move(fromOffsets: from, toOffset: to) } }
            }
            .listStyle(.inset)
            HStack {
                Menu {
                    ForEach(ActionKind.allCases.filter { $0 != .macro && $0 != .transparent }) { k in
                        Button { if let a = k.defaultAction(firstMacro: nil) { edit { $0.steps.append(MacroStep(action: a)) }; editingStep = macro.steps.last?.id } } label: { Label(k.display, systemImage: k.icon) }
                    }
                } label: { Label("Add step", systemImage: "plus") }.frame(width: 150)
                Spacer()
            }.controlSize(.small)
        }
        .padding(Theme.s4)
    }
    func describe(_ a: Action) -> String { if case .shortcut(let n) = a { return n.isEmpty ? String(localized: "Shortcut not selected") : n }; return a.display }
}

/// Action editor with its own kind picker (for macro steps).
struct StepActionEditor: View {
    @Binding var action: Action
    @EnvironmentObject var ctl: RemoteController
    var body: some View {
        Picker("Type", selection: Binding(get: { ActionKind.of(action) }, set: { k in if k != ActionKind.of(action), let a = k.defaultAction(firstMacro: nil) { action = a } })) {
            ForEach(ActionKind.allCases.filter { $0 != .macro && $0 != .transparent }) { k in Label(k.display, systemImage: k.icon).tag(k) }
        }.labelsHidden()
        ActionEditor(action: $action)
    }
}

// MARK: Device

struct DeviceSheet: View {
    @EnvironmentObject var ctl: RemoteController
    var body: some View {
        SheetFrame(title: "Device", width: 660, height: 470) {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s3) {
                        SectionHeader(title: "Connect")
                        KVRow(key: "Model", value: ctl.connectedModel?.name ?? "—")
                        KVRow(key: "Vendor / Product", value: ctl.connectedProductID.map { String(format: "0x0171 / 0x%04X", $0) } ?? "—", mono: true)
                        KVRow(key: "App buttons", value: ctl.connectedModel.map { $0.hasAppButtons ? "A1–A4" : String(localized: "None") } ?? "—")
                        KVRow(key: "Status", value: status)
                        KVRow(key: "Last report", value: ctl.lastRawReport, mono: true)
                        KVRow(key: "Last button", value: ctl.lastPressed?.displayName ?? "—")
                        KVRow(key: "Unknown code", value: ctl.lastUnknownCode?.description ?? "—", mono: true)
                        HStack {
                            Button(ctl.isMonitoring ? String(localized: "Stop monitoring") : String(localized: "Start monitoring")) { ctl.setMonitoring(!ctl.isMonitoring) }
                            Menu("Simulated input") {
                                Button("Press A1") { ctl.inject(reportID: 0xEF, bytes: [0xEF, 0xA1, 0, 0]); ctl.inject(reportID: 0xEF, bytes: [0xEF, 0, 0, 0]) }
                                Button("Press A2") { ctl.inject(reportID: 0xEF, bytes: [0xEF, 0xA2, 0, 0]); ctl.inject(reportID: 0xEF, bytes: [0xEF, 0, 0, 0]) }
                                Button("Press TV") { ctl.inject(reportID: 0x02, bytes: [0x02, 0x8D, 0, 0, 0]); ctl.inject(reportID: 0x02, bytes: [0x02, 0, 0, 0, 0]) }
                            }.frame(width: 90)
                        }.controlSize(.small)
                        Divider()
                        SectionHeader(title: "Button status")
                        Text("Press \"Learn\" and then press the button on the actual machine to record the hid code. Buttons that arrive as keyboard codes remain unassignable because they are processed by macOS.").font(Theme.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        if let l = ctl.learningButton {
                            HStack { ProgressView().controlSize(.small); Text("Press \(l.displayName) on the actual machine...").font(Theme.caption); Spacer(); Button("Cancel") { ctl.learningButton = nil }.controlSize(.small) }
                                .padding(8).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radius))
                        }
                        ForEach(RemoteButton.allCases) { b in
                            let info = ctl.info(for: b)
                            HStack(spacing: Theme.s2) {
                                Text(b.displayName).font(Theme.caption).lineLimit(1).frame(width: 104, alignment: .leading)
                                Text(info.code?.description ?? "—").font(Theme.mono).foregroundStyle(Theme.text2).frame(width: 40, alignment: .leading)
                                Group {
                                    switch info.restriction {
                                    case .none: Label("Assignable", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                                    case .osHandled: Label("macOS Standard Key", systemImage: "lock.fill").foregroundStyle(Theme.warning)
                                    case .codeUnknown: Label("Not learned", systemImage: "questionmark.circle").foregroundStyle(Theme.text3)
                                    }
                                }
                                .lineLimit(1).fixedSize()
                                Spacer(minLength: 4)
                                Button("Learn") { ctl.learningButton = b }.disabled(ctl.learningButton != nil || !ctl.monitor.isRunning)
                                if ctl.config.learnedCodes[b] != nil { Button("Clear") { ctl.mutate { $0.learnedCodes.removeValue(forKey: b) } } }
                            }
                            .font(Theme.caption).controlSize(.mini)
                        }
                    }
                    .padding(Theme.s4)
                }
                .frame(width: 410)
                Divider()
                VStack(alignment: .leading, spacing: Theme.s2) {
                    HStack {
                        SectionHeader(title: "Logs")
                        Toggle("The report is also recorded", isOn: Binding(get: { ctl.config.ui.debugLog }, set: { v in ctl.mutate { $0.ui.debugLog = v } })).controlSize(.mini).toggleStyle(.checkbox)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(ctl.log.enumerated()), id: \.offset) { i, l in Text(l).font(Theme.mono).foregroundStyle(Theme.text2).id(i).textSelection(.enabled) }
                            }.padding(6)
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .onChange(of: ctl.log.count) { _, n in proxy.scrollTo(n - 1) }
                        .onAppear { proxy.scrollTo(ctl.log.count - 1) }
                    }
                }
                .padding(Theme.s3)
            }
        }
    }
    var status: String {
        switch ctl.hidStatus {
        case .connected(let n): return String(localized: "\(n) — Bluetooth connected")
        case .waitingForDevice: return String(localized: "Not connected (waiting)")
        case .blocked(let why): return "⚠ " + why
        case .stopped: return String(localized: "Not monitoring")
        }
    }
}

// MARK: Settings (⌘,)

struct SettingsView: View {
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmReset = false
    @State private var axTrusted = ActionExecutor.accessibilityTrusted
    @State private var imAccess = HIDMonitor.inputMonitoringAccess
    @State private var imCheckedAt: Date?
    @State private var language = LanguageManager.current
    @State private var showLanguageRestart = false
    var body: some View {
        Form {
            Section("General") {
                Toggle("Enable remote monitoring", isOn: Binding(get: { ctl.config.ui.monitoringEnabled }, set: { ctl.setMonitoring($0) }))
                Toggle("Autostart on login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
                        catch { loginError = error.localizedDescription; loginItem = SMAppService.mainApp.status == .enabled }
                    }
                if let e = loginError { Text(e).font(Theme.caption).foregroundStyle(Theme.danger) }
                Picker("Appearance", selection: $editor.appearance) { ForEach(EditorState.Appearance.allCases) { Text($0.label).tag($0) } }
                LabeledContent("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { l in Text(l.label).tag(l) }
                    }
                    .labelsHidden()
                }
                .onChange(of: language) { _, new in
                    guard new != LanguageManager.current else { return }
                    LanguageManager.set(new)
                    showLanguageRestart = true
                }
                if language != LanguageManager.launchedLanguage {
                    Text("Restart the app to apply the new language.")
                        .font(Theme.caption).foregroundStyle(Theme.warning)
                }
            }
            Section("Microphone (Fire TV Remote Microphone)") {
                MicSettings()
            }
            Section("Exclusive mode (remap all buttons)") {
                ExclusiveModeSettings()
            }
            Section("Permissions") {
                LabeledContent {
                    HStack {
                        Button("Request permission") { HIDMonitor.requestInputMonitoringAccess(); refreshInputMonitoring() }
                        Button("System Settings") { openInputMonitoringSettings() }
                        Button("Re-check") { refreshInputMonitoring() }
                    }
                } label: {
                    Label(inputMonitoringLabel, systemImage: inputMonitoringIcon)
                        .foregroundStyle(inputMonitoringColor)
                }
                Text("macOS applies Input Monitoring changes only after the app is restarted. After enabling Fire TV Remote Studio in System Settings, quit and reopen the app. A build signed ad-hoc loses the grant on every rebuild; remove it with − in the list and add it again, or sign with a stable identity.")
                    .font(Theme.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                if let imCheckedAt {
                    Text("Last checked \(imCheckedAt.formatted(date: .omitted, time: .standard))")
                        .font(Theme.caption).foregroundStyle(Theme.text3)
                }
                LabeledContent {
                    HStack { Button("Request permission") { ActionExecutor.promptAccessibility(); axTrusted = ActionExecutor.accessibilityTrusted }; Button("Re-check") { axTrusted = ActionExecutor.accessibilityTrusted } }
                } label: { Label(axTrusted ? String(localized: "Accessibility - Allowed") : String(localized: "Accessibility - Not allowed (required to send keys)"), systemImage: axTrusted ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(axTrusted ? Theme.success : Theme.warning) }
            }
            Section("Config data") {
                LabeledContent("Files") {
                    HStack { Text(ctl.store.url.path).font(Theme.mono).lineLimit(1).truncationMode(.middle); Button("View in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ctl.store.url]) } }
                }
                if let e = ctl.saveError { Text("Save error: \(e)").foregroundStyle(Theme.danger) }
                ForEach(ctl.startupNotices, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(Theme.warning) }
                Button("Reset to defaults…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(width: 520, height: 420)
        .alert("Are you sure you want to reset all settings to the initial state?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { ctl.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Layers, Assignments, Macros, and all learned code will disappear.") }
        .alert("Restart required", isPresented: $showLanguageRestart) {
            Button("Restart Now") { relaunchApp() }
            Button("Later", role: .cancel) {}
        } message: { Text("The display language changes after the app restarts.") }
    }

    private var inputMonitoringLabel: String {
        switch imAccess {
        case .granted: return String(localized: "Input monitoring: allowed")
        case .denied: return String(localized: "Input monitoring: denied (required to read remote)")
        case .unknown: return String(localized: "Input monitoring: not determined")
        }
    }
    private var inputMonitoringIcon: String {
        switch imAccess {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
    private var inputMonitoringColor: Color {
        switch imAccess {
        case .granted: return Theme.success
        case .denied: return Theme.danger
        case .unknown: return Theme.warning
        }
    }
    private func refreshInputMonitoring() {
        imAccess = HIDMonitor.inputMonitoringAccess
        imCheckedAt = Date()
    }
    private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    private func relaunchApp() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.0; /usr/bin/open -n \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}


/// Helper (LaunchDaemon) install state + the exclusive toggle.
struct ExclusiveModeSettings: View {
    @EnvironmentObject var ctl: RemoteController
    @State private var state = HelperClient.installState
    @State private var error: String?
    var body: some View {
        Group {
            Text("In normal mode, buttons macOS handles first (volume, arrows, etc.) cannot be assigned. In exclusive mode, the bundled helper (root LaunchDaemon) seizes only the remote, allowing all buttons to be assigned. Other keyboards/mice are unaffected.").font(Theme.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            LabeledContent("helper") {
                HStack {
                    Text(stateText).font(Theme.caption).foregroundStyle(state == .enabled ? Theme.success : Theme.warning)
                    if state != .enabled { Button("Register") { register() } }
                    if state == .requiresApproval { Button("Open System Settings") { HelperClient.openApprovalSettings() } }
                    Button("Re-check") { refresh() }
                    if state == .enabled { Button("Unregister") { try? HelperClient.unregister(); refresh() } }
                }
            }
            if let e = error { Text(e).font(Theme.caption).foregroundStyle(Theme.danger) }
            Toggle("Use exclusive mode (when helper enabled)", isOn: Binding(get: { ctl.exclusiveRequested }, set: { ctl.setExclusive($0) }))
                .disabled(state != .enabled)
            Text(ctl.exclusiveActive ? String(localized: "Operating in ● exclusive mode (remote is not visible from macOS. Unlock by exiting the app and stopping monitoring)") : String(localized: "Operating in ○ Normal Mode")).font(Theme.caption).foregroundStyle(ctl.exclusiveActive ? Theme.success : Theme.text2)
        }
        .onAppear { refresh() }
    }
    var stateText: String {
        switch state {
        case .enabled: return String(localized: "Enabled")
        case .requiresApproval: return String(localized: "Pending approval: enable FireTVRemoteBridge in System Settings → General → Login Items & Extensions → \"Allow in background\"")
        case .notRegistered: return String(localized: "Not registered")
        case .notFound: return String(localized: "helper not found (rebuild in build-app.sh)")
        case .unknown: return String(localized: "Unknown")
        }
    }
    func refresh() { state = HelperClient.installState; if state == .enabled, ctl.exclusiveRequested, !ctl.exclusiveActive, ctl.config.ui.monitoringEnabled { ctl.setExclusive(true) } }
    func register() { do { try HelperClient.register(); error = nil } catch { self.error = error.localizedDescription }; refresh() }
}


/// Virtual microphone: enable toggle, driver/device status, install/repair/uninstall.
struct MicSettings: View {
    @EnvironmentObject var ctl: RemoteController
    @State private var installed = RemoteController.micDriverInstalled
    @State private var present = RemoteController.micDevicePresent
    @State private var message: String?
    @State private var busy = false
    @State private var confirmUninstall = false
    var body: some View {
        Group {
            Text("Only while pressing the microphone button on the remote control, the voice enters the macOS input device \"Fire TV Remote Microphone\" (Push-to-Talk). Once you've selected this device in Discord, QuickTime, and more, you can use it with the push of a button.").font(Theme.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Toggle("Enable microphone feature", isOn: Binding(get: { ctl.micEnabled }, set: { ctl.setMicEnabled($0) }))
            LabeledContent("Driver") {
                HStack {
                    Label(installed ? (present ? String(localized: "Installed and recognized") : String(localized: "Installed (device not recognized: recover after restart)")) : String(localized: "Not installed"), systemImage: installed && present ? "checkmark.circle.fill" : "xmark.circle")
                        .font(Theme.caption).foregroundStyle(installed && present ? Theme.success : Theme.warning)
                    Button(installed ? String(localized: "Repair (reinstall)") : String(localized: "Install")) { install() }.disabled(busy)
                    Button("Re-check") { refresh() }
                    if installed { Button("Uninstall…") { confirmUninstall = true }.disabled(busy) }
                }
            }
            HStack(spacing: 10) {
                Text(stateText).font(Theme.caption).foregroundStyle(ctl.micState == .listening ? Theme.accent : Theme.text2)
                if ctl.micState == .listening || ctl.micStats.packets > 0 {
                    Text("Packet\(ctl.micStats.packets) · Interpolation\(ctl.micStats.plcFrames) · Error\(ctl.micStats.decodeErrors)").font(Theme.caption).foregroundStyle(Theme.text3)
                }
            }
            if let e = ctl.micLastError { Text(e).font(Theme.caption).foregroundStyle(Theme.danger) }
            if let m = message { Text(m).font(Theme.caption).foregroundStyle(Theme.text2) }
            if !ctl.micStats.ringAvailable && ctl.micEnabled { Text("Cannot open shared buffer \(ctl.mic.ringPath). Recreate it with \"Repair\".").font(Theme.caption).foregroundStyle(Theme.danger) }
        }
        .onAppear { refresh() }
        .alert("Do you want to uninstall the virtual microphone?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Delete Hal driver and shared buffer, helper registration. The app body and settings will remain.") }
    }
    var stateText: String {
        switch ctl.micState {
        case .disabled: return String(localized: "○ Disabled")
        case .ready: return String(localized: "● Waiting (enter with microphone button)")
        case .listening: return String(localized: "● Input in progress")
        case .draining: return String(localized: "● Input in progress (termination process)")
        }
    }
    func refresh() { installed = RemoteController.micDriverInstalled; present = RemoteController.micDevicePresent }
    func runAsAdmin(_ script: String, args: [String], done: @escaping (String?) -> Void) {
        busy = true
        let res = Bundle.main.resourcePath ?? ""
        // Reject paths containing characters that could break the AppleScript string or shell quoting.
        let unsafe: (String) -> Bool = { $0.contains("\"") || $0.contains("\\") || $0.contains("\n") || $0.contains("\r") }
        guard !unsafe(res), !unsafe(script), !args.contains(where: unsafe) else {
            busy = false
            done(String(localized: "Invalid path"))
            return
        }
        let cmd = ([res + "/" + script] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let src = "do shell script \"/bin/sh \(cmd)\" with administrator privileges"
        DispatchQueue.global().async {
            var err: NSDictionary?
            let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                busy = false
                done(err != nil ? (err?["NSAppleScriptErrorMessage"] as? String ?? String(localized: "Failed")) : out?.stringValue)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { refresh(); ctl.mic.prepare() }
            }
        }
    }
    func install() {
        let drv = (Bundle.main.resourcePath ?? "") + "/FireTVRemoteMicrophone.driver"
        runAsAdmin("install-mic-driver.sh", args: [drv]) { message = $0.map { String(localized: "Installation:\($0). If the device is not visible, wait a few seconds and \"reconfirm\"") } }
    }
    func uninstall() {
        try? HelperClient.unregister()
        runAsAdmin("uninstall.sh", args: []) { message = $0 }
    }
}

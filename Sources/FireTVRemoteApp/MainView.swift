import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FireTVCore

/// Single-window editor: top bar (device + layers) / remote canvas / inspector.
struct MainView: View {
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            GeometryReader { geo in
                let compact = geo.size.width < 820
                HStack(spacing: 0) {
                    RemoteCanvas()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.windowBG)
                    Divider()
                    InspectorView()
                        .frame(width: compact ? 300 : Theme.inspectorW)
                        .background(Theme.panelBG)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .overlay(alignment: .bottom) { Toasts() }
        .onChange(of: ctl.lastPressed) { _, b in if editor.followRemote, let b { withAnimation(Theme.anim) { editor.selectedButton = b } } }
        .onChange(of: ctl.config.layers.count) { _, n in if editor.editingLayer >= n { editor.editingLayer = max(0, n - 1) } }
        .sheet(isPresented: $editor.showLayers) { LayersSheet() }
        .sheet(isPresented: $editor.showMacros) { MacrosSheet() }
        .sheet(isPresented: $editor.showDevice) { DeviceSheet() }
    }
}

struct TopBar: View {
    @EnvironmentObject var ctl: RemoteController
    @EnvironmentObject var editor: EditorState

    var body: some View {
        HStack(spacing: Theme.s3) {
            // Device
            Button { editor.showDevice = true } label: {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "tv.and.mediabox").font(.system(size: 14, weight: .medium))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Amazon Remote").font(Theme.bodyStrong).lineLimit(1).fixedSize()
                        HStack(spacing: 5) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(statusText).font(Theme.caption).foregroundStyle(Theme.text2).lineLimit(1).fixedSize()
                            if ctl.exclusiveActive { Text("Exclusive").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent).padding(.horizontal, 4).background(Theme.accent.opacity(0.15), in: Capsule()).help("helper Dedicated Remote: Remap All Buttons") }
                        }
                    }
                }
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help("Open device details, button learning, and log")
            .accessibilityLabel("Device: \(statusText)")

            Divider().frame(height: 22)
            MicPill()
            Divider().frame(height: 22)

            // Active layer (runtime) vs editing layer (design)
            HStack(spacing: 6) {
                Text("Active:").font(Theme.caption).foregroundStyle(Theme.text2)
                Text(activeLayerName).font(Theme.bodyStrong).foregroundStyle(Theme.accent).lineLimit(1)
                    .help("Currently active layer. Unset buttons inherit downward: \(activeLayerStack)")
            }

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                Text("Edit:").font(Theme.caption).foregroundStyle(Theme.text2)
                Picker("Layer to edit", selection: $editor.editingLayer) {
                    ForEach(ctl.config.layers.indices, id: \.self) { i in
                        Text("\(i) · \(ctl.config.layers[i].name)" + (i == ctl.config.defaultLayer ? "  ★" : "")).tag(i)
                    }
                }
                .labelsHidden().frame(width: 160)
                Button { editor.showLayers = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Manage layers (add, name, default)")
            }

            Spacer()

            Toggle(isOn: $editor.followRemote) { Label("Follow physical device", systemImage: "dot.radiowaves.left.and.right").font(Theme.caption) }
                .toggleStyle(.button).controlSize(.small)
                .help("On: Press the button on the remote control to select it on the screen")

            Button { editor.showMacros = true } label: { Label("Macros", systemImage: "list.bullet.rectangle") }
            Menu {
                Button("Export settings…") { exportConfig() }
                Button("Import settings…") { importConfig() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 28)
            SettingsLink { Image(systemName: "gearshape") }.help("Settings (⌘,)")
        }
        .controlSize(.small)
        .lineLimit(1)
        .padding(.horizontal, Theme.s4).frame(height: 48)
        .background(Theme.panelBG)
    }

    var statusColor: Color {
        switch ctl.hidStatus { case .connected: return Theme.success; case .waitingForDevice: return Theme.warning; case .blocked: return Theme.danger; case .stopped: return Theme.text3 }
    }
    var statusText: String {
        switch ctl.hidStatus {
        case .connected: return String(localized: "Bluetooth Connecting")
        case .waitingForDevice: return String(localized: "Not connected, waiting")
        case .blocked: return String(localized: "Cannot open (details)")
        case .stopped: return String(localized: "Not monitoring")
        }
    }
    /// The layer in charge right now (highest priority). The full stack goes in the tooltip.
    var activeLayerName: String { ctl.activeLayers.first.flatMap { ctl.config.layers[safe: $0]?.name } ?? "-" }
    var activeLayerStack: String { ctl.activeLayers.compactMap { ctl.config.layers[safe: $0]?.name }.joined(separator: " → ") }

    func exportConfig() {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = "firetv-remote-config.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try ctl.exportConfig().write(to: url) } catch { NSAlert(error: error).runModal() }
    }
    func importConfig() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try ctl.importConfig(from: try Data(contentsOf: url)) }
        catch { let a = NSAlert(); a.messageText = "You're out of imports"; a.informativeText = error.localizedDescription; a.alertStyle = .warning; a.runModal() }
    }
}

struct Toasts: View {
    @EnvironmentObject var ctl: RemoteController
    var body: some View {
        VStack(spacing: 6) {
            ForEach(ctl.executing, id: \.self) { s in
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(s).font(Theme.caption) }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Theme.panelBG, in: Capsule()).overlay(Capsule().stroke(Theme.border))
            }
            if let e = ctl.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    Text(e).font(Theme.caption).lineLimit(2)
                    Button { ctl.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.panelBG, in: RoundedRectangle(cornerRadius: Theme.radiusL)).overlay(RoundedRectangle(cornerRadius: Theme.radiusL).stroke(Theme.danger.opacity(0.5)))
                .frame(maxWidth: 520)
            }
        }
        .padding(.bottom, Theme.s4)
        .animation(Theme.anim, value: ctl.executing)
        .animation(Theme.anim, value: ctl.lastError)
    }
}


/// Compact microphone status in the top bar: disabled / ready / listening (with level).
struct MicPill: View {
    @EnvironmentObject var ctl: RemoteController
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ctl.micState == .listening ? "mic.fill" : "mic").font(.system(size: 12, weight: .medium))
                .foregroundStyle(ctl.micState == .listening ? Theme.accent : (ctl.micState == .disabled ? Theme.text3 : Theme.text2))
            Text(label).font(Theme.caption).foregroundStyle(ctl.micState == .disabled ? Theme.text3 : Theme.text2).lineLimit(1).fixedSize()
            if ctl.micState == .listening || ctl.micState == .draining {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface)
                        Capsule().fill(Theme.accent).frame(width: g.size.width * CGFloat(min(1, ctl.micLevel * 4)))
                    }
                }.frame(width: 48, height: 6)
            }
        }
        .help(help)
        .accessibilityLabel("Microphone:\(label)")
    }
    var label: String {
        switch ctl.micState {
        case .disabled: return String(localized: "Mic: Off")
        case .ready: return RemoteController.micDevicePresent ? String(localized: "Microphone Idle") : String(localized: "No microphone introduced")
        case .listening: return String(localized: "Listening")
        case .draining: return String(localized: "Listening")
        }
    }
    var help: String {
        switch ctl.micState {
        case .disabled: return String(localized: "When mic is enabled in settings, voice enters \"Fire TV Remote Microphone\" only while mic button is held")
        case .ready: return RemoteController.micDevicePresent ? String(localized: "The voice only enters the \"Fire TV Remote Microphone\" while pressing the microphone button") : String(localized: "Virtual microphone driver not installed (setup → microphone)")
        default: return String(localized: "Sending remote control voice to virtual microphone")
        }
    }
}

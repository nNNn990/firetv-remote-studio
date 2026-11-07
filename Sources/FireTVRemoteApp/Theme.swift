import SwiftUI
import AppKit

/// Design tokens. Semantic system colors adapt to light/dark; the accent is the app's own.
enum Theme {
    // Surfaces
    static let windowBG   = Color(nsColor: .windowBackgroundColor)
    static let panelBG    = Color(nsColor: .controlBackgroundColor)
    static let surface    = Color.primary.opacity(0.05)       // cards, rows
    static let surfaceHover = Color.primary.opacity(0.09)
    static let separator  = Color(nsColor: .separatorColor)
    static let border     = Color.primary.opacity(0.12)
    // Text
    static let text       = Color.primary
    static let text2      = Color.secondary
    static let text3      = Color(nsColor: .tertiaryLabelColor)
    // Accent + states
    static let accent     = Color(red: 1.00, green: 0.46, blue: 0.10)
    static let success    = Color(nsColor: .systemGreen)
    static let warning    = Color(nsColor: .systemYellow)
    static let danger     = Color(nsColor: .systemRed)
    // Type scale
    static let title      = Font.system(size: 15, weight: .semibold)
    static let heading    = Font.system(size: 12, weight: .semibold)
    static let body       = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .medium)
    static let caption    = Font.system(size: 11)
    static let mono       = Font.system(size: 11, design: .monospaced)
    // Metrics
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 24
    static let radius: CGFloat = 6
    static let radiusL: CGFloat = 10
    static let controlH: CGFloat = 28
    static let inspectorW: CGFloat = 340
    static let anim = Animation.easeOut(duration: 0.12)
}

/// Section header inside the inspector.
struct SectionHeader: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(Theme.heading).foregroundStyle(Theme.text2)
            .textCase(.uppercase).kerning(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small rounded status pill (● text).
struct StatusPill: View {
    let text: LocalizedStringKey
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.caption).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 9).frame(height: 22)
        .background(Theme.surface, in: Capsule())
    }
}

/// Informational banner (warning / info).
struct Banner: View {
    let icon: String
    let text: LocalizedStringKey
    var color: Color = Theme.warning
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12)).padding(.top, 1)
            Text(text).font(Theme.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Key/value row used in inspector and device sheet.
struct KVRow: View {
    let key: LocalizedStringKey
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(Theme.caption).foregroundStyle(Theme.text2).frame(width: 96, alignment: .leading)
            Text(value).font(mono ? Theme.mono : Theme.caption).foregroundStyle(Theme.text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

import Foundation

/// A Fire TV remote model the app knows how to talk to.
///
/// All of them use Amazon's Bluetooth vendor ID (`0x0171`) and the same
/// keyboard / consumer / microphone report layout; they differ only in the
/// product ID and in whether they expose the four app buttons
/// (vendor report `0xEF`).
public struct FireTVRemoteModel: Sendable, Equatable, Identifiable {
    public let productID: Int
    public let name: String
    /// Report `0xEF` (A1–A4 app buttons). The 2nd-generation Voice Remote
    /// has no app buttons, so the report is absent from its HID descriptor.
    public let hasAppButtons: Bool

    public var id: Int { productID }

    public init(productID: Int, name: String, hasAppButtons: Bool) {
        self.productID = productID
        self.name = name
        self.hasAppButtons = hasAppButtons
    }

    public static let all: [FireTVRemoteModel] = [
        FireTVRemoteModel(productID: 0x042F, name: "Fire TV Voice Remote (3rd Gen)", hasAppButtons: true),
        FireTVRemoteModel(productID: 0x0413, name: "Fire TV Voice Remote (2nd Gen)", hasAppButtons: false),
    ]

    public static func model(for productID: Int) -> FireTVRemoteModel? {
        all.first { $0.productID == productID }
    }

    /// Friendly name for logs and the UI; unknown product IDs keep Amazon's
    /// own product string ("AR" on the 2nd-generation remote).
    public static func name(for productID: Int, fallback: String = "Amazon Remote") -> String {
        model(for: productID)?.name ?? fallback
    }
}

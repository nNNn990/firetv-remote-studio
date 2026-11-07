import Foundation
import Security

/// XPC contract between the app and the privileged helper (LaunchDaemon).
public enum FireTVIPC {
    public static let machServiceName = "com.uaaa.firetv-remote-bridge.helper"
    public static let daemonPlistName = "com.uaaa.firetv-remote-bridge.helper.plist"
    public static let protocolVersion = 4
    public static let vendorID = 0x0171
    /// Every supported remote model. The app and the privileged helper must
    /// match all of them, otherwise exclusive mode stays blind to newer remotes.
    public static let productIDs: [Int] = FireTVRemoteModel.all.map(\.productID)
    /// Legacy single-product constant (3rd generation). Prefer `productIDs`.
    public static let productID = 0x042F
    /// Team identifier of the running process (nil for ad-hoc / unsigned builds).
    public static var ownTeamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// XPC code-signing requirement for clients of the helper. Only processes signed by the same
    /// Apple Developer team as the helper may connect. For ad-hoc builds (no team) the requirement
    /// falls back to the app's bundle identifier, which only guards against accidental connections.
    public static var codeSigningRequirement: String {
        if let team = ownTeamIdentifier {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        return "identifier \"\(appBundleIdentifier)\""
    }
    public static let appBundleIdentifier = "com.uaaa.firetv-remote-bridge"
}

/// Implemented by the helper (root). Called by the app.
@objc public protocol FireTVHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    /// Seize the remote and start forwarding reports to the connecting app.
    func start(reply: @escaping (Int32, String) -> Void)
    /// Release the device so macOS handles it again.
    func stop(reply: @escaping () -> Void)
    /// Send an OUTPUT report (e.g. 0xF2 mic enable). `data` must start with the report ID.
    func setOutputReport(reportID: Int, data: Data, reply: @escaping (Int32) -> Void)
    /// Exit the helper process (launchd relaunches it on the next connection) — used after app updates.
    func quit()
}

/// Implemented by the app. Called by the helper.
@objc public protocol FireTVHelperClientProtocol {
    func didReceiveReport(reportID: Int, bytes: Data)
    /// status: 0 waiting, 1 connected(seized), 2 blocked
    func statusChanged(status: Int, message: String)
    func log(_ message: String)
}

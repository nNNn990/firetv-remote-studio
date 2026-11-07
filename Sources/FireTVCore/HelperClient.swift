import Foundation
import ServiceManagement
import FireTVIPC

/// App-side client for the privileged helper. Presents the same `HIDMonitor.Event` stream.
public final class HelperClient: NSObject, FireTVHelperClientProtocol {
    public var onEvent: (HIDMonitor.Event) -> Void = { _ in }
    public private(set) var status: HIDMonitor.Status = .stopped { didSet { if status != oldValue { onEvent(.status(status)) } } }
    public private(set) var isRunning = false
    private var connection: NSXPCConnection?

    public override init() { super.init() }

    // MARK: install / approval (SMAppService LaunchDaemon)

    public static var service: SMAppService { SMAppService.daemon(plistName: FireTVIPC.daemonPlistName) }
    public enum InstallState: Equatable { case notRegistered, requiresApproval, enabled, notFound, unknown }
    public static var installState: InstallState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .enabled: return .enabled
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    /// Registers the LaunchDaemon. macOS then asks the user to allow it under
    /// System Settings > General > Login Items & Extensions. Throws on failure.
    public static func register() throws { try service.register() }
    public static func unregister() throws { try service.unregister() }
    public static func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: lifecycle

    public func start() {
        guard !isRunning else { return }
        let c = NSXPCConnection(machServiceName: FireTVIPC.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FireTVHelperProtocol.self)
        c.exportedInterface = NSXPCInterface(with: FireTVHelperClientProtocol.self)
        c.exportedObject = self
        c.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.handleLost(String(localized: "helper disconnected")) } }
        c.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.handleLost(String(localized: "helper interrupted")) } }
        c.resume()
        connection = c
        isRunning = true
        status = .waitingForDevice
        onEvent(.log(String(localized: "Exclusive mode: connecting to helper")))
        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            DispatchQueue.main.async { self?.status = .blocked(String(localized: "unable to connect to helper:\(err.localizedDescription). Please enable helper in settings")) }
        } as? FireTVHelperProtocol
        proxy?.version { [weak self] v in
            DispatchQueue.main.async {
                guard let self else { return }
                if v != FireTVIPC.protocolVersion {
                    // Older helper still resident: ask it to exit (v2+), launchd restarts the new one on reconnect.
                    if v >= 2 { proxy?.quit() }
                    self.isRunning = false; self.connection = nil
                    c.invalidate()
                    self.status = .blocked(String(localized: "the helper was an older version (\(String(v))). Reconnect to the new helper"))
                    return
                }
                proxy?.start { code, msg in DispatchQueue.main.async { self.onEvent(.log(String(localized: "helper start: \(msg)"))) } }
            }
        }
    }

    /// Sends an OUTPUT report through the helper. Completion carries the IOReturn.
    public func setOutputReport(id: UInt8, data: [UInt8], completion: @escaping (Int32) -> Void) {
        guard let c = connection, let proxy = c.remoteObjectProxyWithErrorHandler({ _ in DispatchQueue.main.async { completion(Int32(bitPattern: 0xe00002bc)) } }) as? FireTVHelperProtocol else { completion(Int32(bitPattern: 0xe00002c0)); return }
        proxy.setOutputReport(reportID: Int(id), data: Data(data)) { r in DispatchQueue.main.async { completion(r) } }
    }

    public func stop() {
        guard isRunning else { return }
        let c = connection
        connection = nil
        isRunning = false
        (c?.remoteObjectProxy as? FireTVHelperProtocol)?.stop { c?.invalidate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c?.invalidate() }
        status = .stopped
        onEvent(.log(String(localized: "Exclusive mode: stopped (device released)")))
    }

    private func handleLost(_ why: String) {
        guard isRunning else { return }
        isRunning = false; connection = nil
        status = .blocked(why)
    }

    // MARK: FireTVHelperClientProtocol (called by the helper)

    public func didReceiveReport(reportID: Int, bytes: Data) {
        let arr = [UInt8](bytes)
        DispatchQueue.main.async { self.onEvent(.report(reportID: UInt8(truncatingIfNeeded: reportID), bytes: arr)) }
    }
    public func statusChanged(status: Int, message: String) {
        DispatchQueue.main.async {
            switch status {
            case 1: self.status = .connected(name: message)
            case 2: self.status = .blocked(message)
            default: self.status = .waitingForDevice
            }
        }
    }
    public func log(_ message: String) { DispatchQueue.main.async { self.onEvent(.log(message)) } }
}

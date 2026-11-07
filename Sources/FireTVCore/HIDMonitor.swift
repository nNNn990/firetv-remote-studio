import Foundation
import IOKit
import IOKit.hid
import FireTVIPC

/// Owns the IOHIDManager for the Amazon Remote. Exactly one instance per process;
/// the GUI app is the only process that should run it (opening the device twice
/// from two processes is refused by IOKit anyway).
public final class HIDMonitor {
    public static let vendorID = FireTVIPC.vendorID
    /// All supported Fire TV remote models (2nd gen `0x0413`, 3rd gen `0x042F`).
    public static let productIDs = FireTVIPC.productIDs
    public static var supportedModels: [FireTVRemoteModel] { FireTVRemoteModel.all }
    public static func modelName(for productID: Int) -> String { FireTVRemoteModel.name(for: productID) }

    public enum Status: Equatable {
        case stopped
        case waitingForDevice
        case connected(name: String)
        case blocked(String)   // device present but cannot be opened; retrying
    }
    public enum Event: Equatable {
        case status(Status)
        case report(reportID: UInt8, bytes: [UInt8])
        case log(String)
    }

    public var onEvent: (Event) -> Void = { _ in }
    public private(set) var status: Status = .stopped { didSet { if status != oldValue { onEvent(.status(status)) } } }
    public private(set) var isRunning = false

    private var manager: IOHIDManager?
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var pending = Set<IOHIDDevice>()
    private var opened = Set<IOHIDDevice>()
    private var retry: DispatchSourceTimer?
    private let bufferSize = 256   // 0xF0 audio reports are 81 bytes

    /// Product ID of the remote currently open, and its known model if any.
    public private(set) var connectedProductID: Int?
    public var connectedModel: FireTVRemoteModel? {
        connectedProductID.flatMap { FireTVRemoteModel.model(for: $0) }
    }

    public init() {}

    /// Input Monitoring (TCC) state for this process.
    public enum InputMonitoringAccess: String, Sendable {
        case granted
        case denied
        case unknown
    }
    public static var inputMonitoringAccess: InputMonitoringAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }
    public static var hasInputMonitoringAccess: Bool { inputMonitoringAccess == .granted }
    /// Shows the macOS prompt that adds this app to Privacy & Security > Input Monitoring.
    @discardableResult public static func requestInputMonitoringAccess() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

    public func start() {
        guard !isRunning else { return }
        let access = Self.inputMonitoringAccess
        if access != .granted {
            onEvent(.log(String(localized: "Input monitoring: \(access.rawValue) — requesting system dialog. Quit and reopen after granting.")))
            Self.requestInputMonitoringAccess()
        }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = Self.productIDs.map {
            [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue().deviceMatched(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = m
        isRunning = true
        status = .waitingForDevice
        let ids = Self.productIDs.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
        onEvent(.log(String(localized: "Start monitoring (vid 0x0171 / pid \(ids))")))
    }

    public func stop() {
        guard isRunning, let m = manager else { return }
        retry?.cancel(); retry = nil
        for d in opened { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        for (_, b) in buffers { b.deallocate() }
        opened = []; buffers = [:]; pending = []
        connectedProductID = nil
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        isRunning = false
        status = .stopped
        onEvent(.log(String(localized: "Stop monitoring")))
    }

    /// OUTPUT report to the open device (non-exclusive mode). Buffer must begin with the report ID on macOS BLE HID.
    public func setOutputReport(id: UInt8, data: [UInt8]) -> IOReturn {
        guard let d = opened.first else { return kIOReturnNoDevice }
        var bytes = data
        if bytes.first != id { bytes.insert(id, at: 0) }
        return bytes.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(id), $0.baseAddress!, $0.count) }
    }

    private func productID(_ d: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    }

    /// Amazon's own product string ("AR" on the 2nd-generation remote).
    private func rawName(_ d: IOHIDDevice) -> String {
        (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "Amazon Remote"
    }

    /// Friendly model name, falling back to Amazon's product string.
    private func name(_ d: IOHIDDevice) -> String {
        FireTVRemoteModel.name(for: productID(d), fallback: rawName(d))
    }

    private func deviceMatched(_ d: IOHIDDevice) {
        onEvent(.log(String(localized: "Connected: \(name(d)) [\(rawName(d)) \(String(format: "0x%04X", productID(d)))]")))
        pending.insert(d)
        if !tryOpen(d) { scheduleRetry() }
    }

    private func deviceRemoved(_ d: IOHIDDevice) {
        buffers.removeValue(forKey: d)?.deallocate()
        opened.remove(d); pending.remove(d)
        onEvent(.log(String(localized: "Disconnected: \(name(d))")))
        if opened.isEmpty { connectedProductID = nil }
        status = .waitingForDevice
    }

    @discardableResult
    private func tryOpen(_ d: IOHIDDevice) -> Bool {
        if opened.contains(d) { return true }
        let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        switch r {
        case kIOReturnSuccess:
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            buffers[d] = buf
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(d, buf, bufferSize, { ctx, result, _, _, reportID, report, length in
                guard result == kIOReturnSuccess, length > 0 else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
                Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue()
                    .onEvent(.report(reportID: UInt8(truncatingIfNeeded: reportID), bytes: bytes))
            }, ctx)
            opened.insert(d)
            connectedProductID = productID(d)
            status = .connected(name: name(d))
            onEvent(.log(String(localized: "Device opened: \(name(d))")))
            return true
        case kIOReturnExclusiveAccess:
            status = .blocked(String(localized: "Another process holds the remote (turn off Modify events for Amazon Remote in Karabiner-Elements, or quit old CLI)"))
        case kIOReturnNotPermitted:
            status = .blocked(String(localized: "No input monitoring permission. Allow this app in System Settings > Privacy & Security > Input Monitoring"))
        default:
            status = .blocked(String(format: String(localized: "Cannot open device (0x%08x)"), UInt32(bitPattern: r)))
        }
        return false
    }

    private func scheduleRetry() {
        if retry != nil { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let todo = self.pending.filter { !self.opened.contains($0) }
            if todo.isEmpty { self.retry?.cancel(); self.retry = nil; return }
            for d in todo where self.tryOpen(d) { self.onEvent(.log(String(localized: "Device became available"))) }
        }
        t.resume(); retry = t
    }
}

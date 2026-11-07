// FireTVHelper — LaunchDaemon (root). Seizes the Fire TV remote exclusively so macOS
// receives nothing from it, and forwards raw HID reports to the app over XPC.
// The device is released whenever the app disconnects, stops, or this process exits.
import Foundation
import IOKit
import IOKit.hid
import FireTVIPC

final class Seizer {
    private var manager: IOHIDManager?
    private var opened: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var pending = Set<IOHIDDevice>()
    private var retry: DispatchSourceTimer?
    var client: FireTVHelperClientProtocol?

    func start() -> (Int32, String) {
        if manager != nil { return (0, "already running") }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = FireTVIPC.productIDs.map {
            [kIOHIDVendorIDKey: FireTVIPC.vendorID, kIOHIDProductIDKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in Unmanaged<Seizer>.fromOpaque(ctx!).takeUnretainedValue().matched(dev) }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in Unmanaged<Seizer>.fromOpaque(ctx!).takeUnretainedValue().removed(dev) }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = m
        client?.statusChanged(status: 0, message: "waiting for device")
        return (0, "started")
    }

    func stop() {
        retry?.cancel(); retry = nil
        for (d, buf) in opened { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)); buf.deallocate() }
        opened = [:]; pending = []
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        client?.log("helper: device released")
    }

    /// OUTPUT report to the seized device. macOS BLE HID needs the report ID as the first byte of the buffer.
    func setOutputReport(id: Int, data: Data) -> Int32 {
        guard let d = opened.keys.first else { return Int32(bitPattern: 0xe00002c0) }   // kIOReturnNoDevice
        var bytes = [UInt8](data)
        if bytes.first != UInt8(truncatingIfNeeded: id) { bytes.insert(UInt8(truncatingIfNeeded: id), at: 0) }
        return bytes.withUnsafeMutableBufferPointer { IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(id), $0.baseAddress!, $0.count) }
    }

    private func productID(_ d: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    }

    private func rawName(_ d: IOHIDDevice) -> String {
        (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "Amazon Remote"
    }

    /// Friendly model name, sent to the app as the connected-device status.
    private func name(_ d: IOHIDDevice) -> String {
        FireTVRemoteModel.name(for: productID(d), fallback: rawName(d))
    }

    private func matched(_ d: IOHIDDevice) {
        pending.insert(d)
        client?.log("helper: device matched \(name(d)) [\(rawName(d)) \(String(format: "0x%04X", productID(d)))]")
        if !tryOpen(d) { scheduleRetry() }
    }
    private func removed(_ d: IOHIDDevice) {
        opened.removeValue(forKey: d)?.deallocate(); pending.remove(d)
        client?.statusChanged(status: 0, message: "device disconnected")
    }

    @discardableResult
    private func tryOpen(_ d: IOHIDDevice) -> Bool {
        if opened[d] != nil { return true }
        let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard r == kIOReturnSuccess else {
            let why: String
            switch r {
            case kIOReturnExclusiveAccess: why = "Another process holds it (turn off Modify events in Karabiner-Elements)"
            case kIOReturnNotPrivileged: why = "Insufficient privileges (helper not running as root)"
            default: why = String(format: "IOHIDDeviceOpen(seize) failed 0x%08x", UInt32(bitPattern: r))
            }
            client?.statusChanged(status: 2, message: why)
            return false
        }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)   // 0xF0 audio reports are 81 bytes
        opened[d] = buf
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, buf, 256, { ctx, result, _, _, reportID, report, length in
            guard result == kIOReturnSuccess, length > 0 else { return }
            let data = Data(bytes: report, count: Int(length))
            Unmanaged<Seizer>.fromOpaque(ctx!).takeUnretainedValue().client?.didReceiveReport(reportID: Int(reportID), bytes: data)
        }, ctx)
        client?.statusChanged(status: 1, message: name(d))
        client?.log("helper: seized \(name(d))")
        return true
    }
    private func scheduleRetry() {
        if retry != nil { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let todo = self.pending.filter { self.opened[$0] == nil }
            if todo.isEmpty { self.retry?.cancel(); self.retry = nil; return }
            for d in todo { self.tryOpen(d) }
        }
        t.resume(); retry = t
    }
}

final class HelperService: NSObject, FireTVHelperProtocol, NSXPCListenerDelegate {
    let seizer = Seizer()
    private var active: NSXPCConnection?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        if #available(macOS 13.0, *) { c.setCodeSigningRequirement(FireTVIPC.codeSigningRequirement) }
        c.exportedInterface = NSXPCInterface(with: FireTVHelperProtocol.self)
        c.exportedObject = self
        c.remoteObjectInterface = NSXPCInterface(with: FireTVHelperClientProtocol.self)
        c.invalidationHandler = { [weak self, weak c] in
            DispatchQueue.main.async {
                guard let self, let c, self.active === c else { return }
                self.active = nil; self.seizer.client = nil
                self.seizer.stop()        // app went away: give the device back to macOS
            }
        }
        c.interruptionHandler = c.invalidationHandler
        DispatchQueue.main.async {
            self.active?.invalidate()     // one app at a time
            self.active = c
            self.seizer.client = c.remoteObjectProxy as? FireTVHelperClientProtocol
        }
        c.resume()
        return true
    }
    func version(reply: @escaping (Int) -> Void) { reply(FireTVIPC.protocolVersion) }
    func start(reply: @escaping (Int32, String) -> Void) { DispatchQueue.main.async { let r = self.seizer.start(); reply(r.0, r.1) } }
    func stop(reply: @escaping () -> Void) { DispatchQueue.main.async { self.seizer.stop(); reply() } }
    func quit() { DispatchQueue.main.async { self.seizer.stop(); exit(0) } }
    func setOutputReport(reportID: Int, data: Data, reply: @escaping (Int32) -> Void) {
        DispatchQueue.main.async { reply(self.seizer.setOutputReport(id: reportID, data: data)) }
    }
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: FireTVIPC.machServiceName)
listener.delegate = service
listener.resume()
signal(SIGTERM) { _ in exit(0) }   // device is released by the kernel when the process dies
RunLoop.main.run()

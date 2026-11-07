import Foundation
import AVFoundation
import COpus
import CMicRing

/// Decodes the remote's Opus voice packets (16 kHz mono, 20 ms) and streams 48 kHz Float32 PCM
/// into the shared ring read by the "Fire TV Remote Microphone" HAL driver.
/// Runs on its own serial queue; never blocks the caller.
public final class MicAudioEngine {
    public enum State: Equatable { case idle, active, draining }
    public struct Stats: Equatable {
        public var packets = 0, plcFrames = 0, decodeErrors = 0, sessions = 0
        public var level: Float = 0            // RMS 0…1 of the last 20 ms
        public var ringAvailable = false
    }
    public var onStats: (Stats, State) -> Void = { _, _ in }

    private let queue = DispatchQueue(label: "firetv.mic.audio", qos: .userInteractive)
    private var decoder: OpaquePointer?
    private var upsampler = Upsampler3x()
    private var ring: UnsafeMutablePointer<micring_t>?
    private var state: State = .idle
    private var stats = Stats()
    private var firstPacketAt: Date?
    private var sessionPackets = 0
    private var drainWork: DispatchWorkItem?
    private let frameSamples: Int32 = 320        // 20 ms @ 16 kHz

    public init() {}

    public var ringPath: String { String(cString: MICRING_PATH_C()) }

    /// Open decoder, converter and ring. Safe to call repeatedly.
    public func prepare() {
        queue.async {
            if self.decoder == nil {
                var err: Int32 = 0
                self.decoder = opus_decoder_create(16000, 1, &err)
                if err != OPUS_OK { self.decoder = nil }
            }
            if self.ring == nil { self.ring = micring_open_writer() }
            self.stats.ringAvailable = self.ring != nil
            self.publish()
        }
    }

    public func shutdown() {
        queue.sync {
            if let r = self.ring { micring_set_active(r, 0); micring_close(r); self.ring = nil }
            if let d = self.decoder { opus_decoder_destroy(d); self.decoder = nil }
        }
    }

    /// Mic button pressed: start a capture session.
    public func start() {
        queue.async {
            self.drainWork?.cancel(); self.drainWork = nil
            if self.ring == nil { self.ring = micring_open_writer(); self.stats.ringAvailable = self.ring != nil }
            // opus_decoder_ctl(OPUS_RESET_STATE) is a variadic macro Swift cannot call: recreate instead.
            if let d = self.decoder { opus_decoder_destroy(d) }
            var err: Int32 = 0
            self.decoder = opus_decoder_create(16000, 1, &err)
            self.upsampler.reset()
            self.state = .active
            self.firstPacketAt = nil; self.sessionPackets = 0
            self.stats.sessions += 1
            if let r = self.ring { micring_set_active(r, 1) }
            self.publish()
        }
    }

    /// Mic button released: accept the few late packets, then go silent.
    public func stop() {
        queue.async { [weak self] in
            guard let self, self.state == .active else { return }
            self.state = .draining
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.state = .idle
                if let r = self.ring { micring_set_active(r, 0) }
                self.stats.level = 0
                self.publish()
            }
            self.drainWork = w
            self.queue.asyncAfter(deadline: .now() + 0.2, execute: w)
            self.publish()
        }
    }

    /// One INPUT report 0xF0 (payload without the report ID = one Opus packet).
    public func push(packet: [UInt8]) {
        queue.async {
            guard self.state != .idle, self.decoder != nil, !packet.isEmpty else { return }
            // Packet loss concealment: the remote sends one 20 ms frame per packet with no sequence
            // number, so missing frames are inferred from wall-clock time since the first packet
            // (the remote needs ~200 ms after the enable command before audio starts).
            if self.firstPacketAt == nil { self.firstPacketAt = Date() }
            let elapsed = Date().timeIntervalSince(self.firstPacketAt!)
            let expected = Int(elapsed / 0.02) + 1
            var guard_ = 0
            while self.sessionPackets < expected - 3, guard_ < 3 {
                self.decodeAndWrite(nil); self.stats.plcFrames += 1; self.sessionPackets += 1; guard_ += 1
            }
            self.decodeAndWrite(packet)
            self.sessionPackets += 1
            self.stats.packets += 1
            if self.stats.packets % 5 == 0 { self.publish() }
        }
    }

    private var pcm16 = [Int16](repeating: 0, count: 960)
    private func decodeAndWrite(_ packet: [UInt8]?) {
        guard let d = decoder else { return }
        let n: Int32 = pcm16.withUnsafeMutableBufferPointer { out in
            if let p = packet { return p.withUnsafeBufferPointer { opus_decode(d, $0.baseAddress, Int32(p.count), out.baseAddress!, frameSamples, 0) } }
            return opus_decode(d, nil, 0, out.baseAddress!, frameSamples, 0)
        }
        guard n > 0 else { stats.decodeErrors += 1; return }
        // level meter
        var sum: Float = 0
        for i in 0..<Int(n) { let v = Float(pcm16[i]) / 32768; sum += v * v }
        stats.level = (sum / Float(n)).squareRoot()
        // 16 kHz Int16 -> 48 kHz Float32 with a continuous polyphase FIR (no per-packet discontinuity)
        guard let r = ring else { return }
        let outCount = upsampler.process(pcm16, count: Int(n), into: &pcm48)
        pcm48.withUnsafeBufferPointer { micring_write(r, $0.baseAddress!, UInt32(outCount)) }
    }
    private var pcm48 = [Float](repeating: 0, count: 960 * 3)

    private func publish() {
        let s = stats, st = state
        DispatchQueue.main.async { self.onStats(s, st) }
    }
}


/// 3× upsampler (16 kHz → 48 kHz): zero-stuffing + windowed-sinc low-pass, implemented polyphase.
/// Keeps filter state between calls so consecutive packets join without clicks.
public struct Upsampler3x {
    static let factor = 3
    static let tapsPerPhase = 32
    /// h[k] for k in 0..<96: Hamming-windowed sinc, cutoff 7.2 kHz at 48 kHz, gain 3.
    static let taps: [Float] = {
        let n = tapsPerPhase * factor
        let fc = 7200.0 / 48000.0
        var h = [Float](repeating: 0, count: n)
        let mid = Double(n - 1) / 2
        for i in 0..<n {
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let w = 0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            h[i] = Float(sinc * w * Double(factor))
        }
        return h
    }()
    private var history = [Float](repeating: 0, count: tapsPerPhase)   // last input samples, newest first
    public init() {}
    public mutating func reset() { for i in history.indices { history[i] = 0 } }
    /// Returns the number of output samples written (count * 3).
    public mutating func process(_ input: [Int16], count: Int, into out: inout [Float]) -> Int {
        let T = Self.tapsPerPhase, F = Self.factor
        var o = 0
        for i in 0..<count {
            // shift history
            for k in stride(from: T - 1, to: 0, by: -1) { history[k] = history[k - 1] }
            history[0] = Float(input[i]) / 32768
            for p in 0..<F {
                var acc: Float = 0
                var k = 0
                while k < T { acc += Self.taps[k * F + p] * history[k]; k += 1 }
                out[o] = acc; o += 1
            }
        }
        return o
    }
}

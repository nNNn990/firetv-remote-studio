import Foundation

/// Thin, argument-safe wrapper around /usr/bin/shortcuts. Never builds shell strings.
public final class ShortcutsService {
    public static let binary = "/usr/bin/shortcuts"
    public enum Failure: Error, LocalizedError, Equatable {
        case cliMissing
        case launchFailed(String)
        case exited(code: Int32, stderr: String)
        case alreadyRunning
        public var errorDescription: String? {
            switch self {
            case .cliMissing: return String(localized: "\(ShortcutsService.binary) not found")
            case .launchFailed(let s): return String(localized: "failed to start shortcuts:\(s)")
            case .exited(let c, let e): return String(localized: "shortcuts failed with exit code\(String(c)):\(e)")
            case .alreadyRunning: return String(localized: "Same shortcut is already running")
            }
        }
    }

    private let queue = DispatchQueue(label: "firetv.shortcuts.run", attributes: .concurrent)
    private let lock = NSLock()
    private var running = Set<String>()
    public init() {}

    public var runningNames: Set<String> { lock.lock(); defer { lock.unlock() }; return running }

    /// Parses `shortcuts list` output. Public for tests.
    public static func parseList(_ s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.isEmpty }
    }

    /// Synchronous; call from a background queue.
    public func list() throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: Self.binary) else { throw Failure.cliMissing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.binary)
        p.arguments = ["list"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { throw Failure.launchFailed(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure.exited(code: p.terminationStatus, stderr: String(data: edata, encoding: .utf8) ?? "")
        }
        return Self.parseList(String(data: data, encoding: .utf8) ?? "")
    }

    public func listAsync(_ completion: @escaping (Result<[String], Error>) -> Void) {
        queue.async { completion(Result { try self.list() }) }
    }

    /// Runs a shortcut by name on a background queue. A name already running is refused.
    public func run(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        if running.contains(name) { lock.unlock(); completion(.failure(Failure.alreadyRunning)); return }
        running.insert(name)
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.running.remove(name); self.lock.unlock() }
            guard FileManager.default.isExecutableFile(atPath: Self.binary) else { completion(.failure(Failure.cliMissing)); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.binary)
            p.arguments = ["run", name]
            let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { completion(.failure(Failure.launchFailed(error.localizedDescription))); return }
            let edata = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { completion(.success(())) }
            else { completion(.failure(Failure.exited(code: p.terminationStatus, stderr: (String(data: edata, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))) }
        }
    }
}

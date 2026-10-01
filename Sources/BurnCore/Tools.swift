import Foundation

public enum Tools {
    public static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/schily/bin", "/usr/bin"]

    public static func locate(_ name: String) -> String? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var combined: String { stdout + stderr }
}

/// Written by one reader thread, read after DispatchGroup completion.
private final class DataBox: @unchecked Sendable { var data = Data() }

/// Runs a command to completion and captures its output.
public func runProcess(_ path: String, _ args: [String]) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // Drain pipes concurrently so large outputs never block the child.
        let group = DispatchGroup()
        let outData = DataBox(), errData = DataBox()
        group.enter()
        DispatchQueue.global().async { outData.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        p.terminationHandler = { proc in
            group.notify(queue: .global()) {
                cont.resume(returning: ProcessResult(
                    status: proc.terminationStatus,
                    stdout: String(decoding: outData.data, as: UTF8.self),
                    stderr: String(decoding: errData.data, as: UTF8.self)))
            }
        }
        do { try p.run() } catch { cont.resume(throwing: error) }
    }
}

/// Splits streamed bytes into lines on `\n` or `\r` (cdrecord uses `\r` for progress).
public final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    public init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    public func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    public func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}

import Foundation
import SwiftUI
import BurnCore

struct BurnItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    var size: Int64? = nil          // nil while computing
    var hasHugeFile = false         // contains a file > 4 GiB
    var name: String { url.lastPathComponent }
}

enum MediaState: Equatable {
    case unknown
    case noDrive
    case noDisc
    case mounted(String)            // macOS holds the disc; must unmount before cdrecord can talk to it
    case ready(MediaInfo)
    case error(String)
}

enum BurnPhase: Equatable {
    case idle, preparing, writing, fixating, done, failed(String), cancelled
}

@MainActor
final class BurnModel: ObservableObject {
    @Published var cdrecordPath = Tools.locate("cdrecord")
    @Published var mkisofsPath = Tools.locate("mkisofs")
    @Published var drives: [Drive] = []
    @Published var selectedDev: String? = nil
    @Published var media: MediaState = .unknown
    @Published var items: [BurnItem] = []
    @Published var volumeLabel = "BDXL_" + BurnModel.dateStamp()
    @Published var closeDisc = false
    @Published var ejectWhenDone = false
    @Published var phase: BurnPhase = .idle
    @Published var progress: Double = 0          // 0...1
    @Published var progressText = ""
    @Published var log = ""
    @Published var busy = false
    @Published var notice: String? = nil

    private var running: [Process] = []
    private var cancelRequested = false

    var toolsMissing: Bool { cdrecordPath == nil || mkisofsPath == nil }
    var totalSize: Int64 { items.compactMap(\.size).reduce(0, +) }
    var sizesPending: Bool { items.contains { $0.size == nil } }
    var hasHugeFiles: Bool { items.contains(where: \.hasHugeFile) }
    var isBurning: Bool { [.preparing, .writing, .fixating].contains(phase) }

    var mediaInfo: MediaInfo? {
        if case .ready(let m) = media { return m }
        return nil
    }

    var canBurn: Bool {
        guard !toolsMissing, !busy, !items.isEmpty, !sizesPending, selectedDev != nil,
              let m = mediaInfo, m.isAppendable else { return false }
        return totalSize < m.remainingBytes
    }

    static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }

    // MARK: - Logging

    func appendLog(_ line: String) {
        // cdrecord repeats its privilege warnings on every call; they are harmless on macOS.
        if line.contains("Insufficient '") { return }
        log += line + "\n"
        if log.count > 400_000 { log = String(log.suffix(300_000)) }
    }

    // MARK: - Drive & media

    func refreshAll() async {
        guard let cdrecord = cdrecordPath else { media = .unknown; return }
        busy = true
        defer { busy = false }
        do {
            let r = try await runProcess(cdrecord, ["-scanbus"])
            drives = Parsers.scanbus(r.combined)
            // While macOS has a disc mounted it owns the drive and -scanbus can't see it at all.
            if drives.isEmpty {
                selectedDev = nil
                if let mounted = try await opticalMounts().first { media = .mounted(mounted) } else { media = .noDrive }
                return
            }
            if selectedDev == nil || !drives.contains(where: { $0.dev == selectedDev }) {
                selectedDev = drives.first?.dev
            }
        } catch {
            media = .error("scanbus failed: \(error.localizedDescription)")
            return
        }
        await readMedia()
    }

    func readMedia() async {
        guard let cdrecord = cdrecordPath else { return }
        guard let dev = selectedDev else { media = .noDrive; return }
        do {
            let r = try await runProcess(cdrecord, ["dev=\(dev)", "-minfo"])
            if let info = Parsers.minfo(r.combined) {
                media = .ready(info)
            } else if let mounted = try await opticalMounts().first {
                media = .mounted(mounted)
            } else if ["no disk", "medium not present", "cannot load media"].contains(where: {
                r.combined.localizedCaseInsensitiveContains($0) }) {
                media = .noDisc
            } else {
                let lastLines = r.combined.split(separator: "\n").suffix(3).joined(separator: "\n")
                media = .error(lastLines.isEmpty ? "Could not read media" : lastLines)
            }
        } catch {
            media = .error(error.localizedDescription)
        }
    }

    func unmountAndRead() async {
        busy = true
        do { try await unmountOptical() } catch { appendLog("unmount: \(error.localizedDescription)") }
        busy = false
        // Drive only becomes visible to cdrecord after the unmount, so rescan rather than just re-read.
        await refreshAll()
    }

    private func opticalMounts() async throws -> [String] {
        let r = try await runProcess("/sbin/mount", [])
        return Parsers.opticalMounts(r.stdout)
    }

    private func unmountOptical() async throws {
        for disk in try await opticalMounts() {
            appendLog("$ diskutil unmountDisk \(disk)")
            let r = try await runProcess("/usr/sbin/diskutil", ["unmountDisk", disk])
            appendLog(r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Compilation

    func add(urls: [URL]) {
        for url in urls {
            let url = url.standardizedFileURL
            guard !items.contains(where: { $0.url == url }) else { continue }
            if items.contains(where: { $0.name == url.lastPathComponent }) {
                notice = "“\(url.lastPathComponent)” already in list. Top-level names must be unique."
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let item = BurnItem(url: url, isDirectory: isDir.boolValue)
            items.append(item)
            let id = item.id
            Task.detached(priority: .utility) {
                let (size, huge) = Self.measure(url)
                await MainActor.run {
                    if let i = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[i].size = size
                        self.items[i].hasHugeFile = huge
                    }
                }
            }
        }
    }

    func remove(_ item: BurnItem) { items.removeAll { $0.id == item.id } }

    nonisolated static func measure(_ url: URL) -> (Int64, Bool) {
        let fourGiB: Int64 = 4 * 1024 * 1024 * 1024 - 1
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        func sizeOf(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return 0 }
            return Int64(v.fileSize ?? 0)
        }
        var total: Int64 = 0
        var huge = false
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
            while let f = e?.nextObject() as? URL {
                let s = sizeOf(f)
                total += s
                if s > fourGiB { huge = true }
            }
        } else {
            total = sizeOf(url)
            huge = total > fourGiB
        }
        return (total, huge)
    }

    // MARK: - Burn

    func burn() async {
        guard let cdrecord = cdrecordPath, let mkisofs = mkisofsPath, let dev = selectedDev else { return }
        busy = true
        cancelRequested = false
        phase = .preparing
        progress = 0
        progressText = "Preparing…"
        log = ""
        defer { busy = false }

        do {
            try await unmountOptical()

            // Re-read media right before burning; state may have changed.
            let mi = try await runProcess(cdrecord, ["dev=\(dev)", "-minfo"])
            guard let info = Parsers.minfo(mi.combined) else { throw BurnError("Cannot read disc:\n\(mi.combined.suffix(400))") }
            media = .ready(info)
            guard info.isAppendable else { throw BurnError("Disc is closed; no more sessions can be added.") }

            var msinfo: String? = nil
            if info.diskStatus == .incomplete {
                appendLog("$ cdrecord dev=\(dev) -msinfo")
                let r = try await runProcess(cdrecord, ["dev=\(dev)", "-msinfo"])
                guard let ms = Parsers.msinfo(r.stdout) else { throw BurnError("cdrecord -msinfo failed:\n\(r.combined)") }
                appendLog(ms)
                msinfo = ms
            }

            let urls = items.map(\.url)
            let sizeArgs = Commands.mkisofsArgs(items: urls, label: volumeLabel, msinfo: msinfo,
                                                dev: msinfo == nil ? nil : dev, printSize: true)
            appendLog("$ mkisofs " + sizeArgs.joined(separator: " "))
            let sz = try await runProcess(mkisofs, sizeArgs)
            guard sz.status == 0, let sectors = Parsers.printSize(sz.stdout) else {
                throw BurnError("mkisofs size calculation failed:\n\(sz.stderr.suffix(800))")
            }
            appendLog("Session size: \(sectors) sectors (\(ByteCountFormatter.string(fromByteCount: sectors * 2048, countStyle: .file)))")
            guard sectors < info.remaining else {
                throw BurnError("Not enough space: need \(sectors) sectors, \(info.remaining) free.")
            }
            if cancelRequested { throw CancelError() }

            let mkArgs = Commands.mkisofsArgs(items: urls, label: volumeLabel, msinfo: msinfo,
                                              dev: msinfo == nil ? nil : dev, printSize: false)
            let options = BurnOptions(volumeLabel: volumeLabel, closeDisc: closeDisc, eject: ejectWhenDone)
            let cdArgs = Commands.cdrecordBurnArgs(dev: dev, sectors: sectors, options: options)
            appendLog("$ mkisofs " + mkArgs.joined(separator: " ") + " | cdrecord " + cdArgs.joined(separator: " "))

            let totalMB = max(1, sectors * 2048 / 1_000_000)
            let (mkStatus, cdStatus) = try await runPipeline(mkisofs, mkArgs, cdrecord, cdArgs, totalMB: totalMB)
            if cancelRequested { throw CancelError() }
            guard cdStatus == 0 else { throw BurnError("cdrecord exited with status \(cdStatus). See log.") }
            guard mkStatus == 0 else { throw BurnError("mkisofs exited with status \(mkStatus). See log.") }

            phase = .done
            progress = 1
            progressText = closeDisc ? "Done. Disc closed." : "Done. Session added — disc still appendable."
            items.removeAll()
            volumeLabel = "BDXL_" + Self.dateStamp()
        } catch is CancelError {
            phase = .cancelled
            progressText = "Cancelled."
        } catch {
            phase = .failed(error.localizedDescription)
            progressText = "Failed."
            appendLog("ERROR: \(error.localizedDescription)")
        }
        running = []

        // Give the drive a moment to settle before asking it for the new TOC.
        try? await Task.sleep(for: .seconds(3))
        await readMedia()
    }

    func cancel() {
        cancelRequested = true
        running.forEach { if $0.isRunning { $0.terminate() } }
        appendLog("Cancel requested.")
    }

    /// mkisofs stdout → cdrecord stdin; both stderr streams go to the log.
    private func runPipeline(_ mkPath: String, _ mkArgs: [String], _ cdPath: String, _ cdArgs: [String],
                             totalMB: Int64) async throws -> (Int32, Int32) {
        let mk = Process(), cd = Process()
        mk.executableURL = URL(fileURLWithPath: mkPath)
        mk.arguments = mkArgs
        cd.executableURL = URL(fileURLWithPath: cdPath)
        cd.arguments = cdArgs

        let data = Pipe(), mkErr = Pipe(), cdOut = Pipe()
        mk.standardInput = FileHandle.nullDevice
        mk.standardOutput = data
        mk.standardError = mkErr
        cd.standardInput = data
        cd.standardOutput = cdOut
        cd.standardError = cdOut

        let mkLines = LineSplitter { line in Task { @MainActor in self.handle(line: line, from: "mkisofs", totalMB: totalMB) } }
        let cdLines = LineSplitter { line in Task { @MainActor in self.handle(line: line, from: "cdrecord", totalMB: totalMB) } }
        mkErr.fileHandleForReading.readabilityHandler = { h in mkLines.feed(h.availableData) }
        cdOut.fileHandleForReading.readabilityHandler = { h in cdLines.feed(h.availableData) }

        let result: (Int32, Int32) = try await withCheckedThrowingContinuation { cont in
            let group = DispatchGroup()
            let status = StatusBox()
            group.enter(); group.enter()
            mk.terminationHandler = { status.mk = $0.terminationStatus; group.leave() }
            cd.terminationHandler = { status.cd = $0.terminationStatus; group.leave() }
            do {
                try cd.run()
            } catch {
                cont.resume(throwing: error); return
            }
            do {
                try mk.run()
            } catch {
                cd.terminate()
                group.leave()   // mk never ran
                group.notify(queue: .global()) { cont.resume(throwing: error) }
                return
            }
            group.notify(queue: .global()) { cont.resume(returning: (status.mk, status.cd)) }
            running = [mk, cd]
            phase = .writing
            progressText = "Writing…"
        }

        mkErr.fileHandleForReading.readabilityHandler = nil
        cdOut.fileHandleForReading.readabilityHandler = nil
        mkLines.feed(mkErr.fileHandleForReading.readDataToEndOfFile()); mkLines.flush()
        cdLines.feed(cdOut.fileHandleForReading.readDataToEndOfFile()); cdLines.flush()
        try? await Task.sleep(for: .milliseconds(100))   // let queued log lines land
        return result
    }

    private var lastProgressLine = ""

    private func handle(line: String, from tool: String, totalMB: Int64) {
        if let (done, total) = Parsers.progress(line) {
            let t = total > 0 ? total : totalMB
            progress = min(1, Double(done) / Double(t))
            progressText = "Writing \(done) of \(t) MB"
            // Don't flood the log with every progress tick.
            if line != lastProgressLine && done % 500 == 0 { appendLog(line) }
            lastProgressLine = line
            return
        }
        if tool == "mkisofs", line.contains("% done") { return }
        if line.localizedCaseInsensitiveContains("fixating") {
            phase = .fixating
            progressText = "Fixating (closing session)… do not eject."
        }
        appendLog(line)
    }
}

struct BurnError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct CancelError: Error {}

private final class StatusBox: @unchecked Sendable {
    var mk: Int32 = -1
    var cd: Int32 = -1
}

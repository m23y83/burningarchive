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
    @Published var growisofsPath = Tools.locate("growisofs")
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
    // growisofs reports absolute disc offsets; progress is measured from where this session starts.
    private var sessionStartBytes: Int64 = 0
    private var sessionBytes: Int64 = 1

    var toolsMissing: Bool { cdrecordPath == nil || mkisofsPath == nil || growisofsPath == nil }
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

    /// BSD name ("disk6") of the selected burner's disc, matched via drutil by vendor and model.
    private func opticalBSDName() async throws -> String {
        let drive = drives.first { $0.dev == selectedDev }
        let list = try await runProcess("/usr/bin/drutil", ["list"])
        let rows = Parsers.drutilList(list.stdout)
        let index = rows.first { row in
            drive.map { row.1.contains($0.vendor) && row.1.contains($0.model) } ?? false
        }?.0 ?? rows.first?.0 ?? 1
        // After cdrecord releases the drive, macOS takes a few seconds to re-probe the disc and
        // reports "No Media Inserted" until then, so poll until the node reappears.
        let deadline = Date().addingTimeInterval(30)
        while true {
            let st = try await runProcess("/usr/bin/drutil", ["-drive", "\(index)", "status"])
            if let name = Parsers.drutilBSDName(st.stdout) { return name }
            if cancelRequested { throw CancelError() }
            guard Date() < deadline else {
                throw BurnError("macOS shows no device node for the disc in drive \(index):\n\(st.combined.suffix(400))")
            }
            progressText = "Waiting for macOS to detect the disc…"
            try await Task.sleep(for: .seconds(1))
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
        guard let cdrecord = cdrecordPath, let mkisofs = mkisofsPath, let growisofs = growisofsPath,
              let dev = selectedDev else { return }
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

            // macOS remounts the disc whenever a tool releases the drive, so unmount before each step.
            var msinfo: String? = nil
            if info.diskStatus == .incomplete {
                try await unmountOptical()
                appendLog("$ cdrecord dev=\(dev) -msinfo")
                let r = try await runProcess(cdrecord, ["dev=\(dev)", "-msinfo"])
                guard let ms = Parsers.msinfo(r.stdout) else { throw BurnError("cdrecord -msinfo failed:\n\(r.combined)") }
                appendLog(ms)
                msinfo = ms
            }

            let urls = items.map(\.url)
            try await unmountOptical()
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
            let viaGrowisofs = Commands.usesGrowisofs(mediaType: info.mediaType, closeDisc: closeDisc)
            var bsdName: String? = nil
            let writer: String, writerPath: String, writerArgs: [String]
            if viaGrowisofs {
                let name = try await opticalBSDName()
                bsdName = name
                writer = "growisofs"
                writerPath = growisofs
                // Raw node: growisofs then drives the burner over IOKit SCSI and needs no write permission on it.
                writerArgs = Commands.growisofsArgs(device: "/dev/r\(name)", msinfo: msinfo)
            } else {
                writer = "cdrecord"
                writerPath = cdrecord
                let options = BurnOptions(volumeLabel: volumeLabel, closeDisc: closeDisc, eject: ejectWhenDone)
                writerArgs = Commands.cdrecordBurnArgs(dev: dev, sectors: sectors, options: options)
            }
            appendLog("$ mkisofs " + mkArgs.joined(separator: " ") + " | \(writer) " + writerArgs.joined(separator: " "))

            sessionBytes = max(1, sectors * 2048)
            lastLoggedStep = -1
            sessionStartBytes = (msinfo.flatMap { $0.split(separator: ",").last }.flatMap { Int64($0) } ?? 0) * 2048
            let totalMB = max(1, sectors * 2048 / 1_000_000)
            try await unmountOptical()
            let (mkStatus, wrStatus) = try await runPipeline(mkisofs, mkArgs, writerPath, writerArgs,
                                                             totalMB: totalMB, waitForImage: viaGrowisofs)
            if cancelRequested { throw CancelError() }
            guard wrStatus == 0 else { throw BurnError("\(writer) exited with status \(wrStatus). See log.") }
            guard mkStatus == 0 else { throw BurnError("mkisofs exited with status \(mkStatus). See log.") }

            if viaGrowisofs, ejectWhenDone, let bsdName {
                appendLog("$ diskutil eject \(bsdName)")
                let r = try await runProcess("/usr/sbin/diskutil", ["eject", bsdName])
                appendLog(r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
            }

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
        try? await unmountOptical()
        await readMedia()
    }

    func cancel() {
        cancelRequested = true
        running.forEach { if $0.isRunning { $0.terminate() } }
        appendLog("Cancel requested.")
    }

    /// mkisofs stdout → writer stdin; both stderr streams go to the log.
    /// `waitForImage`: start the writer only once mkisofs emits data. When appending, mkisofs first
    /// reads the previous session through the drive; growisofs needs the drive exclusively, and
    /// mkisofs releases it before it writes any output.
    private func runPipeline(_ mkPath: String, _ mkArgs: [String], _ wrPath: String, _ wrArgs: [String],
                             totalMB: Int64, waitForImage: Bool) async throws -> (Int32, Int32) {
        let mk = Process(), wr = Process()
        mk.executableURL = URL(fileURLWithPath: mkPath)
        mk.arguments = mkArgs
        wr.executableURL = URL(fileURLWithPath: wrPath)
        wr.arguments = wrArgs
        let writer = wr.executableURL!.lastPathComponent

        let data = Pipe(), mkErr = Pipe(), wrOut = Pipe()
        mk.standardInput = FileHandle.nullDevice
        mk.standardOutput = data
        mk.standardError = mkErr
        wr.standardInput = data
        wr.standardOutput = wrOut
        wr.standardError = wrOut

        let mkLines = LineSplitter { line in Task { @MainActor in self.handle(line: line, from: "mkisofs", totalMB: totalMB) } }
        let wrLines = LineSplitter { line in Task { @MainActor in self.handle(line: line, from: writer, totalMB: totalMB) } }
        mkErr.fileHandleForReading.readabilityHandler = { h in mkLines.feed(h.availableData) }
        wrOut.fileHandleForReading.readabilityHandler = { h in wrLines.feed(h.availableData) }
        defer {
            mkErr.fileHandleForReading.readabilityHandler = nil
            wrOut.fileHandleForReading.readabilityHandler = nil
        }

        let group = DispatchGroup()
        let status = StatusBox()
        group.enter()
        mk.terminationHandler = { status.mk = $0.terminationStatus; group.leave() }
        wr.terminationHandler = { status.cd = $0.terminationStatus; group.leave() }
        let finished = { await withCheckedContinuation { c in group.notify(queue: .global()) { c.resume() } } }

        if !waitForImage {
            group.enter()
            do { try wr.run() } catch { group.leave(); throw error }
        }
        do {
            try mk.run()
        } catch {
            if wr.isRunning { wr.terminate() }
            group.leave()   // mk never ran
            await finished()
            throw error
        }
        running = waitForImage ? [mk] : [mk, wr]

        if waitForImage {
            progressText = "Reading previous session…"
            let fd = data.fileHandleForReading.fileDescriptor
            let ready = await Task.detached { waitReadable(fd) }.value
            var startError: Error? = nil
            if cancelRequested { startError = CancelError() }
            else if !ready { startError = BurnError("mkisofs stopped before producing the image. See log.") }
            else {
                do {
                    try await unmountOptical()
                    group.enter()
                    do { try wr.run() } catch { group.leave(); throw error }
                } catch { startError = error }
            }
            if let startError {
                if mk.isRunning { mk.terminate() }
                await finished()
                mkLines.feed(mkErr.fileHandleForReading.readDataToEndOfFile()); mkLines.flush()
                throw startError
            }
            running = [mk, wr]
        }
        phase = .writing
        progressText = "Writing…"

        await finished()
        mkLines.feed(mkErr.fileHandleForReading.readDataToEndOfFile()); mkLines.flush()
        wrLines.feed(wrOut.fileHandleForReading.readDataToEndOfFile()); wrLines.flush()
        try? await Task.sleep(for: .milliseconds(100))   // let queued log lines land
        return (status.mk, status.cd)
    }

    private var lastProgressLine = ""
    private var lastLoggedStep = -1

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
        if tool == "growisofs", let offset = Parsers.growisofsProgress(line) {
            let done = max(0, offset - sessionStartBytes)
            progress = min(1, Double(done) / Double(sessionBytes))
            progressText = "Writing \(done / 1_000_000) of \(sessionBytes / 1_000_000) MB"
            // Log every 5% rather than every tick.
            let step = Int(progress * 20)
            if step != lastLoggedStep { appendLog(line); lastLoggedStep = step }
            return
        }
        if tool == "mkisofs", line.contains("% done") { return }
        // cdrecord: "Fixating..."; growisofs: "flushing cache", "closing track", "closing session".
        if ["fixating", "flushing cache", "closing track", "closing session"].contains(where: {
            line.localizedCaseInsensitiveContains($0) }) {
            phase = .fixating
            progressText = closeDisc ? "Closing disc… do not eject." : "Closing session… do not eject."
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

/// Blocks until the pipe has data (true) or its writer has gone without writing any (false).
private func waitReadable(_ fd: Int32) -> Bool {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        let n = poll(&p, 1, -1)
        if n < 0 && errno == EINTR { continue }
        return n > 0 && p.revents & Int16(POLLIN) != 0
    }
}

private final class StatusBox: @unchecked Sendable {
    var mk: Int32 = -1
    var cd: Int32 = -1
}

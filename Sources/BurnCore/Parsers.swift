import Foundation

public struct Drive: Hashable, Identifiable, Sendable {
    public let dev: String      // cdrecord dev= spec, e.g. "2,0,0"
    public let vendor: String
    public let model: String
    public let revision: String
    public var id: String { dev }
    public var displayName: String { "\(vendor) \(model) (\(dev))" }
}

public enum DiskStatus: String, Sendable {
    case empty, incomplete, complete, unknown
}

public struct MediaInfo: Equatable, Sendable {
    public var mediaType: String = ""
    public var diskStatus: DiskStatus = .unknown
    public var sessionStatus: String = ""
    public var sessions: Int = 0
    public var nextWritable: Int64 = 0      // sectors
    public var remaining: Int64 = 0         // sectors
    public var totalSectors: Int64 = 0      // capacity from track table (0 if unknown)

    public static let sectorSize: Int64 = 2048
    public var remainingBytes: Int64 { remaining * Self.sectorSize }
    public var usedBytes: Int64 { nextWritable * Self.sectorSize }
    public var capacityBytes: Int64 { max(totalSectors, nextWritable + remaining) * Self.sectorSize }
    public var isAppendable: Bool { diskStatus == .empty || diskStatus == .incomplete }
}

public enum Parsers {
    /// Parses `cdrecord -scanbus` output. Only lines with a quoted vendor are drives.
    public static func scanbus(_ text: String) -> [Drive] {
        // \t2,0,0\t200) 'MATSHITA' 'BD-MLT UJ260    ' '1.00' Removable CD-ROM
        let re = try! NSRegularExpression(
            pattern: #"^\s*(\d+,\d+,\d+)\s+\d+\)\s+'([^']*)'\s+'([^']*)'\s+'([^']*)'"#,
            options: .anchorsMatchLines)
        return matches(re, in: text).map { g in
            Drive(dev: g[1], vendor: trim(g[2]), model: trim(g[3]), revision: trim(g[4]))
        }
    }

    public static func minfo(_ text: String) -> MediaInfo? {
        var info = MediaInfo()
        var found = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = trim(String(line[..<colon])).lowercased()
            let value = trim(String(line[line.index(after: colon)...]))
            switch key {
            case "mounted media type": info.mediaType = value; found = true
            case "disk status": info.diskStatus = DiskStatus(rawValue: value) ?? .unknown; found = true
            case "session status": info.sessionStatus = value
            case "number of sessions": info.sessions = Int(value) ?? 0
            case "next writable address": info.nextWritable = Int64(value) ?? 0
            case "remaining writable size": info.remaining = Int64(value) ?? 0
            default: break
            }
        }
        // Largest end address in the track table ≈ disc capacity.
        let re = try! NSRegularExpression(
            pattern: #"^\s*\d+\s+\d+\s+\w+\s+\d+\s+(\d+)\s+\d+"#, options: .anchorsMatchLines)
        let ends = matches(re, in: text).compactMap { Int64($0[1]) }
        if let maxEnd = ends.max() { info.totalSectors = maxEnd + 1 }
        // A blank disc reports its whole data area as one "Blank" track; nothing is used yet.
        if info.diskStatus == .empty { info.sessions = 0 }
        return found ? info : nil
    }

    /// `cdrecord -msinfo` prints "last_sess_start,next_sess_start".
    public static func msinfo(_ text: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"^\s*(\d+,\d+)\s*$"#, options: .anchorsMatchLines)
        return matches(re, in: text).last?[1]
    }

    /// `mkisofs -quiet -print-size` prints the sector count alone on stdout.
    public static func printSize(_ text: String) -> Int64? {
        text.split(whereSeparator: \.isNewline).reversed()
            .compactMap { Int64(trim(String($0))) }.first
    }

    /// Progress line: "Track 01:  123 of 4567 MB written (fifo 100%) ..."
    /// Returns (writtenMB, totalMB). totalMB may be 0 when unknown.
    public static func progress(_ line: String) -> (Int64, Int64)? {
        let re = try! NSRegularExpression(pattern: #"Track\s+\d+:\s+(\d+)\s+(?:of\s+(\d+)\s+)?MB written"#)
        guard let g = matches(re, in: line).first else { return nil }
        return (Int64(g[1]) ?? 0, Int64(g[2]) ?? 0)
    }

    /// Mounted optical volumes from `mount` output: returns BSD whole-disk nodes, e.g. "/dev/disk6".
    public static func opticalMounts(_ text: String) -> [String] {
        let re = try! NSRegularExpression(
            pattern: #"^(/dev/disk\d+)(?:s\d+)?\s+on\s+.*\((?:cd9660|udf)\b"#, options: .anchorsMatchLines)
        return Array(Set(matches(re, in: text).map { $0[1] })).sorted()
    }

    // MARK: helpers

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    static func matches(_ re: NSRegularExpression, in text: String) -> [[String]] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}

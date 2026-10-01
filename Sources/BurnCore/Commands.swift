import Foundation

public struct BurnOptions: Sendable {
    public var volumeLabel: String
    public var closeDisc: Bool
    public var eject: Bool
    public init(volumeLabel: String, closeDisc: Bool = false, eject: Bool = false) {
        self.volumeLabel = volumeLabel
        self.closeDisc = closeDisc
        self.eject = eject
    }
}

public enum Commands {
    /// Escapes a graft-point path component for mkisofs (`\` and `=` are special).
    public static func escapeGraft(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "=", with: "\\=")
    }

    /// Graft point placing `url` at the disc root under its own name.
    public static func graftPoint(for url: URL) -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let name = escapeGraft(url.lastPathComponent)
        let source = escapeGraft(url.path)
        return isDir.boolValue ? "\(name)/=\(source)" : "\(name)=\(source)"
    }

    /// Volume IDs are max 32 chars; keep them to a safe character set.
    public static func sanitizeLabel(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_- "))
        let cleaned = String(s.unicodeScalars.filter { allowed.contains($0) && $0.isASCII })
        return String(cleaned.prefix(32))
    }

    /// mkisofs arguments. `msinfo` + `dev` set => new session merged onto previous one.
    public static func mkisofsArgs(items: [URL], label: String, msinfo: String?, dev: String?,
                                   printSize: Bool) -> [String] {
        var a = ["-R", "-J", "-joliet-long", "-iso-level", "3",
                 "-V", sanitizeLabel(label).isEmpty ? "BDXL" : sanitizeLabel(label),
                 "-graft-points", "-m", ".DS_Store", "-m", "._*"]
        if let msinfo, let dev {
            a += ["-C", msinfo, "-dev", dev]
        }
        if printSize { a += ["-quiet", "-print-size"] }
        a += items.map(graftPoint(for:))
        return a
    }

    /// growisofs writes BD/DVD sessions. Unlike cdrecord's BD-R driver, which always finalizes
    /// the disc (CLOSE SESSION function 6), growisofs only closes the session, so the disc stays
    /// appendable. The image comes in on stdin; `msinfo` must match what growisofs reads from
    /// the drive or it aborts before writing. `spare:none` keeps a blank BD-R unformatted
    /// (sequential, true multisession) instead of pre-formatting it for pseudo-overwrite.
    public static func growisofsArgs(device: String, msinfo: String?) -> [String] {
        var a = ["-use-the-force-luke=spare:none"]
        if let msinfo { a += ["-C", msinfo, "-M"] } else { a.append("-Z") }
        a.append("\(device)=/dev/fd/0")
        return a
    }

    /// Writer for this burn. growisofs has no CD support, and closing a disc is left to
    /// cdrecord, whose finalization is exactly what closing should do.
    public static func usesGrowisofs(mediaType: String, closeDisc: Bool) -> Bool {
        !closeDisc && !mediaType.uppercased().hasPrefix("CD")
    }

    public static func cdrecordBurnArgs(dev: String, sectors: Int64, options: BurnOptions) -> [String] {
        var a = ["dev=\(dev)", "-v", "gracetime=2", "fs=64m", "driveropts=burnfree", "-data",
                 "tsize=\(sectors)s"]
        if !options.closeDisc { a.append("-multi") }
        if options.eject { a.append("-eject") }
        a.append("-")
        return a
    }
}

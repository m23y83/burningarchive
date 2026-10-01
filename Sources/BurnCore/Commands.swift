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

    public static func cdrecordBurnArgs(dev: String, sectors: Int64, options: BurnOptions) -> [String] {
        var a = ["dev=\(dev)", "-v", "gracetime=2", "fs=64m", "driveropts=burnfree", "-data",
                 "tsize=\(sectors)s"]
        if !options.closeDisc { a.append("-multi") }
        if options.eject { a.append("-eject") }
        a.append("-")
        return a
    }
}

import Foundation
import Testing
@testable import BurnCore

/// Runs the exact argument lists the app generates, writing to image files instead of a drive,
/// and checks that session 2 still contains session 1's files.
@Test func twoSessionMergeWithGeneratedArgs() async throws {
    guard let mkisofs = Tools.locate("mkisofs"), let isoinfo = Tools.locate("isoinfo") else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bdtest-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: dir.appendingPathComponent("src/Photos/2026"), withIntermediateDirectories: true)
    try "a".write(to: dir.appendingPathComponent("src/Photos/2026/a.jpg"), atomically: true, encoding: .utf8)
    try "b".write(to: dir.appendingPathComponent("src/we=ird name.txt"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("src/Photos/.DS_Store"), atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: dir) }
    let s1 = dir.appendingPathComponent("s1.iso").path, s2 = dir.appendingPathComponent("s2.iso").path

    // Session 1: folder.
    let items1 = [dir.appendingPathComponent("src/Photos")]
    let size1 = try await runProcess(mkisofs, Commands.mkisofsArgs(items: items1, label: "T", msinfo: nil, dev: nil, printSize: true))
    let n = try #require(Parsers.printSize(size1.stdout))
    let w1 = try await runProcess(mkisofs, ["-o", s1] + Commands.mkisofsArgs(items: items1, label: "T", msinfo: nil, dev: nil, printSize: false))
    #expect(w1.status == 0)
    #expect(Int64(try fm.attributesOfItem(atPath: s1)[.size] as! Int) == n * 2048)

    // Session 2: file with '=' in name, merged onto session 1 (image path stands in for the drive).
    let items2 = [dir.appendingPathComponent("src/we=ird name.txt")]
    let w2 = try await runProcess(mkisofs, ["-o", s2] + Commands.mkisofsArgs(items: items2, label: "T", msinfo: "0,\(n)", dev: s1, printSize: false))
    #expect(w2.status == 0, "\(w2.stderr)")

    // Assemble the "disc" and list the last session.
    let disc = dir.appendingPathComponent("disc.iso")
    var data = try Data(contentsOf: URL(fileURLWithPath: s1))
    data.append(try Data(contentsOf: URL(fileURLWithPath: s2)))
    try data.write(to: disc)
    let ls = try await runProcess(isoinfo, ["-i", disc.path, "-T", "\(n)", "-R", "-l"])
    #expect(ls.stdout.contains("a.jpg"))
    #expect(ls.stdout.contains("we=ird name.txt"))
    #expect(!ls.stdout.contains(".DS_Store"))
}

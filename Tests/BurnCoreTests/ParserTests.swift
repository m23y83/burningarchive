import Foundation
import Testing
@testable import BurnCore

let scanbusOutput = """
Cdrecord-ProDVD-ProBD-Clone 3.02a09 (--) Copyright (C) 1995-2016 Joerg Schilling
Using libscg version 'schily-0.9'.
scsibus2:
\t2,0,0\t200) 'MATSHITA' 'BD-MLT UJ260    ' '1.00' Removable CD-ROM
\t2,1,0\t201) *
\t2,2,0\t202) *
"""

let minfoBlank = """
Mounted media class:      BD
Mounted media type:       BD-R sequential recording
Disk Is not erasable
data type:                standard
disk status:              empty
session status:           empty
BG format status:         none
first track:              1
number of sessions:       1
first track in last sess: 1
last track in last sess:  1
Disk Is unrestricted
Disk type: DVD, HD-DVD or BD

Track  Sess Type   Start Addr End Addr   Size
==============================================
    1     1 Blank  0          48878591   48878592

Next writable address:              0
Remaining writable size:            48878592
"""

let minfoAppendable = """
Mounted media type:       BD-R sequential recording
disk status:              incomplete
session status:           empty
number of sessions:       2

Track  Sess Type   Start Addr End Addr   Size
==============================================
    1     1 Data   0          1023       1024
    2     2 Blank  2048       48878591   48876544

Next writable address:              2048
Remaining writable size:            48876544
"""

@Test func parsesScanbus() {
    let drives = Parsers.scanbus(scanbusOutput)
    #expect(drives == [Drive(dev: "2,0,0", vendor: "MATSHITA", model: "BD-MLT UJ260", revision: "1.00")])
}

@Test func parsesBlankMinfo() throws {
    let m = try #require(Parsers.minfo(minfoBlank))
    #expect(m.mediaType == "BD-R sequential recording")
    #expect(m.diskStatus == .empty)
    #expect(m.sessions == 0)
    #expect(m.remaining == 48878592)
    #expect(m.totalSectors == 48878592)
    #expect(m.capacityBytes == 48878592 * 2048)
    #expect(m.isAppendable)
}

@Test func parsesAppendableMinfo() throws {
    let m = try #require(Parsers.minfo(minfoAppendable))
    #expect(m.diskStatus == .incomplete)
    #expect(m.sessions == 2)
    #expect(m.nextWritable == 2048)
    #expect(m.totalSectors == 48878592)
}

@Test func minfoWithoutDisc() {
    #expect(Parsers.minfo("cdrecord: No disk / Wrong disk!") == nil)
}

@Test func parsesMsinfoAndSize() {
    #expect(Parsers.msinfo("cdrecord: Insufficient 'file read' privileges.\n0,2048\n") == "0,2048")
    #expect(Parsers.printSize("186\n") == 186)
}

@Test func parsesProgress() {
    #expect(Parsers.progress("Track 01:  123 of 4567 MB written (fifo 100%) [buf  99%]   4.0x.")! == (123, 4567))
    #expect(Parsers.progress("Track 01:    5 MB written (fifo 100%)")! == (5, 0))
    #expect(Parsers.progress("Fixating...") == nil)
}

@Test func parsesOpticalMounts() {
    let m = """
    /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
    /dev/disk6 on /Volumes/BDXL_20260930 (cd9660, local, nodev, nosuid, read-only, noowners)
    /dev/disk7s1 on /Volumes/X (udf, local)
    """
    #expect(Parsers.opticalMounts(m) == ["/dev/disk6", "/dev/disk7"])
}

@Test func escapesGraftAndLabel() {
    #expect(Commands.escapeGraft(#"a=b\c"#) == #"a\=b\\c"#)
    #expect(Commands.sanitizeLabel("My Disc: 2026/09 ÆØÅ extra long label here!!") == "My Disc 202609  extra long label")
}

@Test func buildsCommands() {
    let url = URL(fileURLWithPath: "/tmp")
    let a = Commands.mkisofsArgs(items: [url], label: "X", msinfo: "0,2048", dev: "2,0,0", printSize: true)
    #expect(a.contains("-C") && a.contains("0,2048") && a.contains("-dev"))
    #expect(a.last == "tmp/=/tmp")
    let c = Commands.cdrecordBurnArgs(dev: "2,0,0", sectors: 186, options: BurnOptions(volumeLabel: "X"))
    #expect(c.contains("-multi") && c.contains("tsize=186s") && c.last == "-")
    let closed = Commands.cdrecordBurnArgs(dev: "2,0,0", sectors: 1, options: BurnOptions(volumeLabel: "X", closeDisc: true))
    #expect(!closed.contains("-multi"))
}

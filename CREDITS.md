# Credits & Third-Party Notices

BurningArchive is a small graphical front end. Everything that actually talks to
the drive and builds the disc filesystem is done by **cdrtools** and
**dvd+rw-tools**, which the app runs as separate command-line programs.

## cdrtools — Jörg Schilling

- `cdrecord`: writes the data to the disc, reads disc info (`-scanbus`, `-minfo`, `-msinfo`)
- `mkisofs`: builds each ISO9660 / Rock Ridge / Joliet session and merges it with the previous one
- `libscg`: Schily SCSI transport library that `cdrecord` and `mkisofs` use to reach the drive
- `isoinfo`: used only by the test suite

Author: **Jörg Schilling** (1955–2021), with contributions from many others over
more than 25 years. Thank you, Jörg, for cdrecord.

- Homepage: <https://cdrtools.sourceforge.net/private/cdrecord.html>
- Project: <https://sourceforge.net/projects/cdrtools/>
- Maintained continuation (schilytools): <https://codeberg.org/schilytools/schilytools>

Licenses (as published by the cdrtools project):

| Component | License |
|---|---|
| cdrecord, libscg, and most libraries | CDDL-1.0 (Common Development and Distribution License) |
| mkisofs and its diagnostic tools (incl. isoinfo) | GPL-2.0 |

**Not bundled.** This repository and the compiled app contain **no** cdrtools code
or binaries, and the app does not link against any cdrtools library. It starts the
`cdrecord` and `mkisofs` programs that the user installed separately, usually with
Homebrew (`brew install cdrtools`). The cdrtools licenses therefore cover those
programs, not this app. BurningArchive's own code is MIT-licensed (see `LICENSE`).

## dvd+rw-tools — Andy Polyakov

- `growisofs`: writes sessions that leave a BD-R open (appendable), since cdrecord's
  BD-R driver always finalizes the disc

- Homepage: <http://fy.chalmers.se/~appro/linux/DVD+RW/>
- License: GPL-2.0

**Not bundled** either. The app starts the `growisofs` program the user installed
separately (`brew install dvd+rw-tools`).

## Homebrew

cdrtools and dvd+rw-tools for macOS are packaged by the Homebrew project:
<https://formulae.brew.sh/formula/cdrtools>, <https://formulae.brew.sh/formula/dvd+rw-tools> (BSD-2-Clause for the formula).

## Apple frameworks

Built with Swift, SwiftUI, AppKit, CoreGraphics and ImageIO from Apple's macOS SDK.
The app icon is drawn in code (`scripts/make-icon.swift`) and is original artwork
under this project's MIT license.

## Trademarks

Blu-ray Disc™, BD and BDXL™ are trademarks of the Blu-ray Disc Association. This
project is not affiliated with or endorsed by the Blu-ray Disc Association.
MATSHITA is a trademark of Panasonic Holdings Corporation.

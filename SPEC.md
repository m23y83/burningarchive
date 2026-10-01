# BurningArchive — Spec

Minimal native macOS app (SwiftUI) that burns files/folders to BD-R / BDXL discs
as **multisession** data discs using cdrtools (`cdrecord` + `mkisofs`).

## Goals
- Drag & drop files and folders into a window; burn them to disc.
- Every burn = one new session. Disc stays appendable until user closes it.
- Later sessions see (and keep) everything from earlier sessions: new session's
  filesystem is merged with the previous one (`mkisofs -C … -dev …`).
- Zero config when cdrtools installed via Homebrew.

## Non-goals
Audio/video discs, erasing BD-RE, ISO image burning, UDF, disc copy, verify-after-burn.

## Environment
- macOS 14+, Apple Silicon or Intel.
- cdrtools ≥ 3.x (`brew install cdrtools`). Looked up in `/opt/homebrew/bin`,
  `/usr/local/bin`, `/opt/schily/bin`, `/usr/bin`.
- No root required (verified: `cdrecord dev=2,0,0 -minfo` works as user).

## Functional requirements
1. **Tool check** — on launch locate `cdrecord` and `mkisofs`. Missing → banner with
   `brew install cdrtools` hint; Burn disabled.
2. **Drive discovery** — `cdrecord -scanbus`; parse lines
   `\t2,0,0\t200) 'VENDOR' 'MODEL' 'REV' Removable CD-ROM`. Show picker (vendor + model).
   Refresh button.
3. **Media info** — `cdrecord dev=<d> -minfo`; parse:
   `Mounted media type`, `disk status` (empty / incomplete / complete),
   `session status`, `number of sessions`, `Next writable address`,
   `Remaining writable size` (2048-byte sectors). Show type, status, sessions,
   used/free bar.
4. **Compilation** — drop zone accepting file URLs (files + folders), also "Add…"
   button (NSOpenPanel). List shows name, size, remove button. Folders placed on
   disc root as folder (`Name/=/path`); files at root (`name=/path`).
   Duplicate top-level names rejected. Total size shown vs free space.
5. **Options** — Volume label (≤32 chars, default `BDXL_<yyyyMMdd>`);
   "Close disc after this session (no more sessions)" toggle (default off);
   "Eject when done" toggle (default off).
6. **Burn** (confirmation dialog first):
   1. Unmount disc if mounted by macOS (`mount` → cd9660/udf device → `diskutil unmountDisk`).
   2. If disk status `incomplete`: `cdrecord dev=<d> -msinfo` → `a,b`.
   3. `mkisofs <opts> -quiet -print-size` → sectors N. Abort if N > remaining.
   4. `mkisofs <opts> | cdrecord dev=<d> -v gracetime=2 fs=64m driveropts=burnfree -data tsize=Ns [-multi] [-eject] -`
   5. Re-read media info, clear list on success.
   - mkisofs opts: `-R -J -joliet-long -iso-level 3 -V <label> -graft-points -m .DS_Store -m ._*`
     plus `-C a,b -dev <d>` when appending.
   - Graft names escape `\` and `=` with backslash.
7. **Progress** — parse cdrecord `Track 01:  123 of 4567 MB written` (split on `\r`
   and `\n`) → progress bar + phase text (preparing / writing / fixating / done).
   Full raw log in collapsible pane.
8. **Cancel** — terminates both processes. Warns that a cancelled BD-R session is
   likely lost space.
9. **States** — no disc, blank, appendable (n sessions), closed (burn disabled),
   error (message shown).

## Known limitations
- Files > 4 GiB use ISO9660 level-3 multi-extent; macOS Finder may not read them
  correctly (Linux/Windows do). UI shows warning for such files.
- Same top-level name as an existing item on disc → new version shadows the old one.
- Each session costs overhead (BD-R session lead-in/out ~ tens of MB).

## Architecture
SwiftPM executable (no Xcode project needed; builds with Command Line Tools),
wrapped into `BurningArchive.app` by `build.sh` (Info.plist + ad-hoc codesign).
Not sandboxed (must exec Homebrew binaries and talk to the drive).

| File | Role |
|---|---|
| `Package.swift` | SwiftPM manifest: `BurnCore` library + `BurningArchive` executable + tests |
| `BurnCore/Tools.swift` | tool lookup, async process runner |
| `BurnCore/Parsers.swift` | scanbus / minfo / msinfo / progress parsers, graft escaping |
| `BurnCore/Commands.swift` | builds mkisofs / cdrecord argument lists |
| `BurningArchive/BurnModel.swift` | `@MainActor ObservableObject`, orchestration, pipeline |
| `BurningArchive/ContentView.swift` | UI |
| `BurningArchive/App.swift` | `@main` |
| `Tests/BurnCoreTests` | parser + command-builder tests using real captured output |

# Plan

1. [x] Verify toolchain: Swift 6.4 CLT, cdrtools 3.02a09 via brew, drive `2,0,0` (MATSHITA UJ260) visible, `-minfo` works without root.
2. [x] Verify mkisofs semantics offline: `-print-size -quiet` → stdout sectors; graft points + `\=` escaping; `-M image -C 0,N` merge keeps old tree.
3. [x] `BurnCore`: parsers + command builders (pure, testable).
4. [x] Tests with real captured `-scanbus` / `-minfo` output; `swift test`.
5. [x] `BurnModel`: drive scan, media refresh, unmount, msinfo, print-size, mkisofs→cdrecord pipe, progress, cancel.
6. [x] SwiftUI `ContentView`: drive/media header, drop zone list, options, burn bar, log.
7. [x] `build.sh` → `BluRayBurner.app` (Info.plist, ad-hoc sign).
8. [x] Smoke test: launch app, drive + media detected. Offline end-to-end: run the exact generated mkisofs args to an image file for session 1 and 2 and inspect with isoinfo.
9. [x] Real burn — done by user; first session (85.7 GiB) confirmed working.

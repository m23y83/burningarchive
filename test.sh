#!/bin/bash
# Command Line Tools ship the swift-testing macro plugin but SwiftPM doesn't find it by default.
set -euo pipefail
cd "$(dirname "$0")"
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"

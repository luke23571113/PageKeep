#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}"
BUILD_DIR="${BUILD_ROOT%/}/PageKeep-Mac"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/PageKeep.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/PageKeep"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

# Ask only this built Mac app to quit, so its draft confirmation can run.
/usr/bin/swift - "$APP_BINARY" <<'SWIFT'
import AppKit
import Foundation
let path = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
for app in NSWorkspace.shared.runningApplications where app.executableURL?.resolvingSymlinksInPath().path == path {
    app.terminate()
    let deadline = Date().addingTimeInterval(10)
    while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    if !app.isTerminated {
        fputs("Save or discard changes in PageKeep, then run again.\n", stderr)
        exit(1)
    }
}
SWIFT
xcodebuild -project "$ROOT_DIR/PageKeep.xcodeproj" -scheme PageKeepMac \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- build

case "$MODE" in
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/PageKeep" ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "PageKeep"'
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.lukecollins.PageKeepMac"'
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE" --args --ui-testing
    sleep 1
    /usr/bin/swift - "$APP_BINARY" <<'SWIFT'
import AppKit
let path = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
let running = NSWorkspace.shared.runningApplications.contains { $0.executableURL?.resolvingSymlinksInPath().path == path }
exit(running ? 0 : 1)
SWIFT
    ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac

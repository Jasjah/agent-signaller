#!/bin/bash
# Build the release binaries and assemble AgentSignaller.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
# Force the classic build system so product paths are predictable
# (.build/release/...); some toolchains default to the new "swiftbuild" engine
# which uses a different layout.
BUILD_ARGS="-c release --build-system native"
swift build $BUILD_ARGS

BIN_DIR="$(swift build $BUILD_ARGS --show-bin-path)"
APP="$ROOT/AgentSignaller.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Main app binary (renamed to match CFBundleExecutable).
cp "$BIN_DIR/SignalerApp" "$APP/Contents/MacOS/AgentSignaller"
# Ship the CLI inside the bundle so a single artifact carries both.
cp "$BIN_DIR/SignalerCLI" "$APP/Contents/MacOS/agent-signaller"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so the app launches and SMAppService works locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "    (codesign skipped — app will still run unsigned)"

echo "==> done: $APP"
echo "    run with: open \"$APP\""
echo "    CLI is at: $APP/Contents/MacOS/agent-signaller"

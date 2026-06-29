#!/bin/bash
# Build, install AgentSignaller.app to /Applications, symlink the CLI, and wire
# up Claude Code + Codex configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-app.sh"

APP_SRC="$ROOT/AgentSignaller.app"
APP_DST="/Applications/AgentSignaller.app"
# The CLI inside the bundle is the stable, always-valid path used for hooks.
CLI_TARGET="$APP_DST/Contents/MacOS/agent-signaller"

echo "==> installing app to $APP_DST"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# Add a convenience `agent-signaller` to a user-writable dir on PATH (best effort,
# never fails the install). Hooks use the bundle path so this is purely for typing
# `agent-signaller status` in a terminal.
echo "==> adding convenience CLI symlink"
for dir in /opt/homebrew/bin "$HOME/.local/bin" /usr/local/bin; do
    if [ -w "$dir" ] || { [ ! -e "$dir" ] && mkdir -p "$dir" 2>/dev/null; }; then
        if ln -sf "$CLI_TARGET" "$dir/agent-signaller" 2>/dev/null; then
            echo "    linked $dir/agent-signaller"
            break
        fi
    fi
done

echo "==> wiring Claude hooks + Codex notify"
"$CLI_TARGET" install --bin "$CLI_TARGET"

echo "==> launching app"
open "$APP_DST"

echo
echo "Installed. The badge should appear in your chosen corner."
echo "Right-click the badge for options (corner, launch at login, quit)."

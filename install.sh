#!/bin/bash
# Remote bootstrap installer for agent-signaller.
#
#   curl -fsSL https://raw.githubusercontent.com/Jasjah/agent-signaller/main/install.sh | bash
#
# Fetches the source, builds it, installs the app + CLI, and wires up
# Claude Code + Codex. Builds from source, so it needs the Xcode command-line
# tools (`swift`). If you already have a checkout, just run ./scripts/install.sh.
set -euo pipefail

REPO_GIT="https://github.com/Jasjah/agent-signaller.git"
REPO_TARBALL="https://github.com/Jasjah/agent-signaller/archive/refs/heads/main.tar.gz"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found. Install the Xcode command-line tools first:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

# If run from inside a checkout, build from the working tree.
if [ -f "scripts/install.sh" ] && [ -f "Package.swift" ]; then
    exec bash scripts/install.sh
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> fetching agent-signaller source"
if command -v git >/dev/null 2>&1; then
    git clone --depth 1 "$REPO_GIT" "$TMP/src" >/dev/null 2>&1
else
    curl -fsSL "$REPO_TARBALL" | tar xz -C "$TMP"
    mv "$TMP"/agent-signaller-* "$TMP/src"
fi

cd "$TMP/src"
exec bash scripts/install.sh

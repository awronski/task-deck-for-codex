#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
APP="$DIST/Task Deck for Codex.app"
CONFIGURATION="release"

if [[ "${1:-}" == "--debug" ]]; then
    CONFIGURATION="debug"
    shift
fi

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/module-cache"

/usr/bin/swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --product TaskDeckForCodex

/bin/mkdir -p "$DIST"
STAGING_ROOT="$(/usr/bin/mktemp -d "$DIST/.task-deck-for-codex-stage.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Task Deck for Codex.app"
BACKUP_APP="$DIST/.Task Deck for Codex.app.previous"

cleanup() {
    /bin/rm -rf "$STAGING_ROOT"
    if [[ ! -d "$APP" && -d "$BACKUP_APP" ]]; then
        /bin/mv "$BACKUP_APP" "$APP"
    fi
}
trap cleanup EXIT

/bin/mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/bin/cp "$ROOT/.build/$CONFIGURATION/TaskDeckForCodex" "$STAGED_APP/Contents/MacOS/TaskDeckForCodex"
/bin/cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp "$ROOT/Resources/AppIcon.png" "$STAGED_APP/Contents/Resources/AppIcon.png"
/bin/cp "$ROOT/Resources/TaskDeckForCodex.icns" "$STAGED_APP/Contents/Resources/TaskDeckForCodex.icns"
/bin/chmod 755 "$STAGED_APP/Contents/MacOS/TaskDeckForCodex"

# Development-only ad-hoc signing. Public binaries need Developer ID signing and notarization.
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

/bin/rm -rf "$BACKUP_APP"
if [[ -d "$APP" ]]; then
    /bin/mv "$APP" "$BACKUP_APP"
fi

/bin/mv "$STAGED_APP" "$APP"
/bin/rm -rf "$BACKUP_APP"

if [[ "${1:-}" != "--build-only" ]]; then
    /usr/bin/open -n "$APP"
fi

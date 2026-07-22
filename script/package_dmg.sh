#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
APP="$DIST/Task Deck for Codex.app"
DMG_ROOT="$DIST/dmg-root"
DMG="$DIST/TaskDeckForCodex.dmg"
APP_ZIP="$DIST/TaskDeckForCodex-notary.zip"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
COMPLETED=0

cleanup() {
    /bin/rm -rf "$DMG_ROOT" "$APP_ZIP"
    if [[ "$COMPLETED" != "1" ]]; then
        /bin/rm -f "$DMG"
    fi
}

if [[ "$NOTARIZE" != "0" && "$NOTARIZE" != "1" ]]; then
    print -u2 "NOTARIZE must be 0 or 1."
    exit 1
fi

if [[ "$NOTARIZE" == "1" && -z "$SIGNING_IDENTITY" ]]; then
    print -u2 "NOTARIZE=1 requires SIGNING_IDENTITY."
    exit 1
fi

if [[ "$NOTARIZE" == "1" && -z "$NOTARY_PROFILE" ]]; then
    print -u2 "NOTARIZE=1 requires NOTARY_PROFILE."
    exit 1
fi

trap cleanup EXIT

notarize() {
    /usr/bin/xcrun notarytool submit "$1" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
}

"$ROOT/script/build_and_run.sh" --build-only

if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign \
        --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        "$APP"
else
    print "Using the app's development-only ad-hoc signature."
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$NOTARIZE" == "1" ]]; then
    /usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"
    notarize "$APP_ZIP"
    /usr/bin/xcrun stapler staple "$APP"
    /usr/bin/xcrun stapler validate "$APP"
    /usr/sbin/spctl -a -vvv -t exec "$APP"
    /bin/rm -f "$APP_ZIP"
fi

/bin/rm -rf "$DMG_ROOT" "$DMG"
/bin/mkdir -p "$DMG_ROOT"
/bin/cp -R "$APP" "$DMG_ROOT/"
/bin/ln -s /Applications "$DMG_ROOT/Applications"
/usr/bin/hdiutil create \
    -volname "Task Deck for Codex" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
    /usr/bin/codesign --verify --verbose=2 "$DMG"
fi

if [[ "$NOTARIZE" == "1" ]]; then
    notarize "$DMG"
    /usr/bin/xcrun stapler staple "$DMG"
    /usr/bin/xcrun stapler validate "$DMG"
    /usr/sbin/spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

/usr/bin/hdiutil verify "$DMG"
COMPLETED=1
print "$DMG"

#!/usr/bin/env bash
#
# release-dmg.sh — Package, sign, and stage a ForgedBrew Sparkle release DMG.
#
# Fixes the class of bug where the app ends up double-nested inside the DMG
# (…/ForgedBrew.app/ForgedBrew.app), which makes Sparkle report
# "improperly signed and could not be validated" even though the DMG's own
# EdDSA signature is valid. This script always stages the app at the DMG root
# and HARD-FAILS if the resulting structure is wrong.
#
# Usage:
#   ./release-dmg.sh /path/to/exported/ForgedBrew.app [output.dmg]
#
# If no app path is given, it defaults to the repo-root ForgedBrew.app.
# Output defaults to ~/Desktop/ForgedBrew.dmg.
#
# After it runs, it prints the appcast enclosure values (edSignature + length)
# and the steps to publish.

set -euo pipefail

# ----- Config -------------------------------------------------------------
REPO_DIR="/Users/rich/Developer/ForgedBrew"
VOLNAME="ForgedBrew"
DEV_ID="Developer ID Application: RICHARD EUGENE WALLACE (5UNQZ5Q2K9)"
TEAM_ID="5UNQZ5Q2K9"
BUNDLE_ID="com.highfieldlondon.ForgedBrew"

# ----- Args ---------------------------------------------------------------
APP_SRC="${1:-$REPO_DIR/ForgedBrew.app}"
OUT_DMG="${2:-$HOME/Desktop/ForgedBrew.dmg}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

fail() { red "ERROR: $*"; exit 1; }

# ----- Validate the SOURCE app before we package anything -----------------
bold "==> Validating source app: $APP_SRC"
[ -d "$APP_SRC" ] || fail "App not found: $APP_SRC"
[ -f "$APP_SRC/Contents/Info.plist" ] || fail "Source app has no Contents/Info.plist — it is malformed or itself nested: $APP_SRC"

# Guard against handing in an already-nested wrapper (…/ForgedBrew.app/ForgedBrew.app)
if [ -d "$APP_SRC/ForgedBrew.app" ] && [ ! -f "$APP_SRC/Contents/Info.plist" ]; then
  fail "Source app is double-nested. Point this script at the INNER ForgedBrew.app."
fi

# Confirm identity / signature / notarization of the source.
APP_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_SRC/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_SRC/Contents/Info.plist")
APP_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_SRC/Contents/Info.plist")
green "    version $APP_VER (build $APP_BUILD), id $APP_ID"
[ "$APP_ID" = "$BUNDLE_ID" ] || fail "Bundle id mismatch: expected $BUNDLE_ID, got $APP_ID"

bold "==> Verifying code signature + Gatekeeper on the source app"
codesign --verify --strict --verbose=2 "$APP_SRC" || fail "codesign --verify failed on source app"
if ! spctl --assess --type execute --verbose=2 "$APP_SRC" 2>&1 | grep -q "accepted"; then
  red "WARNING: spctl did not report 'accepted'. The app may not be notarized/stapled."
  red "         Sparkle requires a Developer ID-signed, notarized app. Continuing anyway."
fi

# ----- Stage a CLEAN dmg root (app at top level + /Applications symlink) ---
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
bold "==> Staging DMG contents in $STAGE"
# ditto preserves signatures/symlinks correctly (better than cp -R for bundles)
ditto "$APP_SRC" "$STAGE/ForgedBrew.app"
ln -s /Applications "$STAGE/Applications"

# ----- Build the DMG ------------------------------------------------------
bold "==> Building DMG: $OUT_DMG"
rm -f "$OUT_DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT_DMG" >/dev/null
green "    created $OUT_DMG"

# ----- GUARD: verify the DMG structure is NOT nested ----------------------
bold "==> Verifying DMG structure (the critical guard)"
MNT="$(mktemp -d)"
hdiutil attach "$OUT_DMG" -nobrowse -mountpoint "$MNT" -quiet 2>/dev/null \
  || { OUT=$(hdiutil attach "$OUT_DMG" -nobrowse 2>&1); MNT=$(echo "$OUT" | grep -oE '/Volumes/[^ ]+' | head -1); }

cleanup_mnt() { hdiutil detach "$MNT" -quiet 2>/dev/null || true; }
trap 'cleanup_mnt; rm -rf "$STAGE"' EXIT

if [ ! -f "$MNT/ForgedBrew.app/Contents/Info.plist" ]; then
  red "    FAILED: $MNT/ForgedBrew.app/Contents/Info.plist not found."
  if [ -d "$MNT/ForgedBrew.app/ForgedBrew.app" ]; then
    red "    The app is DOUBLE-NESTED inside the DMG. Aborting — do not ship this."
  fi
  fail "DMG structure is invalid."
fi

# Re-verify the app inside the DMG signs/notarizes correctly.
codesign --verify --strict --verbose=2 "$MNT/ForgedBrew.app" >/dev/null 2>&1 \
  || fail "App inside DMG failed codesign --verify."
spctl --assess --type execute "$MNT/ForgedBrew.app" >/dev/null 2>&1 \
  || red "WARNING: app inside DMG not Gatekeeper-accepted (notarization?)."
green "    OK: app is at DMG root, Contents/Info.plist present, signature valid."
cleanup_mnt
trap 'rm -rf "$STAGE"' EXIT

# ----- Sign the DMG with Sparkle's EdDSA key ------------------------------
bold "==> Signing DMG with Sparkle (sign_update)"
SIGN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -type f 2>/dev/null | head -1)"
[ -n "$SIGN" ] || fail "sign_update not found in DerivedData. Build the app once so SPM resolves Sparkle."
SIG_LINE="$("$SIGN" "$OUT_DMG")"
DMG_LEN=$(stat -f%z "$OUT_DMG")
DMG_SHA=$(shasum -a 256 "$OUT_DMG" | awk '{print $1}')

green ""
green "================ RELEASE READY ================"
echo  "Version:     $APP_VER (build $APP_BUILD)"
echo  "DMG:         $OUT_DMG"
echo  "Length:      $DMG_LEN bytes"
echo  "SHA-256:     $DMG_SHA"
echo  "Sparkle sig: $SIG_LINE"
green "==============================================="
echo  ""
bold  "Appcast enclosure to use:"
cat <<EOF
            <enclosure
                url="https://github.com/HighfieldLondon/ForgedBrew/releases/download/v$APP_VER/ForgedBrew.dmg"
                sparkle:version="$APP_BUILD"
                sparkle:shortVersionString="$APP_VER"
                length="$DMG_LEN"
                type="application/octet-stream"
                $SIG_LINE />
EOF
echo  ""
bold  "Then publish:"
cat <<EOF
  cd "$REPO_DIR"
  # (update appcast.xml's v$APP_VER enclosure with the length + sparkle:edSignature above)
  git add appcast.xml && git commit -m "Release $APP_VER" && git push
  gh release upload "v$APP_VER" "$OUT_DMG" --clobber
EOF

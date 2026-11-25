#!/bin/bash
# Build LockscreenDah.app from the SPM executable.
#   ./build.sh            -> build/LockscreenDah.app
#   ./build.sh --install  -> also (re)install to /Applications, grant camera TCC, relaunch
#   ./build.sh --install --no-grant -> skip the TCC grant step
set -euo pipefail
cd "$(dirname "$0")"

EXECUTABLE="LockscreenDah"       # binary / SPM target (ASCII-safe)
BUNDLE_NAME="Lockscreen Dah"     # on-disk app name (matches Info.plist)
APP="build/$BUNDLE_NAME.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXECUTABLE" "$APP/Contents/MacOS/"
# Symbol tables are ~half the binary; the .dSYM in .build/release keeps
# crash logs symbolicatable.
strip "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/Icon.png "$APP/Contents/Resources/"
if [ -d Resources/FaceEmbedding.mlmodelc ]; then
  cp -R Resources/FaceEmbedding.mlmodelc "$APP/Contents/Resources/"
else
  echo "warning: Resources/FaceEmbedding.mlmodelc missing — run scripts/fetch-model.sh first." >&2
  echo "         The app will fall back to presence-only detection (any face counts)." >&2
fi

# Hardened Runtime (--options runtime): makes the loader ignore
# DYLD_INSERT_LIBRARIES and enforce library validation, so local code can't
# inject a dylib into this always-camera-on process to ride its TCC grant.
# Apple-signed dlopen (login.framework), Core ML, and AVFoundation are all
# unaffected. The app loads no third-party dylibs, so nothing else breaks.
#
# Sign with the stable self-signed identity when it is available. The TCC
# record written by scripts/grant-camera-tcc.sh is a `certificate root`
# requirement, which survives rebuilds; ad-hoc signing binds it to a cdhash
# that changes on every build — the drift that made the old record unusable.
# Runtime + camera entitlement must stay on: an earlier hand re-sign dropped
# both without noticing.
SIGN_IDENTITY="InputMapper Self-Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  codesign --force --options runtime \
    --entitlements Resources/LockscreenDah.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  echo "warning: '$SIGN_IDENTITY' not found; signing ad-hoc." >&2
  echo "         The TCC record will be cdhash-bound; re-run scripts/grant-camera-tcc.sh after every build." >&2
  codesign --force --options runtime \
    --entitlements Resources/LockscreenDah.entitlements --sign - "$APP"
fi
echo "Built $APP"

INSTALL=0
GRANT_TCC=1
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --no-grant) GRANT_TCC=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$INSTALL" = 1 ]; then
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  # Wait for the old process to actually exit before relaunching. Reinstalling
  # in a tight loop used to relaunch within milliseconds, while the dying
  # instance still held the capture device — so the new one got no frames inside
  # its startup allowance and reported "Camera failed to start".
  for _ in $(seq 1 30); do
    pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || break
    sleep 0.1
  done
  sleep 0.5  # give the camera daemon a moment to release the device
  rm -rf "/Applications/$BUNDLE_NAME.app" "/Applications/Lockscreen Dah?.app" "/Applications/LockscreenDah.app"
  cp -R "$APP" "/Applications/$BUNDLE_NAME.app"
  echo "Installed /Applications/$BUNDLE_NAME.app"
  # Grant before opening: a denied .app stays alive holding the single-instance
  # lock while it shows its permission alert, which then blocks the .command
  # launcher. If the grant cannot be applied, leave the app closed and fall
  # back to the .command path.
  if [ "$GRANT_TCC" = 1 ] && ./scripts/grant-camera-tcc.sh "/Applications/$BUNDLE_NAME.app"; then
    open "/Applications/$BUNDLE_NAME.app"
  else
    echo "TCC grant not applied. Launch with /Applications/启动 Lockscreen Dah.command,"
    echo "or run ./scripts/grant-camera-tcc.sh \"/Applications/$BUNDLE_NAME.app\" manually."
  fi
fi

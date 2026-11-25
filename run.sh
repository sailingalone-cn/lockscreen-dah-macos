#!/bin/bash
# Launch Lockscreen Dah on a Mac whose TCC cannot grant camera access to an app
# bundle (this X1 Extreme hackintosh: a signed or ad-hoc bundle asks, gets
# "denied" without any prompt ever appearing).
#
# An *unsigned* build started from a terminal is treated as a child tool: it
# inherits the terminal's camera permission instead of asking for its own.
# Measured: signed launch → auth=0 → denied; unsigned launch → auth=3 → stream.
#
# So: copy the built bundle, strip its signature, run the executable directly.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/Lockscreen Dah.app"

if [ ! -d "$APP" ]; then
  echo "not built yet — run ./build.sh first" >&2
  exit 1
fi

DEST="/tmp/LockscreenDah-unsigned.app"
LOG="/tmp/lockscreen-dah.log"

rm -rf "$DEST"
cp -R "$APP" "$DEST"
rm -rf "$DEST/Contents/_CodeSignature"
codesign --remove-signature "$DEST/Contents/MacOS/LockscreenDah" 2>/dev/null || true

nohup "$DEST/Contents/MacOS/LockscreenDah" >>"$LOG" 2>&1 &
echo "Lockscreen Dah started (pid $!)"
echo "log: $LOG"

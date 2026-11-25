#!/bin/bash
# scripts/grant-camera-tcc.sh — give the installed app its own camera TCC record
# whose code requirement matches the app's current signature.
#
# Why this exists: this machine cannot show TCC prompts at all
# (boot-args amfi=0x80 + csr-active-config=0x0FFF). The only non-.command launch
# path is a stored record that already matches. The existing record was bound to
# an old build's cdhash (40-byte requirement), so it never matched; this script
# rewrites that requirement to the app's designated requirement — for a
# self-signed app that is `identifier … and certificate root = H"…"` (84 bytes),
# which survives rebuilds.
#
# usage: grant-camera-tcc.sh [APP_PATH] [--dry-run]
set -euo pipefail

APP="/Applications/Lockscreen Dah.app"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) APP="$arg" ;;
  esac
done

BUNDLE_ID="com.xavierloo.lockscreen-dah"
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -d "$APP" ] || { echo "ERROR: app not found: $APP" >&2; exit 1; }
[ -r "$TCC_DB" ] || { echo "ERROR: cannot read $TCC_DB (needs Full Disk Access)" >&2; exit 1; }

# 1. The app's designated requirement, exactly as signed right now.
codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p' > "$WORK/req.txt"
if ! grep -q 'identifier' "$WORK/req.txt"; then
  echo "ERROR: cannot read a designated requirement from $APP" >&2
  exit 1
fi
if grep -q 'cdhash' "$WORK/req.txt"; then
  echo "ERROR: $APP is ad-hoc signed, so the requirement is cdhash-bound and will" >&2
  echo "       drift on the next build. Re-sign with 'InputMapper Self-Signed' first." >&2
  exit 1
fi

# 2. Serialize it the way TCC stores requirements.
/usr/bin/csreq -r "$WORK/req.txt" -b "$WORK/req.bin"
NEW_HEX="$(xxd -p "$WORK/req.bin" | tr -d '\n')"
NEW_LEN="$(wc -c < "$WORK/req.bin" | tr -d ' ')"
echo "app:    $APP"
echo "DR:     $(cat "$WORK/req.txt")"
echo "csreq:  $NEW_LEN bytes"

# 3. Refuse to touch a database that does not have exactly one camera row.
COUNT="$(sqlite3 "$TCC_DB" "SELECT COUNT(*) FROM access WHERE service='kTCCServiceCamera' AND client='$BUNDLE_ID' AND client_type=0;")"
if [ "$COUNT" -ne 1 ]; then
  echo "ERROR: expected exactly one camera row for $BUNDLE_ID, found $COUNT." >&2
  echo "       Run the app once so it registers, or inspect the database by hand." >&2
  exit 1
fi

CURRENT_HEX="$(sqlite3 "$TCC_DB" "SELECT hex(csreq) FROM access WHERE service='kTCCServiceCamera' AND client='$BUNDLE_ID' AND client_type=0;" | tr 'A-F' 'a-f')"
echo "stored: ${#CURRENT_HEX} hex chars ($(( ${#CURRENT_HEX} / 2 )) bytes), auth_value=$(sqlite3 "$TCC_DB" "SELECT auth_value FROM access WHERE service='kTCCServiceCamera' AND client='$BUNDLE_ID' AND client_type=0;")"

if [ "$CURRENT_HEX" = "$NEW_HEX" ]; then
  echo "already granted: the stored requirement already matches this build."
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run: would UPDATE access SET csreq=X'$NEW_HEX', auth_value=2, auth_reason=2,"
  echo "         auth_version=1, flags=0, last_modified=now WHERE camera row,"
  echo "         then kickstart gui/$(id -u)/com.apple.tccd."
  exit 0
fi

# 4. Back up (SQLite-consistent) and update. busy_timeout covers tccd's own writes.
BACKUP="$TCC_DB.bak.$(date +%Y%m%d-%H%M%S)"
sqlite3 "$TCC_DB" ".backup '$BACKUP'"
echo "backup: $BACKUP"

sqlite3 "$TCC_DB" <<SQL
.timeout 5000
UPDATE access
   SET csreq = X'$NEW_HEX',
       auth_value = 2,
       auth_reason = 2,
       auth_version = 1,
       flags = 0,
       last_modified = CAST(strftime('%s','now') AS INTEGER)
 WHERE service = 'kTCCServiceCamera'
   AND client = '$BUNDLE_ID'
   AND client_type = 0;
SQL

# 5. Reload tccd so its in-memory evaluation stops using the old requirement.
launchctl kickstart -k "gui/$(id -u)/com.apple.tccd"
sleep 1

# 6. Verify the stored bytes.
STORED_HEX="$(sqlite3 "$TCC_DB" "SELECT hex(csreq) FROM access WHERE service='kTCCServiceCamera' AND client='$BUNDLE_ID' AND client_type=0;" | tr 'A-F' 'a-f')"
if [ "$STORED_HEX" != "$NEW_HEX" ]; then
  echo "ERROR: verification failed (stored $(( ${#STORED_HEX} / 2 )) bytes). Restore $BACKUP." >&2
  exit 1
fi
echo "OK: stored csreq is now $(( ${#STORED_HEX} / 2 )) bytes and matches this build."
echo "Next: quit the running instance, then open \"$APP\" directly to test."

#!/bin/bash
# dedupe-test.sh - verify the archive behaviour of copyusb.sh without needing
# root, a NAS, or a real USB drive.
#
# It builds a mock environment (fake block device, mocked mountpoint/findmnt)
# and asserts the three behaviours that matter:
#
#   1. a first plug-in copies every file
#   2. re-plugging an identical card copies NOTHING and creates NO folder
#   3. adding one new clip copies exactly that one clip
#
# Usage: bash test/dedupe-test.sh [path-to-copyusb.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/copyusb.sh}"
[[ -f "$SCRIPT" ]] || { echo "cannot find copyusb.sh at $SCRIPT" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/nas/xpg006camera" "$T/usb/DCIM/Movie" "$T/dev"
: > "$T/dev/sda1"

# --- fake card contents ----------------------------------------------------
printf 'CLIP-ONE'   > "$T/usb/DCIM/Movie/clip1.MP4"
printf 'CLIP-TWO'   > "$T/usb/DCIM/Movie/clip2.MP4"
echo   'metadata'   > "$T/usb/INFO.TXT"

# --- mocked system tools ---------------------------------------------------
# mountpoint: report only our fake NAS mount as mounted
cat > "$T/bin/mountpoint" <<EOF
#!/bin/bash
[[ "\$2" == "$T/nas/xpg006camera" ]] && exit 0 || exit 1
EOF
# findmnt: pretend /dev/sda1 is mounted at our fake usb dir
cat > "$T/bin/findmnt" <<EOF
#!/bin/bash
echo "$T/dev/sda1 $T/usb ext4 rw,relatime"
echo "/dev/mmcblk0p2 / ext4 rw,relatime"
EOF
# lsblk: no PKNAME available, forcing the script's name-based fallback
printf '#!/bin/bash\nexit 0\n' > "$T/bin/lsblk"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sync"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
chmod +x "$T/bin/"*

cat > "$T/conf" <<EOF
MOUNTPOINT="$T/nas/xpg006camera"
LOCK_FILE="$T/run.lock"
LED_TRIGGER="$T/no-such-led"
MQTT_ENABLED="0"
EOF

run_copy() {
    XPG_ALLOW_FAKE_DEV=1 XPG_CONF="$T/conf" PATH="$T/bin:$PATH" \
        bash "$SCRIPT" "$T/dev/sda1" --once 2>&1
}
ARCHIVE="$T/nas/xpg006camera/xpg006camera"
folders() { ls -1d "$ARCHIVE"/*/ 2>/dev/null | grep -v _logs | wc -l | tr -d ' '; }
files()   { find "$ARCHIVE" -type f -not -path '*_logs*' 2>/dev/null | wc -l | tr -d ' '; }

fail=0
check() { # check <description> <actual> <expected>
    if [[ "$2" == "$3" ]]; then
        printf '  ok   %-46s %s\n' "$1" "$2"
    else
        printf '  FAIL %-46s got=%s want=%s\n' "$1" "$2" "$3"
        fail=1
    fi
}

echo "Testing: $SCRIPT"
echo
echo "1. first plug-in (empty archive)"
out="$(run_copy)"
echo "$out" | grep -E 'new file\(s\)|destination:' | sed 's/^/     /'
check "folders created" "$(folders)" "1"
check "files archived"  "$(files)"   "3"

echo
echo "2. identical card re-plugged"
out="$(run_copy)"
echo "$out" | grep -E 'new file\(s\)|nothing new' | sed 's/^/     /'
check "no extra folder" "$(folders)" "1"
check "no extra files"  "$(files)"   "3"
grep -q 'nothing new' <<<"$out" && printf '  ok   %-46s\n' "reported as nothing new" \
                                 || { printf '  FAIL %-46s\n' "reported as nothing new"; fail=1; }

echo
echo "3. one new clip added to the card"
echo 'CLIP-THREE' > "$T/usb/DCIM/Movie/clip3.MP4"
out="$(run_copy)"
echo "$out" | grep -E 'new file\(s\)|done:' | sed 's/^/     /'
check "one extra folder" "$(folders)" "2"
check "one extra file"   "$(files)"   "4"
grep -q '1 new file(s) to transfer' <<<"$out" \
    && printf '  ok   %-46s\n' "only the new clip transferred" \
    || { printf '  FAIL %-46s\n' "only the new clip transferred"; fail=1; }

echo
if (( fail )); then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: all checks passed"

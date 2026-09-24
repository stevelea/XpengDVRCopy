#!/bin/bash
# copyusb.sh - copy car-camera footage from a just-plugged USB drive to the NAS share.
#
# Installed by install.sh to /usr/local/bin/copyusb.sh
# Usage:  copyusb.sh /dev/sda1 [--once]
#           --once   skip the "wait for NAS" gate (used for manual testing)
#
# What appears on the share:
#   <mount>/xpg006camera/<YYYY-MM-DD_HHMMSS>/   one folder per plug-in
#   <mount>/xpg006camera/_logs/copy.log         running history
#
# Re-plugging the same card is SAFE: a file whose relative path is already
# archived is never transferred again, so the archive does not fill up with
# duplicate copies of the same clips. Only genuinely new footage is sent.
set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration - override any of these in /etc/xpg-camera-copy.conf
# ----------------------------------------------------------------------------
NAS_IP="192.168.1.235"
NAS_SHARE="Shared_Drive"
DEST_SUBDIR="xpg006camera"           # folder inside the share
MOUNTPOINT="/mnt/nas/xpg006camera"   # where the share is mounted

# Copy everything by default. Set COPY_MODE="videos" to restrict to VIDEO_EXT
# (space separated, lowercase, no dot).
COPY_MODE="all"
VIDEO_EXT="mp4 mov avi mkv ts m4v 3gp lrv insv"

# How long to wait for the NAS to wake up before giving up.
NAS_WAIT_SECONDS="300"

LOCK_FILE="/run/xpg-camera-copy.lock"

# LED feedback. Names differ per board - Raspberry Pi uses ACT, Orange Pi boards
# expose green:red, some expose none at all. Leave LED_NAME empty to take the
# first LED that can be driven, or set LED_NAME="none" for no LED. A board with
# no controllable LED is fine: the copy is unaffected and the MQTT status is the
# indication instead.
LED_NAME="${LED_NAME:-}"
LED_DIR=""                                  # resolved below
LED_IDLE_TRIGGER="none"                     # the board's own default, restored on idle
LED_TRIGGER=""
LED_BRIGHTNESS=""

resolve_led() {
    [[ "$LED_NAME" == "none" ]] && return 0
    local root="${LED_ROOT:-/sys/class/leds}"
    local base candidates=()
    if [[ -n "$LED_NAME" ]]; then
        candidates=("$root/$LED_NAME")
    else
        # Prefer names known to be status LEDs, then anything writable. The
        # board-specific ones matter: without them the glob can land on a
        # keyboard LED such as input3::capslock, which looks like it worked and
        # tells you nothing.
        candidates=(
            "$root/ACT"                     # Raspberry Pi
            "$root/orangepi:red:status"     # Orange Pi - the status LED
            "$root/orangepi:green:power"    # Orange Pi - power, used only as a fallback
            "$root/green" "$root/green:red" "$root/red"
        )
        for d in "$root"/*; do
            case "$d" in *input*|*capslock*|*numlock*|*scrolllock*) continue ;; esac
            [[ -e "$d" ]] && candidates+=("$d")
        done
    fi
    for base in "${candidates[@]}"; do
        if [[ -w "$base/trigger" ]]; then
            LED_DIR="$base"
            LED_TRIGGER="$base/trigger"
            LED_BRIGHTNESS="$base/brightness"
            # Remember what the board had, so idle can put it back. mmc0 is a
            # Raspberry Pi trigger; on another board it means nothing.
            LED_IDLE_TRIGGER="$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$base/trigger" 2>/dev/null)"
            [[ -n "$LED_IDLE_TRIGGER" ]] || LED_IDLE_TRIGGER="none"
            return 0
        fi
    done
    return 0
}

# MQTT status reporting (for Home Assistant). Set MQTT_ENABLED="0" to disable.
# States published: idle -> waiting -> copying -> safe | error
MQTT_ENABLED="1"
MQTT_HOST="192.168.1.88"
MQTT_PORT="1883"
MQTT_USER="mqtt"
MQTT_PASS=""                 # set in /etc/xpg-camera-copy.conf
MQTT_PREFIX="xpg006camera"          # topic prefix
MQTT_DEVICE_NAME="Camera archiver"  # shown in Home Assistant
MQTT_DEVICE_ID="xpg006camera_archiver"   # unique; change if you run two
MQTT_DEVICE_MODEL="USB card archiver"
MQTT_DEVICE_MANUFACTURER=""          # blank leaves it out of the payload
MQTT_RETAIN="1"                     # retain so Home Assistant sees the last state
MQTT_TIMEOUT="10"                   # seconds

# Config file (XPG_CONF overrides the location; used by the test harness).
CONF_FILE="${XPG_CONF:-/etc/xpg-camera-copy.conf}"
if [[ -r "$CONF_FILE" ]]; then . "$CONF_FILE"; fi
resolve_led

DEV="${1:-}"
ONCE=0
DISCOVERY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --once)      ONCE=1 ;;
        --discovery) DISCOVERY_ONLY=1 ;;
        -h|--help)   echo "usage: $0 /dev/sdX[1-9] [--once] | --discovery"; exit 0 ;;
    esac
done

ARCHIVE_ROOT="${MOUNTPOINT}/${DEST_SUBDIR}"
SHARE_LOG_DIR="${ARCHIVE_ROOT}/_logs"

# MQTT topics
MQTT_TOPIC_STATUS="${MQTT_PREFIX}/status"        # idle | waiting | copying | safe | error
MQTT_TOPIC_DETAIL="${MQTT_PREFIX}/detail"        # human readable, e.g. "copying 2025_0917_120000_0001.MP4"
MQTT_TOPIC_LAST="${MQTT_PREFIX}/last_copy"       # timestamp of the last successful copy
MQTT_TOPIC_AVAIL="${MQTT_PREFIX}/availability"   # online | offline
MQTT_TOPIC_CMD="${MQTT_PREFIX}/cmd"              # HA button/switch writes here
MQTT_TOPIC_COUNT="${MQTT_PREFIX}/last_count"    # files copied by the last run
MQTT_TOPIC_USB="${MQTT_PREFIX}/usb"             # on | off - is the stick connected
MQTT_DISCOVERY_PREFIX="${MQTT_DISCOVERY_PREFIX:-homeassistant}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
now() { date '+%Y-%m-%d %H:%M:%S'; }
# ISO 8601 met tijdzone-offset. Home Assistant eist dit formaat voor
# een sensor met device_class 'timestamp'; een spatie en geen offset
# laat de entiteit onbeschikbaar.
now_iso() { date '+%Y-%m-%dT%H:%M:%S%:z'; }

log() {
    local msg="[$(now)] $*"
    echo "$msg" >&2
    # Mirror to the share once mounted, so a permanent history exists there.
    if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        mkdir -p "$SHARE_LOG_DIR" 2>/dev/null
        echo "$msg" >> "$SHARE_LOG_DIR/copy.log" 2>/dev/null
    fi
}

stamp() { date '+%Y-%m-%d_%H%M%S'; }

# Onboard LED: solid while copying, slow blink = success, fast blink = failure.
set_led() {
    [[ -n "$LED_DIR" && -w "$LED_TRIGGER" ]] || return 0
    case "$1" in
        busy)  echo none  > "$LED_TRIGGER" 2>/dev/null; echo 1 > "$LED_BRIGHTNESS" 2>/dev/null ;;
        done)  echo timer > "$LED_TRIGGER" 2>/dev/null
               echo 500 > "$LED_DIR/delay_on"  2>/dev/null
               echo 500 > "$LED_DIR/delay_off" 2>/dev/null ;;
        error) echo timer > "$LED_TRIGGER" 2>/dev/null
               echo 100 > "$LED_DIR/delay_on"  2>/dev/null
               echo 900 > "$LED_DIR/delay_off" 2>/dev/null ;;
        idle)  echo "$LED_IDLE_TRIGGER" > "$LED_TRIGGER" 2>/dev/null ;;
    esac
}

die() {
    log "ERROR: $*"
    set_led error
    publish "error" "$*"
    exit 1
}

# ----------------------------------------------------------------------------
# MQTT status publishing. Never allowed to break a copy: if the broker or the
# client is unavailable we log it and carry on.
# ----------------------------------------------------------------------------
publish() {
    local state="$1" detail="${2:-}"
    [[ "$MQTT_ENABLED" == "1" ]] || return 0
    command -v mosquitto_pub >/dev/null 2>&1 || return 0

    local args=(-h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -q 1)
    [[ "$MQTT_RETAIN" == "1" ]] && args+=(-r)

    if ! timeout "$MQTT_TIMEOUT" mosquitto_pub "${args[@]}" \
            -t "$MQTT_TOPIC_STATUS" -m "$state" 2>/dev/null; then
        echo "[$(now)] WARNING: MQTT publish failed (broker $MQTT_HOST unreachable?)" >&2
        return 0
    fi
    if [[ -n "$detail" ]]; then
        timeout "$MQTT_TIMEOUT" mosquitto_pub "${args[@]}" \
            -t "$MQTT_TOPIC_DETAIL" -m "$detail" 2>/dev/null
    fi
    return 0
}

# Availability: "online" while a plug-in is being handled, "offline" otherwise.
# Home Assistant marks the entities unavailable when the Pi is down.
# Kaart aangesloten of niet. Wordt ook door de udev-regel bij verwijderen
# gezet, zodat Home Assistant het verschil ziet.
publish_usb_state() {
    local state="$1"
    [[ "$MQTT_ENABLED" == "1" ]] || return 0
    command -v mosquitto_pub >/dev/null 2>&1 || return 0
    timeout "$MQTT_TIMEOUT" mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" -q 1 -r \
        -t "$MQTT_TOPIC_USB" -m "$state" 2>/dev/null
}

publish_avail() {
    local state="$1"
    [[ "$MQTT_ENABLED" == "1" ]] || return 0
    command -v mosquitto_pub >/dev/null 2>&1 || return 0
    timeout "$MQTT_TIMEOUT" mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" -q 1 -r \
        -t "$MQTT_TOPIC_AVAIL" -m "$state" 2>/dev/null
}

# Timestamp of the last successful copy.
# Aantal overgezette bestanden van de laatste ronde. 0 betekent: kaart al
# bekend, niets nieuws. Zo is van buitenaf te zien of er iets gebeurd is.
publish_count() {
    local n="${1:-0}"
    [[ "$MQTT_ENABLED" == "1" ]] || return 0
    command -v mosquitto_pub >/dev/null 2>&1 || return 0
    timeout "$MQTT_TIMEOUT" mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" -q 1 -r \
        -t "$MQTT_TOPIC_COUNT" -m "$n" 2>/dev/null
}

publish_last_copy() {
    [[ "$MQTT_ENABLED" == "1" ]] || return 0
    command -v mosquitto_pub >/dev/null 2>&1 || return 0
    timeout "$MQTT_TIMEOUT" mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" -q 1 -r \
        -t "$MQTT_TOPIC_LAST" -m "$(now_iso)" 2>/dev/null
}

# Publish a message read from stdin. Used for JSON so nothing needs escaping.
mqtt_pub_stdin() {
    local topic="$1"
    timeout "$MQTT_TIMEOUT" mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" -q 1 -r -t "$topic" -s 2>/dev/null
}

# Home Assistant discovery: creates the entities automatically on first run.
# The payloads are generated with python3 so the JSON is always valid - doing
# this with shell quoting is a losing game when Jinja templates are involved.
publish_discovery() {
    [[ "$MQTT_ENABLED" == "1" ]] || return 0
    command -v mosquitto_pub >/dev/null 2>&1 || { echo "mosquitto_pub is not installed" >&2; return 1; }
    command -v python3      >/dev/null 2>&1 || { echo "python3 is not installed" >&2; return 1; }

    local prefix="$MQTT_DISCOVERY_PREFIX"

    # --- status sensor (the one you actually watch) -------------------------
    python3 - "$MQTT_TOPIC_STATUS" "$MQTT_TOPIC_AVAIL" "$MQTT_TOPIC_DETAIL" <<'PYEOF' | mqtt_pub_stdin "$prefix/sensor/xpg006camera/status/config"
import json, sys
status, avail, detail = sys.argv[1:4]
print(json.dumps({
    "name": "Car camera copy status",
    "unique_id": "xpg006camera_status",
    "state_topic": status,
    "json_attributes_topic": detail,
    "availability_topic": avail,
    "payload_available": "online",
    "payload_not_available": "offline",
    "icon": "mdi:content-duplicate",
    "device": {
        "identifiers": ["$MQTT_DEVICE_ID"],
        "name": "$MQTT_DEVICE_NAME",
        "manufacturer": "$MQTT_DEVICE_MANUFACTURER",
        "model": "$MQTT_DEVICE_MODEL",
    },
}))
PYEOF
    echo "  discovery: status sensor"

    # --- safe-to-remove binary sensor ---------------------------------------
    python3 - "$MQTT_TOPIC_STATUS" "$MQTT_TOPIC_AVAIL" <<'PYEOF' | mqtt_pub_stdin "$prefix/binary_sensor/xpg006camera/safe/config"
import json, sys
status, avail = sys.argv[1:3]
print(json.dumps({
    "name": "Car camera safe to remove",
    "unique_id": "xpg006camera_safe",
    "state_topic": status,
    "availability_topic": avail,
    "payload_available": "online",
    "payload_not_available": "offline",
    "value_template": "{{ 'ON' if value == 'safe' else 'OFF' }}",
    "device_class": "running",
    "icon": "mdi:usb-flash-drive",
    "device": {
        "identifiers": ["$MQTT_DEVICE_ID"],
        "name": "$MQTT_DEVICE_NAME",
    },
}))
PYEOF
    echo "  discovery: safe-to-remove binary sensor"

    # --- last copy timestamp -------------------------------------------------
    python3 - "$MQTT_TOPIC_LAST" "$MQTT_TOPIC_AVAIL" <<'PYEOF' | mqtt_pub_stdin "$prefix/sensor/xpg006camera/last_copy/config"
import json, sys
last, avail = sys.argv[1:3]
print(json.dumps({
    "name": "Car camera last copy",
    "unique_id": "xpg006camera_last",
    "state_topic": last,
    "availability_topic": avail,
    "payload_available": "online",
    "payload_not_available": "offline",
    "device_class": "timestamp",
    "icon": "mdi:clock-check-outline",
    "device": {
        "identifiers": ["$MQTT_DEVICE_ID"],
        "name": "$MQTT_DEVICE_NAME",
    },
}))
PYEOF
    echo "  discovery: last-copy sensor"

    # Kaart aangesloten?
    mqtt_pub_stdin "$MQTT_DISCOVERY_PREFIX/binary_sensor/xpg006camera/usb/config" <<JSON
{"name":"Car camera USB connected","unique_id":"xpg006camera_usb","state_topic":"$MQTT_TOPIC_USB","payload_on":"on","payload_off":"off","availability_topic":"$MQTT_TOPIC_AVAIL","payload_available":"online","payload_not_available":"offline","device_class":"plug","icon":"mdi:usb-flash-drive","device":{"identifiers":["$MQTT_DEVICE_ID"],"name":"$MQTT_DEVICE_NAME"}}
JSON
    echo "  discovery: usb connected"

    # Hoeveel bestanden de laatste ronde overzette (0 = niets nieuws).
    mqtt_pub_stdin "$MQTT_DISCOVERY_PREFIX/sensor/xpg006camera/count/config" <<JSON
{"name":"Car camera new clips","unique_id":"xpg006camera_count","state_topic":"$MQTT_TOPIC_COUNT","availability_topic":"$MQTT_TOPIC_AVAIL","payload_available":"online","payload_not_available":"offline","unit_of_measurement":"files","icon":"mdi:file-video-plus","device":{"identifiers":["$MQTT_DEVICE_ID"],"name":"$MQTT_DEVICE_NAME"}}
JSON
    echo "  discovery: new-clips count"

    # Toestand van de kijker op de NAS: wanneer voor het laatst geindexeerd.
    mqtt_pub_stdin "$MQTT_DISCOVERY_PREFIX/sensor/xpg006camera/indexed/config" <<JSON
{"name":"Car camera viewer indexed","unique_id":"xpg006camera_indexed","state_topic":"xpg006camera/indexed","availability_topic":"$MQTT_TOPIC_AVAIL","payload_available":"online","payload_not_available":"offline","device_class":"timestamp","icon":"mdi:database-clock","device":{"identifiers":["$MQTT_DEVICE_ID"],"name":"$MQTT_DEVICE_NAME"}}
JSON
    echo "  discovery: viewer indexed"

    # Aantal clips in de kijker.
    mqtt_pub_stdin "$MQTT_DISCOVERY_PREFIX/sensor/xpg006camera/clips/config" <<JSON
{"name":"Car camera clips indexed","unique_id":"xpg006camera_clips","state_topic":"xpg006camera/clips","availability_topic":"$MQTT_TOPIC_AVAIL","payload_available":"online","payload_not_available":"offline","unit_of_measurement":"clips","icon":"mdi:video-vintage","device":{"identifiers":["$MQTT_DEVICE_ID"],"name":"$MQTT_DEVICE_NAME"}}
JSON
    echo "  discovery: clips indexed"

    # Knop om de kijker opnieuw te laten indexeren.
    mqtt_pub_stdin "$MQTT_DISCOVERY_PREFIX/button/xpg006camera/reindex/config" <<JSON
{"name":"Car camera re-index viewer","unique_id":"xpg006camera_reindex","command_topic":"$MQTT_TOPIC_CMD","payload_press":"reindex","availability_topic":"$MQTT_TOPIC_AVAIL","payload_available":"online","payload_not_available":"offline","icon":"mdi:database-refresh","device":{"identifiers":["$MQTT_DEVICE_ID"],"name":"$MQTT_DEVICE_NAME"}}
JSON
    echo "  discovery: re-index button"

    echo "Home Assistant discovery published (retained)."
}

# ----------------------------------------------------------------------------
# 0. Validate the device and take a single-instance lock
# ----------------------------------------------------------------------------
if (( DISCOVERY_ONLY )); then
    publish_discovery
    exit 0
fi

if [[ -z "$DEV" ]]; then
    echo "usage: $0 /dev/sdX[1-9] [--once] | --discovery" >&2
    exit 2
fi

exec 9>"$LOCK_FILE" || { echo "cannot open lock file $LOCK_FILE" >&2; exit 1; }
if ! flock -n 9; then
    log "another copy is already running - ignoring $DEV"
    exit 0
fi

# XPG_ALLOW_FAKE_DEV=1 lets the test harness use a fake device node.
if [[ "${XPG_ALLOW_FAKE_DEV:-0}" == "1" ]]; then
    [[ -e "$DEV" ]] || die "$DEV does not exist"
else
    [[ -b "$DEV" ]] || die "$DEV is not a block device"
fi

publish_avail "online"
log "=== insertion detected: $DEV ==="
publish "idle" "detected $DEV"
publish_usb_state "on"

# ----------------------------------------------------------------------------
# 1. Wait for the NAS share (it may be asleep or switched off)
# ----------------------------------------------------------------------------
if (( ! ONCE )); then
    log "waiting up to ${NAS_WAIT_SECONDS}s for the share at $MOUNTPOINT ..."
    publish "waiting" "waiting for the NAS share"
    publish_avail "online"
    waited=0
    while (( waited < NAS_WAIT_SECONDS )); do
        mountpoint -q "$MOUNTPOINT" 2>/dev/null && break
        sleep 5; waited=$(( waited + 5 ))
    done
    if ! mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        log "share not mounted yet - attempting an explicit mount"
        mount "$MOUNTPOINT" 2>&1 | while read -r l; do log "  mount: $l"; done
    fi
    mountpoint -q "$MOUNTPOINT" 2>/dev/null \
        || die "NAS share unreachable after ${NAS_WAIT_SECONDS}s (is $NAS_IP awake?)"
fi

mountpoint -q "$MOUNTPOINT" 2>/dev/null || die "NAS share $MOUNTPOINT is not mounted"
log "share is mounted"

# ----------------------------------------------------------------------------
# 2. Locate the filesystem(s) on this device, mounting it ourselves if the
#    desktop/udisks layer has not already done so.
# ----------------------------------------------------------------------------
# Base device name, handling /dev/sda1, /dev/mmcblk0p1 and /dev/loop0p1 alike.
BASE=""
pkn="$(lsblk -no PKNAME "$DEV" 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$pkn" ]] && BASE="/dev/$pkn"
if [[ -z "$BASE" || ! -b "$BASE" ]]; then
    # Fallback: derive it from the name itself.
    if [[ "$DEV" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
        BASE="${BASH_REMATCH[1]}"          # /dev/sda1  -> /dev/sda
    elif [[ "$DEV" =~ ^(/dev/[a-z]+[0-9]+)p[0-9]+$ ]]; then
        BASE="${BASH_REMATCH[1]}"          # /dev/mmcblk0p1 -> /dev/mmcblk0
    else
        BASE="$DEV"
    fi
fi
log "device $DEV belongs to $BASE"

TMPDIR_RUN=""
OUR_MOUNTS=()
cleanup_mounts() {
    local m
    for m in "${OUR_MOUNTS[@]:-}"; do
        [[ -n "$m" ]] && umount "$m" 2>/dev/null
    done
}
trap 'cleanup_mounts; rm -rf "$TMPDIR_RUN" 2>/dev/null' EXIT

find_sources() {
    SOURCES=()
    local src tgt
    while read -r src tgt _; do
        [[ -z "$src" || -z "$tgt" ]] && continue
        # Never treat the OS or the NAS share itself as source material.
        # NOTE: our own self-mount point (/mnt/xpg-usb-*) must NOT be excluded.
        case "$tgt" in
            /|/boot|/boot/*|/mnt/nas|/mnt/nas/*) continue ;;
        esac
        if [[ "$src" == "$DEV" || "$src" == "$BASE"[0-9]* || "$src" == "$BASE"p[0-9]* ]]; then
            SOURCES+=("$tgt")
        fi
    done < <(findmnt -rn -o SOURCE,TARGET 2>/dev/null)
}

find_sources

if (( ${#SOURCES[@]} == 0 )); then
    # Not mounted yet - mount it ourselves so a plug-in always works, even
    # without a desktop session or udisks auto-mounting the card.
    log "$DEV is not mounted - mounting it now"
    MNTP="/mnt/xpg-usb-$(basename "$DEV")"
    mkdir -p "$MNTP"
    if mount -o ro "$DEV" "$MNTP" 2>&1 | while read -r l; do log "  mount: $l"; done; then
        OUR_MOUNTS+=("$MNTP")
        log "mounted read-only at $MNTP"
    elif mount "$DEV" "$MNTP" 2>&1 | while read -r l; do log "  mount: $l"; done; then
        OUR_MOUNTS+=("$MNTP")
        log "mounted at $MNTP"
    else
        log "could not mount $DEV (unsupported filesystem? try 'lsblk -f' and 'dmesg | tail')"
        die "nothing to copy from $DEV"
    fi
    find_sources
fi

if (( ${#SOURCES[@]} == 0 )); then
    log "no readable filesystem found for $DEV"
    die "nothing to copy from $DEV"
fi
log "source filesystem(s): ${SOURCES[*]:-}"

# ----------------------------------------------------------------------------
# 3. Optional extension filter
# ----------------------------------------------------------------------------
# No -D: there are no device nodes on a camera card, and FAT/exFAT cannot
# represent them; --partial keeps large clips resumable.
RSYNC_BASE=(-rt --no-perms --no-owner --no-group --no-specials --no-devices --partial)

# In "videos" mode the candidate list is filtered by extension instead of using
# rsync include/exclude rules, because --files-from overrides those rules and
# would happily copy every listed file.
EXT_REGEX=""
if [[ "$COPY_MODE" == "videos" ]]; then
    for ext in $VIDEO_EXT; do
        EXT_REGEX="${EXT_REGEX:+$EXT_REGEX|}\\.${ext}"
    done
fi

# ----------------------------------------------------------------------------
# 4. Work out what is new, using the archive contents as the reference set.
#    Computing this explicitly (rather than trusting --ignore-existing) makes
#    the behaviour identical on every rsync version.
# ----------------------------------------------------------------------------
TMPDIR_RUN="$(mktemp -d)" || die "cannot create temp dir"

ARCHIVED="$TMPDIR_RUN/archived"
: > "$ARCHIVED"
if [[ -d "$ARCHIVE_ROOT" ]]; then
    # Archive paths look like "<date>/<source>/<relative path>". Strip the date
    # folder so the result is comparable with what is on the card, and ignore
    # our own _logs directory.
    ( cd "$ARCHIVE_ROOT" && find . -type f -print0 2>/dev/null ) \
        | while IFS= read -r -d '' f; do
              rel="${f#./}"
              case "$rel" in _logs/*|_logs) continue ;; esac
              printf '%s\n' "${rel#*/}"
          done \
        | LC_ALL=C sort -u > "$ARCHIVED"
fi
log "archive already holds $(wc -l < "$ARCHIVED" | tr -d ' ') file(s)"

log "scanning the card for new material ..."
NEWLISTS=()          # parallel to SOURCES: path of the new-file list for each source
changed=0
idx=0
for SRC in "${SOURCES[@]}"; do
    CAND="$TMPDIR_RUN/cand.$idx"
    ( cd "$SRC" && find . -type f -print0 2>/dev/null ) \
        | while IFS= read -r -d '' f; do printf '%s\n' "${f#./}"; done \
        | LC_ALL=C sort -u > "$TMPDIR_RUN/oncard"
    # Archive entries carry the source folder name ("<date>/<basename>/..."),
    # so prepend the same basename here to compare like with like.
    srcname="$(basename "$SRC")"; [[ "$srcname" == "/" || -z "$srcname" ]] && srcname="root"
    sed "s|^|$srcname/|" "$TMPDIR_RUN/oncard" | LC_ALL=C sort -u > "$TMPDIR_RUN/oncard.norm"
    LC_ALL=C comm -23 "$TMPDIR_RUN/oncard.norm" "$ARCHIVED" > "$TMPDIR_RUN/cand.norm"
    if [[ -n "$EXT_REGEX" ]]; then
        grep -iE "$EXT_REGEX$" "$TMPDIR_RUN/cand.norm" > "$TMPDIR_RUN/cand.norm.f" || true
        mv "$TMPDIR_RUN/cand.norm.f" "$TMPDIR_RUN/cand.norm"
    fi
    sed "s|^$srcname/||" "$TMPDIR_RUN/cand.norm" > "$CAND"
    c="$(wc -l < "$CAND" | tr -d ' ')"
    NEWLISTS[$idx]="$CAND"
    changed=$(( changed + c ))
    log "  $SRC -> $c new file(s)"
    idx=$(( idx + 1 ))
done

if (( changed == 0 )); then
    log "nothing new - all footage from this card is already archived"
    set_led done
    publish_count 0
    publish "safe" "nothing new - already archived"
    sleep 2
    exit 0
fi
log "$changed new file(s) to transfer"

# ----------------------------------------------------------------------------
# 5. Copy into a dated folder for this plug-in
# ----------------------------------------------------------------------------
# mkdir without -p on purpose: -p succeeds when the folder already exists, so
# the fallback below would never run. Two runs inside the same second are
# possible - a re-plug, or the test - and they must not share a folder.
DEST="${ARCHIVE_ROOT}/$(stamp)"
# mkdir without -p on purpose: -p succeeds when the folder already exists, so a
# fallback guarded on its failure would never run. An if/else makes the outcome
# unambiguous; testing the filesystem afterwards reported success without having
# chosen the fallback.
if mkdir "$DEST" 2>/dev/null; then
    :
elif mkdir "${DEST}_$$" 2>/dev/null; then
    DEST="${DEST}_$$"
else
    die "cannot create destination folder under $ARCHIVE_ROOT"
fi
log "destination: $DEST"

set_led busy
publish "copying" "copying $changed new file(s) from $DEV"
total_files=0
total_bytes=0
failed=0

idx=0
for SRC in "${SOURCES[@]}"; do
    name="$(basename "$SRC")"; [[ "$name" == "/" || -z "$name" ]] && name="root"
    sub="$DEST/$name"
    mkdir -p "$sub"

    # --files-from with the new-file list: only genuinely new footage is sent.
    sed 's|^|/|' "${NEWLISTS[$idx]}" > "$TMPDIR_RUN/filesfrom"
    out="$(rsync "${RSYNC_BASE[@]}" --files-from="$TMPDIR_RUN/filesfrom" --stats \
            "$SRC/" "$sub/" 2>&1)"
    rc=$?
    log "copying $SRC/ -> $sub/"
    echo "$out" | while read -r l; do log "  rsync: $l"; done

    # 24 = "some files vanished" (normal on a dashcam card); anything else is real.
    if [[ $rc -ne 0 && $rc -ne 24 ]]; then
        log "rsync exited $rc for $SRC"
        failed=1
    fi

    # rsync prints e.g. "Total transferred file size: 250,008 B" - keep digits.
    s="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {print $2}' | tr -dc '0-9')"
    [[ -z "$s" ]] && s="$(echo "$out" | awk -F': ' '/Number of files transferred/ {print $2}' | tr -dc '0-9')"
    b="$(echo "$out" | awk -F': ' '/Total transferred file size/ {print $2}' | tr -dc '0-9')"
    total_files=$(( total_files + ${s:-0} ))
    total_bytes=$(( total_bytes + ${b:-0} ))
    idx=$(( idx + 1 ))
done

# ----------------------------------------------------------------------------
# 6. Report and tidy up
# ----------------------------------------------------------------------------
human="$(numfmt --to=iec "${total_bytes:-0}" 2>/dev/null)"
[[ -z "$human" ]] && human="${total_bytes:-0} bytes"
log "done: ${total_files} file(s), ${human} transferred"

# If we reserved a folder but nothing landed, remove it again.
copied="$(find "$DEST" -type f 2>/dev/null | wc -l | tr -d ' ')"
if (( copied == 0 )); then
    find "$DEST" -mindepth 1 -type d -delete 2>/dev/null
    rmdir "$DEST" 2>/dev/null && log "no files copied - removed empty folder $DEST"
else
    log "archive folder now holds $copied file(s)"
fi

sync

if (( failed )); then
    log "=== finished with errors ==="
    set_led error
    exit 1
fi

log "=== finished OK ==="
publish_last_copy
publish_count "${total_files:-0}"
publish "safe" "copy finished: ${total_files} file(s), ${human}"
set_led done
sleep 2
exit 0

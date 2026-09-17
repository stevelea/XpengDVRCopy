#!/bin/bash
# install.sh - set up the Pi Zero W to archive car-camera footage to the NAS.
#
# Run ON THE PI as root:
#     sudo bash install.sh
#
# Optional environment overrides:
#     NAS_IP=192.0.2.10 NAS_SHARE=Shared_Drive NAS_USER=youruser NAS_PASS=secret \
#         bash install.sh
#   (without NAS_PASS you are prompted, so the password never lands in shell history)
set -euo pipefail

NAS_IP="${NAS_IP:-}"
NAS_SHARE="${NAS_SHARE:-Shared_Drive}"
NAS_USER="${NAS_USER:-}"
DEST_SUBDIR="${DEST_SUBDIR:-xpg006camera}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/nas/xpg006camera}"
CRED_FILE="/etc/samba/creds-xpg006camera"
COPY_SCRIPT="/usr/local/bin/copyusb.sh"
CONF_FILE="/etc/xpg-camera-copy.conf"
SERVICE="xpg-camera-copy@.service"
FSTAB_TAG="# xpg006camera NAS archive"

[[ $EUID -eq 0 ]] || { echo "run me as root: sudo bash $0" >&2; exit 1; }

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Installing required packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends cifs-utils rsync ca-certificates mosquitto-clients

# Collect the share details if they were not supplied in the environment.
if [[ -t 0 ]]; then
    [[ -z "$NAS_IP" ]]    && { read -r -p "NAS/share host IP or name: " NAS_IP || true; }
    [[ -z "$NAS_SHARE" ]] && { read -r -p "Share name: " NAS_SHARE || true; }
    [[ -z "$NAS_USER" ]]  && { read -r -p "SMB username: " NAS_USER || true; }
fi
[[ -n "$NAS_IP"    ]] || { echo "NAS_IP is required (e.g. NAS_IP=192.0.2.10 sudo -E bash $0)" >&2; exit 1; }
[[ -n "$NAS_SHARE" ]] || { echo "NAS_SHARE is required (e.g. NAS_SHARE=Shared_Drive)" >&2; exit 1; }
[[ -n "$NAS_USER"  ]] || { echo "NAS_USER is required (e.g. NAS_USER=youruser)" >&2; exit 1; }

say "Storing NAS credentials in $CRED_FILE"
install -d -m 700 /etc/samba
if [[ -z "${NAS_PASS:-}" ]]; then
    read -r -s -p "Password for SMB user '$NAS_USER' on $NAS_IP: " NAS_PASS || true
    echo
fi
[[ -n "$NAS_PASS" ]] || { echo "no password supplied" >&2; exit 1; }
umask 077
printf 'username=%s\npassword=%s\n' "$NAS_USER" "$NAS_PASS" > "$CRED_FILE"
chmod 600 "$CRED_FILE"
chown root:root "$CRED_FILE"

# MQTT settings for Home Assistant status reporting (optional).
if [[ -z "${MQTT_HOST:-}" && -t 0 ]]; then
    read -r -p "MQTT broker host for Home Assistant status (blank to skip): " MQTT_HOST || true
fi
if [[ -n "${MQTT_HOST:-}" ]]; then
    MQTT_USER="${MQTT_USER:-}"
    MQTT_PREFIX="${MQTT_PREFIX:-xpg006camera}"
    if [[ -z "${MQTT_PASS:-}" && -t 0 ]]; then
        read -r -s -p "MQTT password for user '${MQTT_USER:-<none>}': " MQTT_PASS || true
        echo
    fi
fi

say "Configuring the persistent mount point"
install -d -m 755 "$MOUNTPOINT"

# Keep the fstab entry idempotent: drop any previous one, then re-add.
if grep -qF "$FSTAB_TAG" /etc/fstab 2>/dev/null; then
    cp -a /etc/fstab "/etc/fstab.xpg.bak.$(date +%s)"
    grep -vF "$FSTAB_TAG" /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
fi
cp -a /etc/fstab "/etc/fstab.xpg.bak.$(date +%s)"
{
    printf '%s\n' "$FSTAB_TAG"
    printf '//%s/%s %s cifs credentials=%s,uid=0,gid=0,iocharset=utf8,vers=3.0,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=120,file_mode=0664,dir_mode=0775 0 0\n' \
        "$NAS_IP" "$NAS_SHARE" "$MOUNTPOINT" "$CRED_FILE"
} >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$MOUNTPOINT" || { mount "$MOUNTPOINT" || true; }
if mountpoint -q "$MOUNTPOINT"; then
    echo "    share mounted at $MOUNTPOINT"
else
    echo "    WARNING: could not mount yet - it will retry automatically (nofail/automount)." >&2
    echo "    Check with: sudo mount -v $MOUNTPOINT" >&2
fi

say "Installing the copy script"
install -m 755 "$(dirname "$0")/copyusb.sh" "$COPY_SCRIPT"

# Helper used by the systemd unit to mark the MQTT entities offline; it reads
# the broker settings from the config file instead of hardcoding them.
cat > /usr/local/bin/xpg-mqtt-avail <<'AVAIL'
#!/bin/bash
# Publish an availability state for the camera archiver. Usage: xpg-mqtt-avail online|offline
CONF="/etc/xpg-camera-copy.conf"
[[ -r "$CONF" ]] && . "$CONF"
[[ "${MQTT_ENABLED:-1}" == "1" ]] || exit 0
command -v mosquitto_pub >/dev/null 2>&1 || exit 0
exec timeout "${MQTT_TIMEOUT:-10}" mosquitto_pub \
    -h "${MQTT_HOST:-127.0.0.1}" -p "${MQTT_PORT:-1883}" \
    -u "${MQTT_USER:-}" -P "${MQTT_PASS:-}" -q 1 -r \
    -t "${MQTT_PREFIX:-xpg006camera}/availability" -m "${1:-offline}"
AVAIL
chmod 755 /usr/local/bin/xpg-mqtt-avail

# Create the config on first install, and add any newly introduced settings to
# an existing file without touching what you have already customised.
CONF_DEFAULTS=(
    'COPY_MODE="all"'
    'VIDEO_EXT="mp4 mov avi mkv ts m4v 3gp lrv insv"'
    'NAS_WAIT_SECONDS="300"'
    "MOUNTPOINT=\"$MOUNTPOINT\""
    "DEST_SUBDIR=\"$DEST_SUBDIR\""
    'MQTT_ENABLED="1"'
    'MQTT_HOST=""'
    'MQTT_PORT="1883"'
    'MQTT_USER=""'
    'MQTT_PREFIX="xpg006camera"'
)

if [[ ! -f "$CONF_FILE" ]]; then
    {
        echo "# Settings for /usr/local/bin/copyusb.sh"
        echo "# COPY_MODE=\"all\" copies everything; \"videos\" restricts to VIDEO_EXT below."
        printf '%s\n' "${CONF_DEFAULTS[@]}"
    } > "$CONF_FILE"
    chmod 644 "$CONF_FILE"
    echo "    wrote $CONF_FILE"
else
    added=0
    for line in "${CONF_DEFAULTS[@]}"; do
        key="${line%%=*}"
        if ! grep -qE "^[[:space:]]*${key}=" "$CONF_FILE"; then
            printf '%s\n' "$line" >> "$CONF_FILE"
            added=$(( added + 1 ))
        fi
    done
    echo "    kept existing $CONF_FILE (added $added new setting(s))"
fi

say "Installing the plug-in detection service"
cat > "/etc/systemd/system/$SERVICE" <<'UNIT'
[Unit]
Description=Archive car-camera USB ($1) to the NAS share
After=network-online.target remote-fs.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
# Wait for a DHCP address before trying to reach the NAS.
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do ip route | grep -q "^default" && exit 0; sleep 2; done; exit 0'
ExecStart=/usr/local/bin/copyusb.sh /dev/%I
# Mark the MQTT entities unavailable once no copy is running.
ExecStopPost=-/usr/local/bin/xpg-mqtt-avail offline
TimeoutStartSec=infinity
Nice=10
IOSchedulingClass=idle
StandardOutput=journal
StandardError=journal
UNIT
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true

say "Installing the udev rule (any USB mass-storage partition)"
cat > /etc/udev/rules.d/99-xpg-camera.rules <<'RULE'
# When a USB storage partition appears, archive it to the NAS.
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{ID_BUS}=="usb", TAG+="systemd", ENV{SYSTEMD_WANTS}+="xpg-camera-copy@%k.service"
ACTION=="add", SUBSYSTEM=="block", KERNEL=="mmcblk[0-9]p[0-9]", ENV{ID_BUS}=="usb", TAG+="systemd", ENV{SYSTEMD_WANTS}+="xpg-camera-copy@%k.service"
RULE
udevadm control --reload-rules
udevadm trigger --subsystem-match=block --action=add || true

say "Enabling the automount for the share"
systemctl restart "$(systemd-escape -p --suffix=automount "$MOUNTPOINT")" 2>/dev/null || true

say "Publishing Home Assistant MQTT discovery"
"$COPY_SCRIPT" --discovery || echo "  (discovery failed - rerun later with: sudo $COPY_SCRIPT --discovery)" >&2

say "Installation complete"
cat <<EOF

  Share        : //$NAS_IP/$NAS_SHARE  ->  $MOUNTPOINT
  Archive      : $MOUNTPOINT/$DEST_SUBDIR/<date>/
  Copy script  : $COPY_SCRIPT
  Config       : $CONF_FILE
  Trigger      : plug the car USB into the OTG port (any USB storage works)

  Watch it happen:
      sudo journalctl -fu "$SERVICE"
      tail -f $MOUNTPOINT/$DEST_SUBDIR/_logs/copy.log

  Test it right now without unplugging anything:
      sudo $COPY_SCRIPT /dev/sdX1 --once

  LED: solid = copying, slow blink = done, fast blink = failed.

EOF

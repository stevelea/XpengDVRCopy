# XpengDVRCopy

**Archive your car's dashcam/DVR USB stick to a NAS automatically, and get a
Home Assistant status that tells you when it is safe to pull the stick out.**

Plug the car's USB drive into a Raspberry Pi. The Pi copies everything to a
network share, folder structure intact, skipping anything it has already
archived. A status is published over MQTT so Home Assistant (or an LED) can tell
you the moment it is safe to remove the drive.

Built and tested on a **Raspberry Pi Zero W** running Raspberry Pi OS
(Debian 12 bookworm), archiving to a **UniFi UNAS** over SMB/CIFS.

```
 ┌──────────────┐   SMB/CIFS    ┌──────────────┐   USB OTG   ┌──────────────┐
 │  NAS share   │◀──────────────│  Raspberry   │◀────────────│  Car DVR USB │
 │ 192.168.x.x  │  (read-only   │   Pi Zero W  │   (or any   │    stick     │
 └──────────────┘   archive)    └──────┬───────┘    Pi)      └──────────────┘
                                       │ MQTT
                                       ▼
                                ┌──────────────┐
                                │Home Assistant│
                                │  "safe"      │
                                └──────────────┘
```

## Features

- **Fully automatic** — plug the drive in, nothing else to do. A udev rule
  detects any USB mass-storage device and starts a systemd service.
- **Idempotent** — footage already archived is never copied again, so
  re-plugging the same card is a no-op rather than a duplicate archive.
- **Never touches your card** — the drive is mounted **read-only**. Files are
  copied, never moved or deleted.
- **Survives reboots, NAS outages and early plug-in** — the share is mounted via
  `/etc/fstab` with `nofail` and automount, and the copy waits for the NAS to
  become reachable (default 5 minutes).
- **Home Assistant auto-discovery** — status, safe-to-remove and last-copy
  entities appear with no YAML.
- **LED feedback** — solid while copying, slow blink when safe, fast blink on
  error.
- **A permanent log** on the share (`_logs/copy.log`) plus the systemd journal.
- **Handles exFAT, FAT32 and NTFS** cards.

## The files in `deploy/`

`install.sh` is the way to install this — it writes every file below into place
and prompts for the things that are machine-specific. The `deploy/` directory
holds the files themselves, so you can read what will be installed before
running it, or install by hand:

| File | Goes to | Purpose |
|---|---|---|
| `deploy/copyusb.sh` | `/usr/local/bin/` | the copy itself |
| `deploy/xpg-usb-state` | `/usr/local/bin/` | publishes "card removed" — nothing runs on a pull, so udev calls this |
| `deploy/xpg-mqtt-avail` | `/usr/local/bin/` | marks the Home Assistant entities unavailable |
| `deploy/xpg-camera-copy@.service` | `/etc/systemd/system/` | runs the script for one device |
| `deploy/99-xpg-camera.rules` | `/etc/udev/rules.d/` | detects the plug-in and the removal |

`deploy/README.md` covers installing by hand: the package list, the `/etc/fstab`
entry, why the mount uses `nofail`, and the design notes.

These files were recovered from a running installation, so they are the versions
actually in use rather than a remembered approximation. The broker password is
blank in both `deploy/copyusb.sh` and `xpg-camera-copy.conf.example`; it goes in
`/etc/xpg-camera-copy.conf` on the machine.

## How it works

1. **udev** sees a USB block device appear and starts
   `xpg-camera-copy@<device>.service`.
2. The **systemd unit** waits for a default route, runs the copy, and marks the
   MQTT entities offline when it exits.
3. **`copyusb.sh`** mounts the card if nothing else has (read-only), waits for
   the NAS share, works out which files are genuinely new, and `rsync`s them
   into `…/xpg006camera/<date>/<filesystem>/`.
4. **MQTT** publishes `idle → waiting → copying → safe` (or `error`).

### Why the dedupe is done by hand

Each plug-in gets its own date folder, which means `rsync --ignore-existing`
would compare against an *empty* new folder and cheerfully re-copy everything.
So the script first builds the list of relative paths already present anywhere in
the archive, subtracts the card's file list from it, and feeds the difference to
`rsync --files-from`. That behaviour is explicit and identical on every rsync
version.

## Install

On a fresh Raspberry Pi OS install:

```bash
git clone https://github.com/stevelea/XpengDVRCopy.git
cd XpengDVRCopy
sudo bash install.sh
```

You will be prompted for:

| Prompt | Notes |
| --- | --- |
| NAS/SMB username | The account that can write to the share |
| SMB password | Stored in `/etc/samba/creds-<name>`, `chmod 600`, root-only |
| MQTT broker host | Optional — leave blank to skip Home Assistant reporting |
| MQTT username / password | Optional |

Or supply everything non-interactively:

```bash
sudo NAS_IP=192.0.2.10 NAS_SHARE=Shared_Drive NAS_USER=youruser NAS_PASS='secret' \
     MQTT_HOST=198.51.100.5 MQTT_USER=mqtt MQTT_PASS='secret' \
     bash install.sh
```

Overridable variables: `NAS_IP`, `NAS_SHARE`, `NAS_USER`, `NAS_PASS`,
`DEST_SUBDIR`, `MOUNTPOINT`, `MQTT_HOST`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASS`,
`MQTT_PREFIX`.

`install.sh` is **idempotent** — re-running it replaces the fstab entry, service
and udev rule rather than duplicating them, backs up `/etc/fstab` first, and
merges new settings into `/etc/xpg-camera-copy.conf` without clobbering your
edits.

## Usage

Plug the drive into the Pi's **USB OTG data port**. That's it.

| Signal | Meaning |
| --- | --- |
| HA sensor `safe` | Copy finished — remove the stick |
| LED solid on | Copying |
| LED slow blink (½s) | Safe to remove |
| LED fast blink | Error — check the log |

Status flow:

```
idle  ->  waiting  ->  copying  ->  safe
                                \->  error
```

Because the card is mounted read-only, removing it can never corrupt it — `safe`
means "the copy has finished", not "a write is in flight".

### Files on the share

```
<mount>/xpg006camera/
├── 2026-09-17_120920/
│   └── sda1/                          <- the card's filesystem label
│       └── DCIM/Movie/2026_09_17_…MP4 <- original layout preserved
├── 2026-09-17_153301/
│   └── sda1/DCIM/Movie/2026_09_17_…MP4
└── _logs/copy.log
```

Only plug-ins that actually contain new material create a folder.

## Home Assistant

Three entities are published via MQTT discovery and appear automatically:

| Entity | Topic | Values |
| --- | --- | --- |
| Car camera copy status | `xpg006camera/status` | `idle` `waiting` `copying` `safe` `error` |
| Car camera safe to remove | `xpg006camera/status` | on when `safe` |
| Car camera last copy | `xpg006camera/last_copy` | timestamp |

Plus `xpg006camera/detail` (human-readable detail) and
`xpg006camera/availability` (`online`/`offline`). **All messages are retained**,
so Home Assistant shows the correct state after a restart.

To (re)publish discovery:

```bash
sudo /usr/local/bin/copyusb.sh --discovery
```

Example notification automation:

```yaml
alias: Camera card is safe to remove
triggers:
  - trigger: state
    entity_id: sensor.car_camera_copy_status
    to: "safe"
actions:
  - action: notify.mobile_app_your_phone
    data:
      message: "Dashcam footage copied — safe to remove the USB stick."
```

Set `MQTT_ENABLED="0"` in `/etc/xpg-camera-copy.conf` to turn reporting off.

## Configuration

Settings live in `/etc/xpg-camera-copy.conf` (see
[`xpg-camera-copy.conf.example`](xpg-camera-copy.conf.example)). Common changes:

```ini
# Archive only video files instead of everything on the card
COPY_MODE="videos"
VIDEO_EXT="mp4 mov avi mkv ts m4v 3gp lrv insv"

# Give a slow NAS longer to wake up
NAS_WAIT_SECONDS="600"

# Turn MQTT reporting off
MQTT_ENABLED="0"
```

## Testing

`test/dedupe-test.sh` runs the copy logic against a mock environment (fake
device, mocked `mountpoint`/`findmnt`) and asserts the three behaviours that
matter most:

1. a first plug copies everything,
2. re-plugging the same card **creates no folder and copies nothing**,
3. adding one new clip copies exactly that clip.

```bash
bash test/dedupe-test.sh
```

No root, no NAS and no real USB drive required.

## Troubleshooting

**Nothing happens when I plug the drive in**

```bash
lsblk              # does the drive appear (e.g. sda1)?
udevadm monitor    # plug it in again and watch for the block event
```

**The share won't mount**

```bash
sudo mount -v /mnt/nas/xpg006camera
sudo dmesg | grep -i cifs | tail -5
```

`STATUS_LOGON_FAILURE` means the password in the credentials file is wrong.

**No status in Home Assistant**

```bash
mosquitto_sub -h <broker> -u <user> -P '<pass>' -t 'xpg006camera/status' -v
```

Note that MQTT brokers with per-topic ACLs may deny **wildcard**
subscriptions — reading the exact topic above still works.

**Watch a copy live**

```bash
sudo journalctl -fu 'xpg-camera-copy@*'
tail -f /mnt/nas/xpg006camera/xpg006camera/_logs/copy.log
```

**Run a copy by hand**

```bash
sudo /usr/local/bin/copyusb.sh /dev/sdX1 --once
```

**Disable everything**

```bash
sudo systemctl disable --now xpg-camera-copy@.service
sudo rm /etc/udev/rules.d/99-xpg-camera.rules
sudo udevadm control --reload-rules
```

## Uninstall

```bash
sudo systemctl disable --now xpg-camera-copy@.service
sudo rm -f /etc/systemd/system/xpg-camera-copy@.service \
           /etc/udev/rules.d/99-xpg-camera.rules \
           /usr/local/bin/copyusb.sh \
           /usr/local/bin/xpg-mqtt-avail \
           /etc/xpg-camera-copy.conf \
           /etc/samba/creds-xpg006camera
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
# then remove the "# xpg006camera NAS archive" block from /etc/fstab
```

## Requirements

- Raspberry Pi (any model with a USB host/OTG port) running Raspberry Pi OS
  bookworm or similar
- `cifs-utils`, `rsync` and (optionally) `mosquitto-clients` — installed
  automatically by `install.sh`
- An SMB/CIFS share with write access
- Optional: an MQTT broker and Home Assistant

## License

MIT — see [LICENSE](LICENSE).

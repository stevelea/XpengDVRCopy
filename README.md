# XpengDVRCopy

**Archive your car's dashcam/DVR USB stick to a NAS automatically, and get a
Home Assistant status that tells you when it is safe to pull the stick out.**

Plug the car's USB drive into a small always-on board. It copies everything to a
network share, folder structure intact, skipping anything it has already
archived. A status is published over MQTT so Home Assistant (or an LED) can tell
you the moment it is safe to remove the drive.

Running on an **Orange Pi 3 LTS** (Armbian, kernel 6.18) archiving to a **UniFi
UNAS** over SMB/CIFS. See [Hardware](#hardware) for what matters when picking a
board - it is the network path, not the CPU.

```
 ┌──────────────┐   SMB/CIFS    ┌──────────────┐     USB      ┌──────────────┐
 │  NAS share   │◀──────────────│  Orange Pi   │◀────────────│  Car DVR USB │
 │ 192.168.x.x  │  (read-only   │    3 LTS     │    (any      │    stick     │
 └──────────────┘   archive)    └──────┬───────┘    board)    └──────────────┘
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
| `deploy/xpg-mqtt-avail` | `/usr/local/bin/` | publishes one availability message |
| `deploy/xpg-mqtt-availd` | `/usr/local/bin/` | holds the entities online while the board is up |
| `deploy/xpg-camera-copy@.service` | `/etc/systemd/system/` | runs the script for one device |
| `deploy/xpg-mqtt-avail.service` | `/etc/systemd/system/` | keeps that availability process running |
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
2. The **systemd unit** waits for a default route, runs the copy, and exits.
   It deliberately does *not* touch the MQTT availability topic — see below.
3. **`copyusb.sh`** mounts the card if nothing else has (read-only), waits for
   the NAS share, works out which files are genuinely new, and `rsync`s them
   into `…/xpg006camera/<date>/<filesystem>/`.
4. **MQTT** publishes `idle → waiting → copying → safe` (or `error`).

### Why availability is its own service

The copy service is a **oneshot**: it starts when a card appears and stops the
moment the copy ends. Marking the entities offline from its `ExecStopPost`
therefore looked reasonable and was actively wrong — the service stops at the
same instant it publishes `safe`, so Home Assistant replaced "safe" with
"unavailable" and there was no way to tell that the copy had finished.

So `xpg-mqtt-avail.service` holds the availability topic instead. It stays
connected for as long as the board is up, and it covers both ways the board can
go away:

- a **clean stop** (shutdown, reboot, `systemctl stop`) is announced by
  `ExecStopPost`;
- a **crash or power cut** cannot announce anything, so the process registers an
  MQTT **last will** with the broker, which publishes `offline` on its behalf.

It also republishes `online` every five minutes, which costs one tiny message and
repairs a retained `offline` that arrives late.

### Why the dedupe is done by hand

Each plug-in gets its own date folder, which means `rsync --ignore-existing`
would compare against an *empty* new folder and cheerfully re-copy everything.
So the script first builds the list of relative paths already present anywhere in
the archive, subtracts the card's file list from it, and feeds the difference to
`rsync --files-from`. That behaviour is explicit and identical on every rsync
version.

## Install

On a fresh Debian, Armbian or Raspberry Pi OS install:

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

Plug the drive into the board's **USB port** - on a Zero-class board
that means the OTG data port, not the power-only one. That's it.

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

The entities only go `unavailable` when the board itself is gone — not when a
copy finishes. If you ever see them unavailable while the board is up, check
`systemctl status xpg-mqtt-avail`.

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

## Hardware

This runs on any small always-on Linux board with a USB host port.

The copy logic is board-agnostic: the udev rule matches any USB storage device,
the service waits for a default route rather than for a particular network
manager, and the device name is derived from the kernel (`/dev/sda1` and
`/dev/mmcblk0p1` are both handled).

What differs between boards is the **LED**, and the name it reports to Home
Assistant. Both are settings:

```ini
LED_NAME="green:red"                # or "ACT", or "none"
MQTT_DEVICE_NAME="Camera archiver"
MQTT_DEVICE_ID="xpg006camera_archiver"
MQTT_DEVICE_MODEL="USB card archiver"
```

`LED_NAME` empty means "take the first LED that can be driven"; `"none"` means
no LED at all. **A board with no controllable LED is fine** — the copy is
unaffected, and the MQTT status is the indication instead. Deriving a name from
the error is not fun, so the auto-detect also knows the Orange Pi names
(`orangepi:red:status`, `orangepi:green:power`) and skips keyboard LEDs, which is
what it otherwise picks on an Orange Pi. On the Orange Pi 3 LTS it resolves to
`/sys/class/leds/orangepi:red:status`. Check what a board offers with:

```bash
for d in /sys/class/leds/*; do echo "$d  writable=$([ -w $d/trigger ] && echo yes)"; done
```

If you run more than one of these boards, give each its own `MQTT_PREFIX` or
`MQTT_DEVICE_ID`, otherwise their Home Assistant entities collide.

### Why it is worth using a faster board

The bottleneck is the **network path, not the CPU**, and it is not a small
effect. Measured on the same NAS and share:

| Board | Large file | Small files | A 164 GB card, copied for real |
| --- | --- | --- | --- |
| Raspberry Pi Zero W, 100 Mb Wi-Fi | ~1 MB/s | ~1 MB/s | days |
| Orange Pi 3 LTS, gigabit wired | 57-58 MB/s | 10.6 MB/s | ~2 hours |

The two transfer figures are synthetic: one big file, then many small ones. A
real card sits between them at about **20 MB/s** — dashcam sticks are tens of
thousands of small clips, so each file costs a round-trip that the CPU does not
matter for. **Wired gigabit Ethernet is the single biggest win**, and it is worth
running a cable for. A Zero-class board still works, it just means leaving the
stick in overnight.

Home Assistant shows a `copying` status with a running file and byte count, so
if you are unsure how long is left, look there rather than at the LED.

### Android will not work

Android is a Linux kernel with none of the surrounding machinery: no udev, no
systemd, no `/etc/fstab`, and a read-only `/system`. `mount.cifs`, `rsync` and
`mosquitto-clients` are not available either. A board sold running Android needs
a real distribution before this can be installed on it.

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

Two suites, neither needing root, a NAS or a real card.

`test/dedupe-test.sh` runs the copy logic against a mock environment (fake
device, mocked `mountpoint`/`findmnt`) and asserts the three behaviours that
matter most:

1. a first plug copies everything,
2. re-plugging the same card **creates no folder and copies nothing**,
3. adding one new clip copies exactly that clip.

```bash
bash test/dedupe-test.sh
bash test/mqtt-avail-test.sh
```

`test/mqtt-avail-test.sh` guards the availability rules with a fake broker
client: that the copy service never marks the entities offline, that the
availability service does announce a clean stop, that it registers a last will
for a crash, and that `RemainAfterExit` has not crept back onto the copy unit.
Both suites stub out `timeout(1)`, so they run on macOS as well as on the
board.

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
sudo systemctl disable --now xpg-camera-copy@.service xpg-mqtt-avail.service
sudo rm /etc/udev/rules.d/99-xpg-camera.rules
sudo udevadm control --reload-rules
```

## Uninstall

```bash
sudo systemctl disable --now xpg-camera-copy@.service xpg-mqtt-avail.service
sudo rm -f /etc/systemd/system/xpg-camera-copy@.service \
           /etc/systemd/system/xpg-mqtt-avail.service \
           /etc/udev/rules.d/99-xpg-camera.rules \
           /usr/local/bin/copyusb.sh \
           /usr/local/bin/xpg-mqtt-avail \
           /usr/local/bin/xpg-mqtt-availd \
           /etc/xpg-camera-copy.conf \
           /etc/samba/creds-xpg006camera
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
# then remove the "# xpg006camera NAS archive" block from /etc/fstab
```

## Requirements

- An always-on Linux board with a USB host port — validated on an Orange Pi
  3 LTS (Armbian, kernel 6.18, aarch64) and a Raspberry Pi Zero W (Raspberry Pi
  OS bookworm); Debian/Ubuntu on x86 works too
- systemd and udev, which is what does the plug-in detection
- `cifs-utils`, `rsync` and (optionally) `mosquitto-clients` — installed
  automatically by `install.sh`
- An SMB/CIFS share with write access
- Optional: an MQTT broker and Home Assistant

## License

MIT — see [LICENSE](LICENSE).

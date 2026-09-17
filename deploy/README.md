# The archiver — copying cards to the share

Runs on the Raspberry Pi the car's USB stick is plugged into. It has no user
interface: a udev rule notices a new USB storage partition and starts a systemd
service, which runs one shell script. The script copies the card to the share and
reports over MQTT, then exits.

Everything here was recovered from a working installation (`2026-09-17`), so it
is the code that is actually running rather than a remembered version.

## The files

| File | Installs to | Purpose |
|---|---|---|
| `copyusb.sh` | `/usr/local/bin/copyusb.sh` | the copy itself |
| `xpg-usb-state` | `/usr/local/bin/xpg-usb-state` | publishes "card removed" |
| `xpg-mqtt-avail` | `/usr/local/bin/xpg-mqtt-avail` | marks the HA entities offline |
| `xpg-camera-copy@.service` | `/etc/systemd/system/` | runs the script for one device |
| `99-xpg-camera.rules` | `/etc/udev/rules.d/` | detects the plug-in and the removal |
| `xpg-camera-copy.conf.example` | `/etc/xpg-camera-copy.conf` | settings |

`xpg-camera-copy.conf.example` has an empty `MQTT_PASS`. Fill it in on the
machine; it is not in this repository on purpose.

## Why two helpers exist

`copyusb.sh` announces "the card is connected" when it starts. It cannot announce
the opposite, because nothing runs when a card is pulled — so `xpg-usb-state` is
called by the udev `remove` rule instead.

`xpg-mqtt-avail` is called from the unit's `ExecStopPost`, so the Home Assistant
entities go unavailable when no copy is running rather than showing a stale
state.

## Packages

As installed on this Pi, from `dpkg-query`:

```
cifs-utils          mounting the share
rsync               the copy
mosquitto-clients   mosquitto_pub, for the MQTT reporting
python3             not used by the archiver; present on the image
exfatprogs          so exFAT cards mount
```

## Install

```bash
sudo apt-get install -y cifs-utils rsync mosquitto-clients exfatprogs

sudo install -m 755 deploy/pi/copyusb.sh      /usr/local/bin/copyusb.sh
sudo install -m 755 deploy/pi/xpg-usb-state   /usr/local/bin/xpg-usb-state
sudo install -m 755 deploy/pi/xpg-mqtt-avail  /usr/local/bin/xpg-mqtt-avail
sudo install -m 644 deploy/pi/xpg-camera-copy@.service /etc/systemd/system/
sudo install -m 644 deploy/pi/99-xpg-camera.rules      /etc/udev/rules.d/

sudo install -m 644 deploy/pi/xpg-camera-copy.conf.example /etc/xpg-camera-copy.conf
sudoedit /etc/xpg-camera-copy.conf     # set MQTT_HOST, MQTT_USER, MQTT_PASS

sudo systemctl daemon-reload
sudo udevadm control --reload-rules
```

Then the share, in `/etc/fstab`, with the password in its own file:

```bash
sudo install -d -m 700 /etc/samba
printf 'username=%s\npassword=%s\n' YOURUSER 'YOURPASS' | sudo tee /etc/samba/creds-xpg006camera >/dev/null
sudo chmod 600 /etc/samba/creds-xpg006camera
```

```
//192.168.1.235/Shared_Drive /mnt/nas/xpg006camera cifs credentials=/etc/samba/creds-xpg006camera,uid=0,gid=0,iocharset=utf8,vers=3.0,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=120,file_mode=0664,dir_mode=0775 0 0
```

`nofail` matters: without it the Pi will not finish booting when the NAS is
switched off.

## Test it

The test needs no root, no NAS and no card — it mocks all three:

```bash
bash test/dedupe-test.sh
```

It asserts the three behaviours that matter, and it is the reason the duplicate
copy bug was caught rather than shipped:

1. a first plug-in copies everything
2. re-plugging an identical card copies **nothing** and creates no folder
3. adding one clip transfers exactly that one clip

Point 2 is the one worth understanding. Each plug-in gets its own dated folder,
so `rsync --ignore-existing` would compare against an empty new folder and copy
everything again. The script instead builds the set of relative paths already in
the archive, subtracts the card's file list from it, and hands the difference to
`rsync --files-from`.

## Design notes

- **The card is mounted read-only.** Nothing is written to it, ever.
- **Nothing is deleted.** Files are copied, and the card is left alone. That
  is why removing the card can never corrupt it, and why `safe` means "the copy
  finished" rather than "a write is in flight".
- **A failed transfer cannot silently leave a short file.** rsync without
  `--inplace` writes to a temporary name and renames on completion, and
  `--partial` keeps the incomplete data for resuming. A half-copied file
  therefore never sits under its final name, so the dedupe cannot mistake it for
  a finished one.
- **Startup is safe to repeat.** The service waits for a default route first, so
  it does not race DHCP.

## Gotcha found on this install

`/etc/fstab` ended up with the share **twice** — once with the `# xpg006camera
NAS archive` tag the installer writes and once without, from an earlier attempt.
It is harmless (the kernel mounts the share once and the second entry is
ignored) but it is confusing when you go looking. Check with:

```bash
grep -c xpg006camera /etc/fstab    # expect 2: one comment, one entry
```

## Known limits

- **Slow, because the hardware is.** A Pi Zero W is a single-core ARMv6 with
  427 MB of RAM doing USB reads, SMB framing and rsync on one core. Around
  1 MB/s is what it does. A 35 GB card takes days, not hours.
- **The dedupe scan is not the bottleneck.** On a 11,470-file card it took
  109 seconds against many hours of copying.
- **A card written on a Mac brings junk** — `._*` AppleDouble files and
  `.fseventsd` — and each small file costs a full SMB round-trip. Excluding them
  would speed up a first copy, at the cost of not archiving everything.

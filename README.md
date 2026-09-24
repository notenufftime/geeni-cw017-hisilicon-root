# Geeni / Merkury CW017 "Mini 11S" — firmware 2.10.6 on HiSilicon

**Community documentation of an undocumented hardware/firmware variant.**

This device is a **Geeni CW017 (model string "Mini 11S")** running firmware
**2.10.6** on a **HiSilicon `hi_sfc`** platform. It is **not covered by any
existing public project**:

| Project | Covers | Why it doesn't fit |
|---|---|---|
| [guino/Merkury720](https://github.com/guino/Merkury720) | 720p, fw 2.7.x | different bootloader, lacks `run` |
| [guino/Merkury1080P](https://github.com/guino/Merkury1080P) | CW017, fw **4.0.x** | fw 4.0.x only; different load address |
| [guino/BazzDoorbell](https://github.com/guino/BazzDoorbell) | doorbells | different device |
| [guino/Geeni720P](https://github.com/guino/Geeni720P) | Geeni, **`hi_sfc`** | **closest match** — same flash driver |

**Key discovery: on `hi_sfc` hardware the standard SD boot-hack cannot work,
because the bootloader lacks the `run` command.** See [Root cause](#-root-cause-the-bootloader-lacks-run).

---

## Device identification

```json
{"devname":"Smart Home Camera","model":"Mini 11S","serialno":"060569885",
 "softwareversion":"2.10.6","hardwareversion":"M11S_H1_V10_F23",
 "firmwareversion":"ppstrong-c51-tuya2_geeni-2.10.6.20210819",
 "authkey":"<redacted>","deviceid":"<redacted>","pid":"aaa",
 "WiFi MAC":"38:01:46:1c:b2:48"}
```

| Property | Value |
|---|---|
| Model | Mini 11S (CW017 family), 1080p indoor |
| Software version | **2.10.6** |
| Hardware | `M11S_H1_V10_F23` |
| SoC | **HiSilicon ARMv7 Cortex-A7** (`CPU part 0xc07`), `hi_sfc` flash |
| Kernel | **Linux 4.9.37** |
| RAM | 32,908 kB (~37 MB) |
| Flash | 16 MB SPI NOR |
| BusyBox init | `/etc/inittab` → `::sysinit:/etc/init.d/rcS` |
| Manufacturer string | `Meari Tech` (echoed by rcS) |

### Stock boot command line

```
mem=37M console=ttyAMA0,115200n8 mtdparts=hi_sfc:192k(bld)ro,64k(env)ro,64k(enc)ro,
64k(sysflg)ro,3136k(sys),4352k(app),320k(cfg) ppsAppParts=5 ppsWatchInitEnd
```

> **Note `hi_sfc` and `mem=37M`.** Every documented working case in the
> existing projects uses **`spi0.0` with 64 MB RAM**. Compare:
> `mem=64M ... mtdparts=spi0.0:256k(bld),64k(env),...,2496k(sys),4608k(app),640k(cfg)`

### Flash layout (`/proc/mtd`)

| MTD | Size | Name | Notes |
|---|---|---|---|
| mtd0 | 192k | `bld` | bootloader |
| mtd1 | 64k | `env` | U-Boot environment |
| mtd2 | 64k | `enc` | encrypted |
| mtd3 | 64k | `sysflg` | |
| mtd4 | 3136k | `sys` | system / rootfs |
| mtd5 | 4352k | `app` | **ppsapp binary** |
| mtd6 | 320k | `cfg` | jffs2, holds `tuya_config.json` |

---

## ✅ CONFIRMED WORKING — opening the local HTTP server

**No reset. No power cycle. Simply hot-insert the SD card while the camera runs.**

### Procedure

1. Format a microSD card **FAT32**. **Small is better** — a 1.9 GB card worked.
   Cheap consumer cards are fine; industrial/ATP cards reportedly fail to mount
   in time.
2. Put **`ppsFactoryTool.txt`** in the card **root**. **Edit it — do not retype
   or copy-paste the contents**, the parser is format-sensitive:

   ```
   module=wifi,,ssid=YOUR_SSID,,password=YOUR_PASSWORD,,
   ```

   - double commas between fields
   - **trailing `,,`** required
   - **no trailing newline**
   - no BOM, LF endings

3. With the camera **powered ON** and already working in the app,
   **insert the card (hot-insert).**
4. The camera disconnects and reconnects to the SSID in the file. Wait ~60s.
5. **Port 80 is now open.**

**This contradicts the primary documentation**, which describes a reset-hold boot.
On this firmware the reset-hold does nothing useful; the hot-insert works.

### ⚠️ Port 80, NOT 8090

**2.10.x serves HTTP on port 80.** Port **8090 is 4.0.x only.**

Querying 8090 returns "connection refused" and looks like total failure. This
cost hours of debugging. Confirmed independently by
[Merkury1080P issue #4](https://github.com/guino/Merkury1080P/issues/4).

### ⚠️ Credentials: you MUST hand-build the Basic auth header

**`http://admin:056565099@IP/...` FAILS with 401** in .NET / PowerShell / many
clients, because **the camera's server sends no `WWW-Authenticate` header**, so
the client never attaches credentials.

**This is a client-side trap, not a wrong password.** Credentials are correct.

```bash
# curl works fine
curl -u admin:056565099 http://192.168.4.119/devices/deviceinfo
curl -u admin:056565099 http://192.168.4.119/proc/cmdline
```

```powershell
# PowerShell: hand-build the header. See scripts/query-camera.ps1
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('admin:056565099'))
$c = New-Object System.Net.Sockets.TcpClient
$c.Connect($ip,80); $s = $c.GetStream()
$rq = "GET /devices/deviceinfo HTTP/1.1`r`nHost: $ip`r`nAuthorization: Basic $auth`r`nConnection: close`r`n`r`n"
$b = [Text.Encoding]::ASCII.GetBytes($rq)
$s.Write($b,0,$b.Length); $s.Flush(); Start-Sleep -Milliseconds 900
$buf = New-Object byte[] 65536; $n = $s.Read($buf,0,65536); $c.Close()
[Text.Encoding]::ASCII.GetString($buf,0,$n)
```

Credentials: **`admin:056565099`** — also try **`admin:admin`** on some paths.

### What the HTTP server exposes

**Read-only. No directory listing.**

| Path | Result |
|---|---|
| `/devices/deviceinfo` | 200 — full identity (serial, authkey, deviceid) |
| `/proc/cmdline` | 200 — boot command line |
| `/proc/mtd`, `/proc/mounts`, `/proc/meminfo`, `/proc/cpuinfo` | 200 |
| `/proc/self/status` | 200 — **shows `ppsapp` runs as uid 0, `CapEff 3fffffffff`** |
| `/proc/self/root/<path>` | 200 — **full filesystem read** |
| `/proc/self/root/home/cfg/tuya_config.json` | 200 — all settings |
| `/proc/self/root/etc/init.d/rcS` | 200 — **the boot script** |
| `/proc/self/root/etc/inittab` | 200 |
| `/proc/self/root/etc/shadow` | 200 — **root SHA-512 hash exposed** |
| directory path | 200 with **empty body** (no listing) |
| missing path | 500 Internal Server Error |
| `PUT` / `POST` | **server hangs** — no write support |

> **The web server is `ppsapp` itself, running as root with every capability.**
> Write capability exists in the process; it is simply not exposed over HTTP.

### Readable filesystem paths confirmed

```
/proc/self/root/etc/init.d/          (dir)
/proc/self/root/etc/init.d/rcS       (script)
/proc/self/root/etc/inittab
/proc/self/root/etc/passwd
/proc/self/root/etc/shadow
/proc/self/root/etc/group
/proc/self/root/etc/resolv.conf      -> hardcoded 216.104.96.22, 216.104.98.222
/proc/self/root/etc/TZ               -> CST04:00:00  (China Standard Time)
/proc/self/root/home/cfg/tuya_config.json
/proc/self/root/bin/  /sbin/  /lib/  (dirs)
/proc/self/root/home/               (dir)
/proc/self/root/home/init.d/        (dir)

NOT present: /home/app/  /etc/rc.local  /drv/  /hisi/  /sound/
```

---

## 🔴 Root cause: the bootloader lacks `run`

**The standard SD boot hack cannot work on this hardware.** Confirmed by
[guino/Geeni720P](https://github.com/guino/Geeni720P) documenting a Geeni camera
with the **same `hi_sfc` flash driver**:

> *"https://github.com/guino/Merkury720 — **does not work because the bootloader
> lacks the `run` command** used by this method."*

### Mechanism of failure

The Merkury720 `env` file contains:

```
ipaddr=0;run hack;bootm 0x81C08000;
        ^^^^^^^^^
```

`run hack` is a **U-Boot command** that executes the `hack=` environment variable
as a shell script. **If the bootloader has no `run` command, the entire chain
silently fails.** The `env import` may appear to succeed while nothing executes.

guino confirmed on the same hardware:
> *"logs showing the ppsMmcTool.txt being executed but the env and run commands fail"*

### This explains every symptom observed

| Symptom | Explained by missing `run` |
|---|---|
| No `hack` marker on the SD card | `initrun.sh` never executed |
| No `home/` directory copied | same |
| `/proc/cmdline` never gains `ip=30;` | bootarg never applied |
| `81808000` **and** `81C08000` failed identically | **the address is irrelevant** |
| SD card mounts and records video fine | the card is not the problem |

**⚠️ Do not waste time trying more load addresses. The command is missing, not
the address.**

### Tested and failed

- Reset-hold during power-on, ~5s (multiple attempts)
- Reset-hold with the card already inserted
- `81C08000` (4.0.x address) in `env` + `ppsMmcTool.txt`
- `81808000` (2.7.x address) in `env` + `ppsMmcTool.txt`
- `ppsFactoryTool.txt` with an added `onvif_enable=1` field → **negative**

### ❌ `ppsFactoryTool.txt` does not accept extra keys

Tested with a card containing **only** `ppsFactoryTool.txt`:

```
module=wifi,,ssid=TEST,,password=TEST,,onvif_enable=1,,
```

**Result:** `onvif_enable` stayed `0`; `tuya_config.json` byte-identical
(1028 bytes); ports 8000/8554 stayed closed; camera healthy; port 80 still open.

**Conclusion:** it is a **WiFi-provisioning file only**. It parses
`module`/`ssid`/`password` and ignores other keys. It does not write config.
Clean, non-destructive negative.

---

## 🎯 The goal: ONVIF / RTSP

`/home/cfg/tuya_config.json` contains:

```json
"onvif_enable":	0,
"onvif_pwd":	"admin"
```

Per [guino on Merkury720 #28](https://github.com/guino/Merkury720/issues/28):
> *"Most devices on **2.10 and higher** allow you to enable ONVIF (which includes
> RTSP) **without patching** — just by enabling it in `tuya_config.json`"*

**Expected when enabled:** ONVIF on port **8000**, RTSP on port **8554**.

### Two further obstacles (documented upstream)

**1. Devices refuse ONVIF while offline.**
From [Merkury1080P #11](https://github.com/guino/Merkury1080P/issues/11), `@jilleb`:
> *"The `FUN_0001ff98` checks the online status of the device. While status is not
> Online, sleep. I replaced the `iVar1 != 1` by `iVar1 != 0` and it's totally
> ignored, device is nicely usable off-cloud!"*

**2. Enrollment + cloud time sync required.**
guino: devices stay in *enrollment mode* until registered in the phone app, and
need cloud time sync before RTSP/ONVIF starts — unless an **offline patch** is
applied.

**3. 2.10.6 `ppsapp` patches are not fully solved publicly.**
There is an open request: [BazzDoorbell #52 "ppsapp 2.10.6 request"](https://github.com/guino/BazzDoorbell/issues/52).
Patches posted so far target 2.7.x and 4.0.x. **A 2.10.6 patch may need to be
derived in Ghidra** — see [guino/ppsapp-rtsp](https://github.com/guino/ppsapp-rtsp).

---

## ✅ THE SOLUTION: SPI flash programmer

We confirmed the boot-time hook exists on this camera:

```
/etc/inittab:  ::sysinit:/etc/init.d/rcS

/etc/init.d/rcS:
  #! /bin/sh
  /bin/mount -a
  echo "Meari Tech"
  for initscript in /etc/init.d/S[0-9][0-9]*
  do
      if [ -x $initscript ] ; then
          echo "[RCS]: $initscript"
          $initscript
      fi
  done
```

**Any executable `/etc/init.d/S##*` runs as root at every boot.** Same mechanism,
same manufacturer string, as the Geeni720P write-up.

### The only change needed — one script

```sh
#!/bin/sh
# /etc/init.d/S70custom      (MUST be chmod +x)

cat /proc/mounts > /tmp/hack

(
while true; do
 sleep 10
 if [ -e /mnt/mmc01/custom.sh ]; then
  cp /mnt/mmc01/custom.sh /tmp/custom.sh
  chmod +x /tmp/custom.sh
  /tmp/custom.sh
 fi
done
) &
```

See [`artifacts/S70custom`](artifacts/S70custom).

### Procedure

1. Remove the SPI flash chip (heat gun) — or try a **SOIC8 test clip** first
   (often fails in-circuit; the flash is still powered by the SoC)
2. `flashrom -p ch341a_spi -r flash.bin`  ← **keep this, it is your recovery image**
3. `binwalk -e -M flash.bin` → extract the **JFFS2 app partition**
4. Mount the jffs2 image, add `/etc/init.d/S70custom`, `chmod +x`, unmount
5. Patch it back into `flash.bin` **at the correct offset for this layout**
6. `flashrom -p ch341a_spi -w flash-custom.bin`
7. Reinstall the chip, boot with the Merkury720 `mmc/` files on the SD card
8. `custom.sh` now runs → telnet + `set onvif_enable 1`
9. Patch `ppsapp` for RTSP: <https://github.com/guino/ppsapp-rtsp>

Helper: [`scripts/flash-workflow.sh`](scripts/flash-workflow.sh)

### ⚠️⚠️ TWO CRITICAL WARNINGS

**1. The ch341a must be 3.3V-safe.**
The common black ch341a **drives SPI lines at 5V** and can **permanently damage**
a 3.3V flash chip. Buy a 3.3V-native programmer, a 3.3V-modded unit, or use a
**Raspberry Pi** (GPIO is 3.3V native — no mod, no risk).

**2. Do NOT reuse guino's partition offset.** The layouts differ:

```
THIS DEVICE : 192k(bld),64k(env),64k(enc),64k(sysflg),3136k(sys),4352k(app),320k(cfg)
Geeni720P   : 192k(bld),64k(env),64k(enc),64k(sysflg),2240k(sys),5m(app),448k(cfg)
```

**Derive the app-partition offset from `binwalk` on your own dump.**

---

## Other confirmed facts

- **The camera does not revert `tuya_config.json` immediately** — observed
  byte-identical (1028 bytes) across a mode change, despite guino's warning that
  the device rebuilds the file from Tuya's servers.
- Default timezone is **`CST04:00:00`** (China Standard Time).
- Nameservers are hardcoded: `216.104.96.22`, `216.104.98.222`.
- `ppsapp` runs as **uid 0** with `CapEff: 0000003fffffffff`.
- **IR-cut filter audibly clicks** on day/night transition.
  **Red LED** = IR/night mode or active recording. **Blue** = WiFi connected.
  Red + blue together with a click is **normal**, not a fault.
- The camera **records to the SD card in the clear**:
  `SDT/<serialno>/record/YYYY/MM/DD/HH/*.data`
  This is **local, cloud-free video storage that works with no modification.**
  Convert with [guino/ipcam26Xconvert](https://github.com/guino/ipcam26Xconvert).

---

## Safety

**The SD-card methods here are non-destructive.** Boot without the card →
stock behaviour. Nothing in the HTTP/hot-insert work writes to flash.

The risky steps are writing `env` (mtd1) or reflashing (mtd5) — **neither
succeeded or was completed here.**

**Recovery assets on the board:** UART pads (3.3V / RX / TX / GND, **115200 8N1**)
and a JTAG header. Neither was used. Note guino observed a **watchdog resets the
board quickly** over UART on related hardware.

---

## Open questions

1. What is the correct `S70custom` **flash offset** for the `4352k(app)` layout?
2. Does a **2.10.6 `ppsapp`** RTSP patch exist, or must it be derived in Ghidra?
3. Does the **offline patch** (ONVIF without cloud) exist for 2.10.6?
4. Is there any HTTP write vector in `ppsapp` not yet found?
5. Which other Geeni/Merkury models share this `hi_sfc` + 2.10.6 combination?

**If you have this device, please post your `/proc/cmdline` and
`/devices/deviceinfo`** — especially whether your cmdline shows `hi_sfc` or
`spi0.0`.

---

## Credits

- [guino](https://github.com/guino) — Merkury720, Merkury1080P, Geeni720P,
  BazzDoorbell, ppsapp-rtsp, ipcam26Xconvert. Nearly everything here builds on
  their work; the `run`-command root cause and the `S70custom` technique are
  theirs.
- [parkerlreed](https://github.com/parkerlreed) — CW017 4.0.x rooting
- [jilleb](https://github.com/jilleb) — offline patch (ONVIF without cloud)
- `Woolfy025`, `CyberCowboy`, `braidenwhite` — CW017 / Mini 11S threads that
  established **port 80 (not 8090)** and the **hot-insert** method

## License

Documentation: CC BY-SA 4.0. Scripts: MIT.

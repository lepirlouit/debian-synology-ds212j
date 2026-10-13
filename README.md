# Debian + a mainline kernel on a Synology DS-212j

A 2012 Synology DS-212j is still a perfectly usable little box: a Marvell Kirkwood
88F6281 at 1.2 GHz, 256 MB of DDR2, two SATA bays, USB 2.0 and gigabit Ethernet.
Synology stopped updating DSM for it long ago, and DSM 6.2 runs a 2.6.32 kernel.
This write-up replaces DSM with Debian running a current upstream Linux kernel,
and eventually swaps the 2012 vendor U-Boot for a modern mainline U-Boot.

> Repository: <https://github.com/lepirlouit/debian-synology-ds212j>
>
> **Status:** done. Mainline U-Boot v2026.07 is in SPI flash, and Debian 13 with Linux 7.2.10 boots from a RAID1 mirror on the two internal disks. Every step below was actually carried out on the hardware.

## Credits and prior work

This project stands on two earlier write-ups:

- **tangrs, ["Running Debian on a Synology DS212J"](https://blog.tangrs.id.au/2021/11/19/running-debian-on-a-synology-ds212j/)
  (19 November 2021)**. It explains how DSM boots, why a Debian root under DSM's 2.6.32
  kernel fails (`FATAL: kernel too old`), and how to boot Debian's `linux-image-marvell` from
  the stock U-Boot over TFTP with an appended DTB. Above all, it found the two most important
  board quirks: **GPIO 29/31 power the drives**, and **GPIO 35 is the fan tachometer, not an
  alarm**, so the upstream DT makes `systemd-udevd` spin. The DT changes from that post are in
  [this gist](https://gist.github.com/tangrs/c3e6bd13b849d5a5bcf9d338550427fe). Synology's GPL
  source, which both of us used, is on
  [SourceForge](https://sourceforge.net/projects/dsgpl/files/Synology%20NAS%20GPL%20Source/)
  and on Synology's own download site.
- **The Debian wiki, [InstallingDebianOn/Synology](https://wiki.debian.org/InstallingDebianOn/Synology)**.
  It covers the DS218j (Armada 385, a different SoC), but its general notes apply here: the
  3.3 V serial header (pins 2 = GND, 4 = TX, 6 = RX on the board; checked on the DS218j, not
  re-checked on this board), Ctrl-C to stop U-Boot, the appended-DTB `uImage` trick for old
  vendor U-Boots, and `make bindeb-pkg` for the kernel.

Where this guide goes further: a mainline U-Boot in flash (so no TFTP or serial is needed to
boot), a fixed upstream DT (RAM size, SATA pinctrl, LEDs), the `sata_mv` LED patch, RAID1
root without an initramfs, Debian kernel packages, and the DSM LED/beep behaviour. The
[appendix](#appendix--the-device-tree-changes-explained) says, for each DT change, where the
information came from. A [coverage table](#coverage-compared-with-the-earlier-write-ups) at the
end compares this guide with both sources.

## What you need

- The DS-212j. This guide wipes the disks, so back up anything you care about first.
- A 3.3 V USB-to-serial adapter connected to the board's console header
  (115200 8N1). Here it shows up as `/dev/ttyUSB0`.
- A Linux PC (Ubuntu/Debian-based here).
- One or two USB sticks.
- No network is required. Everything in this guide goes over the serial line and USB.

## Hardware facts gathered from the stock boot

```
U-Boot 1.1.4 (Mar 15 2012 - 15:43:19) Marvell version: 3.4.4
Soc: 88F6281 A1 (DDR2)
CPU running @ 1200Mhz L2 running @ 480Mhz
SysClock = 400Mhz , TClock = 200Mhz
DRAM CS[0] base 0x00000000   size 128MB
DRAM CS[1] base 0x08000000   size 128MB
DRAM Total size 256MB  16bit width
[4096kB@f8000000] Flash:  4 MB
Synology Model: DS212jr1
```

The stock environment boots with `bootm F8080000 F8280000`, which runs the kernel and
ramdisk straight out of the memory-mapped SPI flash. The stock U-Boot has
**no USB, SATA or FAT support**, so it can only boot from SPI flash, TFTP or the serial
line (`loadb`). This is the main reason to replace it later.

The 4 MB SPI flash layout, as seen by DSM:

| Offset     | Size     | Content                        |
|------------|----------|--------------------------------|
| 0x000000   | 0x80000  | U-Boot (kwbimage, SPI boot)    |
| 0x080000   | 0x200000 | DSM kernel (uImage)            |
| 0x280000   | 0x140000 | DSM ramdisk                    |
| 0x3C0000   | 0x10000  | vendor (MAC address, serial)   |
| 0x3D0000   | 0x20000  | "RedBoot config" (all zeros here, reused for the new U-Boot env) |
| 0x3F0000   | 0x10000  | FIS directory                  |

## Step 1 – Get to the U-Boot prompt

Connect the serial adapter, open the console at 115200 baud, power the NAS on, and press any
key when you see `Hit any key to stop autoboot`. You land at the `Marvell>>` prompt.

To catch the prompt reliably from a script, I used
[`tools/catch_uboot.py`](tools/catch_uboot.py), which logs the console and spams Ctrl-C
once the countdown starts.

## Step 2 – Back up the whole SPI flash (over serial only)

The stock U-Boot can't write to USB, but the flash is memory-mapped at `0xF8000000`,
so we can simply `md` it and parse the hex dump on the PC. To be sure no byte is corrupted
on the serial line, every 64 KB chunk is checked against U-Boot's own `crc32` command and
re-read if it doesn't match:

```
python3 tools/dump_flash.py backup/flash_stock.bin
```

This takes about 25 minutes at 115200 baud (no chunk needed a retry here). Keep
`backup/flash_stock.bin` safe: it is your way back to DSM, and the `vendor` area at
`0x3C0000` holds the board's real MAC address (`00:11:32:…`) and serial number.
The DSM kernel stored at `0x80000` turns out to be Linux 2.6.32.12.

### Extracting the DDR2 settings from the stock bootloader

The first 512 bytes of the flash are the Kirkwood boot ROM header (`0x5a` = SPI boot,
load to `0x600000`, entry point `0x670000`). Its extension header contains the register writes
the boot ROM performs to initialise the DDR2 controller **before** U-Boot runs. A
new U-Boot needs exactly these values, and they are saved in
[`backup/ddr_regs.txt`](backup/ddr_regs.txt):

```
DATA 0xFFD01400 0x43000C30   # SDRAM config
DATA 0xFFD01404 0x39743000   # DDR controller control (low)
...
DATA 0xFFD01504 0x07FFFFF1   # CS0: 128 MB, enabled
DATA 0xFFD0150C 0x07FFFFF5   # CS1: 128 MB, enabled
...
```

### Pin multiplexing

The stock MPP (pin function) and GPIO registers can be read directly from the stock U-Boot
prompt. They are saved in [`backup/stock-mpp-gpio-regs.txt`](backup/stock-mpp-gpio-regs.txt):

```
Marvell>> md.l f1010000 7
f1010000: 01002222 03303311 00550000 00000000
f1010010: 44440000 00044444 00000000
```

Decoded: MPP0-3 are SPI, MPP6 is SYSRST_OUTn, MPP8/9 are I²C (for the S-35390A RTC),
MPP10/11 are UART0 (the console), and MPP13/14 are UART1 (the power/LED microcontroller).
Everything else is GPIO. The audio functions on MPP36-44 are leftovers from Marvell's
reference design; the DS-212j has no audio.

## Step 3 – Build tools (host)

```
sudo apt install bison flex libssl-dev libgnutls28-dev uuid-dev bc gcc-arm-linux-gnueabi \
    mmdebstrap qemu-user-static binfmt-support arch-test debian-archive-keyring
```

Ubuntu's `gcc-arm-linux-gnueabi` targets `armv5t` with soft-float, which is exactly what
the Kirkwood (ARMv5TE) and Debian's `armel` port need.

## Step 4 – A mainline U-Boot for the DS-212j

Mainline U-Boot (v2026.07) still supports Kirkwood and has a Synology DS109 board,
but nothing for the DS-212j. The port in
[`patches/u-boot/`](patches/u-boot/0001-arm-kirkwood-add-Synology-DS-212j-board.patch)
adds a `ds212j` target:

- `kwbimage.cfg` contains the DDR2 register list copied **verbatim** from the stock
  bootloader header (step 2). This is the only part that can't be guessed.
- The pin setup matches the stock registers, and the HDD LEDs and fan GPIOs are initialised.
- It uses the upstream `kirkwood-ds212j` device tree, which U-Boot shares with Linux.
- It enables USB storage, SATA (`sata_mv`) for both bays, ext4/FAT, and
  **bootstd**, so it finds `/boot/extlinux/extlinux.conf` on USB or SATA by itself.
- The environment is stored in SPI flash at `0x3D0000`, which was unused on this unit,
  and the `vendor` sector is left alone.

```
git clone --depth 1 -b v2026.07 https://source.denx.de/u-boot/u-boot.git
cd u-boot && git am ../patches/u-boot/*.patch
make CROSS_COMPILE=arm-linux-gnueabi- O=../uboot-out ds212j_defconfig
make CROSS_COMPILE=arm-linux-gnueabi- O=../uboot-out -j8
# -> ../uboot-out/u-boot.kwb (≈ 320 KiB, fits in the 512 KiB bootloader slot)
```

(On Ubuntu, the host `kwboot` tool links against `-ltinfo`. Install `libncurses-dev`, or
point `HOSTLDFLAGS=-L…` to a directory with a `libtinfo.so` symlink.)

## Step 5 – Linux 7.2 for the DS-212j

The upstream `kirkwood-ds212j.dts` has several bugs: wrong RAM size, a SATA pin conflict,
drives left unpowered, dark disk LEDs, and a fan interrupt storm. The
[DT patch](patches/linux/) fixes them. Each change, and how I found it, is explained in the
[appendix](#appendix--the-device-tree-changes-explained). The kernel
is built from `mvebu_v5_defconfig` plus a [config fragment](config/linux-ds212j.config)
that adds what systemd/Debian need (cgroups, seccomp, autofs, IPv6…), MD RAID1, the board
drivers (gpio-fan, LEDs, S-35390A RTC, Synology power-off via UART1) and appended-DTB
support so the stock U-Boot can boot it too.

```
tar xf linux-7.2.10.tar.xz && cd linux-7.2.10
for p in ../patches/linux/*.patch; do patch -p1 < $p; done
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
make O=../linux-out mvebu_v5_defconfig
scripts/kconfig/merge_config.sh -m -O ../linux-out ../linux-out/.config ../config/linux-ds212j.config
make O=../linux-out olddefconfig
make O=../linux-out -j8 zImage modules dtbs        # ~7 min on an 8-thread laptop
```

## Step 6 – A Debian 13 (trixie) armel root filesystem, built without root

Trixie is the last Debian release with `armel`. Its userland is fine, but it no longer ships
a Kirkwood kernel, which is why we built one. `mmdebstrap` in `unshare` mode builds the
rootfs as a normal user, running the armel binaries through qemu-user:

```
mmdebstrap --mode=unshare --arch=armel --variant=minbase \
  --include=systemd-sysv,udev,openssh-server,sudo,mdadm,u-boot-tools,… \
  trixie debian-trixie-armel.tar http://deb.debian.org/debian
```

[`tools/make-usb-image.sh`](tools/make-usb-image.sh) then turns it into a bootable disk
image, still without root. Inside a user namespace (`unshare --map-auto --map-root-user`),
it extracts the tarball with correct ownership, installs the kernel, DTB and modules,
writes `extlinux.conf`, `fstab`, the hostname and DHCP config, sets a root password, and
runs `mkfs.ext4 -d` on the result. A tiny Python snippet writes the MBR, so `sfdisk`
isn't needed either.

```
tools/make-usb-image.sh debian-trixie-armel.tar linux-out ds212j-usb.img 2500M
sudo dd if=ds212j-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
```

## Step 7 – Test the new U-Boot from RAM with `kwboot` (nothing is flashed)

The Kirkwood boot ROM can load a bootloader over the UART. `kwboot` (built along with
U-Boot) keeps sending the boot pattern while the board resets, and the ROM then takes
the image over XMODEM instead of reading SPI flash. There's no need to touch the power button.
Type `reset` at the stock prompt (or `reboot` in Linux), and start kwboot right away:

```
uboot-out/tools/kwboot -b uboot-out/u-boot.kwb -B 115200 /dev/ttyUSB0
```

[`tools/kwboot_test.py`](tools/kwboot_test.py) automates the reset, the upload and the
console log. The upload takes about 35 s. On the first try:

```
U-Boot 2026.07 (Oct 13 2026 - 14:32:39 +0200)
Synology DS-212j
SoC:   Kirkwood 88F6281_A1
Model: Synology DS212j v10, v20
DRAM:  256 MiB
...
** Booting bootflow 'usb_mass_storage.lun0.bootdev.part_1' with extlinux
Starting kernel ...
Linux version 7.2.10-ds212j ...
Welcome to Debian GNU/Linux 13 (trixie)!
ds212j login:
```

## Step 8 – Three bugs on the way to working disks

The first boot came up without disks. Fixing that turned up three separate problems.

**1. Upstream DT pin conflict.** `kirkwood-synology.dtsi` gives the SATA controller the
`sata0`/`sata1` pin groups, which include MPP20-23 for the activity LEDs. But
`kirkwood-ds212j.dts` also uses MPP20-23 as GPIO HDD LEDs, so pinctrl refused the SATA pins
and `sata_mv` never probed:

```
kirkwood-pinctrl: pin PIN21 already requested by gpio-leds-hdd-21-2; cannot claim for f1080000.sata
```

The stock MPP registers show MPP20-23 set to GPIO, so the fix is to drop the SATA node's
`pinctrl-0` on this board.

**2. The drives are not powered.** Once `sata_mv` probed, both links stayed down
(`SStatus 0`). On the DS-212j, each drive's 5 V/12 V is switched by a GPIO that is off at
reset. Under DSM, Synology's kernel switches it on. Driving the candidate lines from Linux
with `gpioset` found them (`gpioset -c 0 -z 29=1`, and disk 1 appeared):

| GPIO | Function                     |
|------|------------------------------|
| 29   | HDD1 power (active high)     |
| 31   | HDD2 power (active high)     |
| 20/21| HDD2/HDD1 green LED (active low) |
| 22/23| HDD2/HDD1 amber LED (active low) |
| 32-34| fan speed (3 bits)           |
| 35   | fan tachometer/alarm input   |

Synology's GPL kernel source for DSM 6.2 (`arch/arm/mach-feroceon-kw/synology-gpio.c`)
confirms it. `KW_6281_212j_GPIO_init()` reuses the DS109 table (`hdd2_pm = 31`, fan 32-35,
fail LEDs 22/23) and adds `hdd1_pm = 29`, and DSM waits 3 s between drives. The upstream
`kirkwood-synology.dtsi` already has the matching `regulators-hdd-29` node; the DS-212j DT
just never enabled it. The [DT patch](patches/linux/) does that, and the U-Boot board code
powers HDD1 at early init and HDD2 3 s later.

**3. U-Boot gives up on the drives too early.** Even when powered, U-Boot printed
`Failed to identify SATA device`, but a manual `sata stop; sata init` at the prompt a minute
later found both drives. Timing it showed that these Seagate ST32000644NS drives need **~18 s**
after power-on before they answer ATA IDENTIFY, while `sata_mv` tried only twice, 10 ms apart.
The second [U-Boot patch](patches/u-boot/) keeps asking for up to 30 s once the link is up.
Empty ports have no link, so they aren't delayed:

```
SATA0: waiting for drive to spin up done
SATA1: waiting for drive to spin up done
```

U-Boot also reads the factory MAC address from the `vendor` flash sector (6 bytes plus a
checksum byte, the sum of the 6 bytes). Without it, U-Boot made up a random MAC on every boot.

## Step 9 – Flash the new U-Boot

From the RAM-loaded U-Boot, I loaded the image over the serial line with YMODEM
(TFTP worked but stalled once, and serial is fast enough for 330 KB), checked its CRC
against the file on the PC, and wrote it:

```
DS212j> loady 0x1000000                 # PC: sb -k u-boot.kwb </dev/ttyUSB0 >/dev/ttyUSB0
DS212j> crc32 0x1000000 ${filesize}     # == crc32 of the file on the PC
DS212j> sf probe
DS212j> sf protect unlock 0 0x400000    # Synology leaves the block-protect bits set!
DS212j> sf update 0x1000000 0 ${filesize}
DS212j> sf read 0x2000000 0 ${filesize}
DS212j> cmp.b 0x1000000 0x2000000 ${filesize}
Total of 329216 byte(s) were the same
```

Without `sf protect unlock`, `sf update` fails with `ERROR: flash area is locked` and
writes nothing, which is harmless. Only the first 330 KB of flash change. The `vendor`
sector, the old DSM kernel/ramdisk and the rest stay as they were, and `kwboot` plus the
4 MB backup can restore everything.

## Step 10 – Install Debian on a RAID1 mirror of the two disks

Booted from the USB stick, I partitioned both disks identically (MBR, since the disks are 2 TB):

| Partition | Size   | Type | Array | Use |
|-----------|--------|------|-------|-----|
| sdX1      | 16 GiB | fd   | md0, **metadata 0.90** | `/` (with `/boot`) |
| sdX2      | 2 GiB  | da   | md1, metadata 1.2 | swap |
| sdX3      | rest   | da   | md2, metadata 1.2 + bitmap | `/srv` |

The 0.90 metadata for the root array is deliberate:

- The superblock sits at the **end** of the partition, so each member starts with a plain
  ext4 filesystem. U-Boot's bootstd reads `/boot/extlinux/extlinux.conf` straight from
  `sata 0:1` (or `sata 1:1` if the first disk dies) without knowing about RAID.
- The kernel **autodetects** 0.90 arrays on partitions of type `fd`
  (`CONFIG_MD_AUTODETECT`), so `root=/dev/md0` works **without an initramfs**.

The data and swap arrays use modern metadata, and mdadm assembles them in userspace from
`/etc/mdadm/mdadm.conf`. [`tools/install-to-raid.sh`](tools/install-to-raid.sh) creates the
filesystems, copies the running system and writes `fstab`, `mdadm.conf` and `extlinux.conf`.

```
md: Autodetecting RAID arrays.
md: running: <sdb1><sda1>
md/raid1:md0: active with 2 out of 2 mirrors
VFS: Mounted root (ext4 filesystem) on device 9:0.
Welcome to Debian GNU/Linux 13 (trixie)!
```

U-Boot scans SATA before USB, so the stick is no longer needed.

## Result

```
$ uname -r
7.2.10-ds212j
$ findmnt / /srv ; swapon
/dev/md0  /     ext4
/dev/md2  /srv  ext4   (1.8T)
/dev/md1  swap  2G
$ free -m
Mem:  239 total, 46 used
```

What works: both SATA disks in RAID1, gigabit Ethernet with the factory MAC, USB, the
RTC, the fan (gpio-fan, 3800 rpm at the default speed), the hardware crypto engine (CESA),
and the LEDs (disk, power, status) and buzzer behaving as under DSM (step 12). The serial console is at
115200 baud, and SSH works on the LAN.

## Step 11 – The kernel as a Debian package

Copying a `zImage` by hand works, but `apt` doesn't know about it. The kernel's own
`make bindeb-pkg` builds a proper `linux-image-7.2.10-ds212j` package, and Debian's
**u-boot-menu** package regenerates `/boot/extlinux/extlinux.conf` from the kernel
postinst/postrm hooks whenever a kernel is installed or removed. Each kernel gets an entry
plus a "rescue target" entry.

[`tools/build-kernel-deb.sh`](tools/build-kernel-deb.sh) does everything: it downloads and
verifies the tarball, applies the patches and config fragment, and builds the package.

```
sudo apt install debhelper            # bindeb-pkg's debian/rules calls dh_listpackages
tools/build-kernel-deb.sh 7.2.10 2    # -> build/debs/linux-image-7.2.10-ds212j_7.2.10-2_armel.deb
```

Notes:

- The `linux-headers` package is skipped (build profile `pkg.linux-upstream.nokernelheaders`).
  It would need the armel OpenSSL headers on the build host and is only useful for DKMS.
- `bindeb-pkg` installs the DTBs **flat** in `/usr/lib/linux-image-<version>/`, without the
  `marvell/` subdirectory.

On the NAS, `/etc/default/u-boot`:

```
U_BOOT_PARAMETERS="console=ttyS0,115200 rootfstype=ext4 rootwait ro"
U_BOOT_ROOT="root=/dev/md0"
U_BOOT_TIMEOUT="30"
U_BOOT_FDT="kirkwood-ds212j.dtb"
```

Install the kernel **before** `u-boot-menu`. Otherwise its first run finds no
`/boot/vmlinuz-*` and writes an empty menu, and the NAS won't boot:

```
sudo apt install ./linux-image-7.2.10-ds212j_7.2.10-2_armel.deb
sudo apt install u-boot-menu && sudo u-boot-update
```

Upgrading a kernel is now an ordinary `apt install` of the new package:

```
U-Boot menu
1:	Debian GNU/Linux 7.2.10-ds212j
2:	Debian GNU/Linux 7.2.10-ds212j (rescue target)
Retrieving file: /boot/vmlinuz-7.2.10-ds212j
Retrieving file: /usr/lib/linux-image-7.2.10-ds212j/kirkwood-ds212j.dtb
```

## Step 12 – LEDs, beep and fan, like DSM

### Disk LEDs

Synology's GPL code (`synobios/mv6281/ds212j.c` and `synology-gpio.c`) shows how DSM drives them:

- **Green** is driven by the SATA controller itself. MPP20/21 are switched to their
  "SATA activity" function (`0x5`), and the SATA LED register is set to "presence +
  activity" (`SATAHC_LED_ACT_PRESENT`, bit 2 at `0x8002C`). The LED stays lit while a disk is
  present and blinks on I/O.
- **Orange** (fault) are plain GPIOs 22/23, active low.

Mainline `sata_mv` knows the register bit (`SOC_LED_CTRL_ACT_PRESENCE`) but never sets it.
A [small patch](patches/linux/0002-ata-sata_mv-optional-presence-activity-LED-mode.patch)
adds a `marvell,led-act-presence` DT property for it. The DT routes MPP20/21 to the SATA
controller, and only the orange LEDs remain `gpio-leds`.

The orange LEDs are lit from userspace by `ds212j-leds` (see below) when a disk is `faulty`
in an md array or SMART reports it failing.

### Power LED, STATUS LED and beep

These are handled by the microcontroller on UART1 (`/dev/ttyS1`, 9600 8N1), which also
handles power-off (`1`, sent by the mainline `synology,power-off` driver). Synology's GPL
code only shows `4`/`6`. I tested every code below on this unit by sending it and watching
the front panel. Commands can be sent back to back.

| Code | Effect |
|------|--------|
| `4`  | power LED steady |
| `5`  | power LED blinking |
| `6`  | power LED off |
| `7`  | STATUS LED off |
| `8`  | STATUS LED green |
| `9`  | STATUS LED green, blinking |
| `:`  | STATUS LED orange |
| `;`  | STATUS LED orange, blinking |
| `3`  | the beep DSM gives when boot has finished |
| `2`  | a shorter beep |

`ds212j-microp` wraps these (`ds212j-microp power-led on`, `ds212j-microp status-led
orange-blink`, `ds212j-microp beep`…). The behaviour follows the DS212j hardware guide:

- **POWER:** blinks while booting (the microcontroller does this by itself from power-on)
  and while shutting down. It goes steady once the system is up.
- **Beep:** one beep when boot has finished.
- **STATUS:** green when all md arrays are healthy. Blinking orange when one is degraded or
  crashed, or when no array exists.

A oneshot systemd unit sends "power LED steady + beep + STATUS" when the system is up, and
"power LED blinking" when it's stopped at shutdown. `ds212j-leds` updates STATUS and the amber
HDD LEDs from mdadm's monitor (`PROGRAM` in `mdadm.conf`, on every RAID event) and from a
10-minute timer. It only talks to the microcontroller when the STATUS state changes.

Both scripts and their units are packaged as [`ds212j-support`](pkg/ds212j-support/),
built with `dpkg-deb --root-owner-group -b pkg/ds212j-support`.

### Fan: an interrupt storm in the upstream DT

After the first boot, `systemd-udevd` used ~25% CPU on an idle system. The upstream
Synology dtsi gives `gpio-fan` GPIO 35 as `alarm-gpios`, with an edge interrupt. But on
this board GPIO 35 is the fan **tachometer**: it toggles all the time while the fan spins.
Synology's own `GetFanStatus()` samples it 200 times and calls the fan "running" if it sees
both levels. Every edge raised the "alarm" interrupt, and `gpio-fan` answered each one with
a `sysfs_notify()` and a uevent:

```
$ grep fan /proc/interrupts
 35:     105970  f1010140.gpio   3 Edge   GPIO fan alarm
$ udevadm monitor --kernel     # 263 "change" events in 5 s
```

Deleting `alarm-gpios` for the DS-212j in the DT fixes it. Fan speed control is unaffected,
and the uevents drop to zero.

## Step 13 – Fan modes like DSM

DSM offers four fan modes: **Full-speed**, **Cool**, **Quiet** and **Low-power** ("the fan
stops when the system is cold"). The DS-212j has no board or CPU temperature sensor
(`THERMAL_NO, CPUTMP_NO` in Synology's `mapping.h`), so DSM's `scemd` daemon drives the fan
from the **disk temperatures**. Its tables come from the official firmware
(`DSM_DS212j_25556.pat` → `hda1.tgz`, which is xz despite its name →
`/usr/syno/etc.defaults/scemd.xml`):

```xml
<fan_config period="20" threshold="6" type="DUAL_MODE_HIGH" hibernation_speed="STOP">       <!-- Cool -->
	<disk_temperature fan_speed="ULTRA_LOW"  action="NONE">0</disk_temperature>
	<disk_temperature fan_speed="VERY_LOW"   action="NONE">33</disk_temperature>
	<disk_temperature fan_speed="LOW"        action="NONE">41</disk_temperature>
	<disk_temperature fan_speed="VERY_HIGH"  action="NONE">47</disk_temperature>
	<disk_temperature fan_speed="ULTRA_HIGH" action="NONE">53</disk_temperature>
	<disk_temperature fan_speed="ULTRA_HIGH" action="SHUTDOWN">61</disk_temperature>
</fan_config>
<!-- DUAL_MODE_LOW (Quiet): 0 ULTRA_LOW, 38 VERY_LOW, 46 LOW, 52 VERY_HIGH, 58 ULTRA_HIGH, 61 SHUTDOWN
     DUAL_MODE_LOW_STOP (Low-power): 0 STOP, 33 ULTRA_LOW, then like Quiet -->
```

The speed levels are the 3-bit value on GPIO 32-34 (`FanStatusMappingType1()`: STOP 0,
ULTRA_LOW 1, VERY_LOW 2, LOW 4, VERY_HIGH 6, ULTRA_HIGH 7). The DT lists all eight values in
that order (see the appendix), and `ds212j-fan` reproduces scemd **exactly**:

- It polls every 20 s, using the hottest internal disk (`smartctl -n standby -A`, which never
  wakes a sleeping disk).
- It speeds up at once and slows down only after 6 polls in a row (`threshold="6"`).
- The fan stops while the disks hibernate.
- It shuts the NAS down at 61 °C.

The mode is set in `/etc/default/ds212j-fan` (`MODE=full|cool|quiet|low-power`).
Measured on this unit, level VERY_LOW (2) actually stops the fan. DSM does the same.

## Step 14 – Disk hibernation like DSM

- **Spin-down:** a udev rule applies `hdparm -S` to the two internal disks whenever they
  appear. The delay is set in `/etc/default/ds212j-disks` (`SPINDOWN_MINUTES=10`, like DSM's
  "HDD hibernation" setting).
- **Nothing writes to the disks every few minutes.** journald keeps the journal in RAM
  (`Storage=volatile`, 16 MB), `rsyslog` is removed, and `ds212j-logsave` appends the journal
  to `/var/log/journal-saved/YYYY-MM.log` once a day and at every clean shutdown. A power cut
  loses at most a day of logs. The root filesystem is already mounted `noatime`.
- **The front panel looks like DSM's.** The DS212j is `HIBER_LED_POWER_ONLY` in Synology's
  source. While both disks are in standby (`hdparm -C`, which doesn't wake them), only the
  power LED stays lit: STATUS goes off (`7`) and the green HDD LEDs go off. The "presence" bit
  of the SATA LED register (`0xF108002C` bit 2) is cleared through `/dev/mem`, so the LEDs only
  blink on activity. The fan stops too. Everything returns when a disk wakes up.

To check whether the disks are really asleep: `sudo hdparm -C /dev/sda /dev/sdb`.

## Step 15 – copyparty file server

[copyparty](https://github.com/9001/copyparty) suits this box much better than Nextcloud.
Nextcloud needs PHP, a database and 512 MB+ of RAM, and 32-bit support is being deprecated.
copyparty is a single Python file that gives a web UI with resumable uploads, WebDAV, search,
and thumbnails (`python3-pil`, `ffmpeg`).

- The official single-file release, `copyparty-sfx.py`, is checked against the SHA-256
  published on GitHub and installed in `/usr/local/bin`.
- It runs as a dedicated `copyparty` user under a hardened unit
  ([`config/copyparty/copyparty.service`](config/copyparty/copyparty.service)):
  `ProtectSystem=strict`, with only `/srv/files` and `/var/lib/copyparty` writable.
- The config is [`/etc/copyparty/copyparty.conf`](config/copyparty/copyparty.conf.template):
  one account with full rights on `/srv/files` (RAID1), no anonymous access, and the index
  and thumbnails kept in `/var/lib/copyparty`.

```
sudo apt install --no-install-recommends python3-pil ffmpeg
sudo useradd --system --home-dir /var/lib/copyparty --create-home --shell /usr/sbin/nologin copyparty
sudo install -m 755 copyparty-sfx.py /usr/local/bin/
sudo install -d -o copyparty -g copyparty /srv/files
sudo systemctl enable --now copyparty        # -> http://ds212j:3923/
```

<!-- next steps are appended as they are done -->

## Appendix – The device-tree changes explained

The DS-212j [DT patch](patches/linux/0001-ARM-dts-kirkwood-ds212j-fix-RAM-SATA-HDD-power-and-LEDs.patch)
makes six changes, all to `arch/arm/boot/dts/marvell/kirkwood-ds212j.dts`. Each one is a place
where the upstream description of the board didn't match the real hardware. This appendix
explains what changed, and above all **how I found out what to change**. Every change rests on
at least two independent sources.

### Background: how the DS-212j device tree is built

The DTB tells the generic Kirkwood kernel what is on this particular board. It is built from
four files:

```
kirkwood.dtsi            → the SoC itself (UARTs, SATA, USB, GPIO controllers…)
kirkwood-6281.dtsi       → the 88F6281 variant (pin groups such as "sata0", "sata1")
kirkwood-synology.dtsi   → blocks shared by 16 Synology models, mostly
                           status = "disabled", for each model to switch on
kirkwood-ds212j.dts      → the DS-212j: switches on the blocks that apply
```

The board file is short, and that's where the bugs were. It switched on the wrong shared
blocks, or didn't switch on the right ones. The shared `.dtsi` files are left untouched, and
every fix is an override in `kirkwood-ds212j.dts`, so no other Synology model is affected.

### Where the information came from

| Source | What it gave |
|---|---|
| **The stock U-Boot**, over the serial console | the boot banner, the DDR register list (step 2), and the pin-mux (MPP) and GPIO register values |
| **Synology's GPL source** for the DSM 6.2 kernel (`linux-2.6.32`, model `6281`) and its `synobios` module, from Synology's download site (*ToolChain → Synology NAS GPL Source*) | the GPIO map and LED handling Synology itself uses on the DS212j |
| **Experiments on the running NAS** | kernel error messages, toggling GPIOs with `gpioset`, counting interrupts and udev events |
| **Watching the front panel** | which LED or beep reacts to which command |

The Synology files that matter are `arch/arm/mach-feroceon-kw/synology-gpio.c` (the per-model
GPIO tables), `arch/arm/mach-kirkwood/include/mach/synology.h`, and
`synobios/mv6281/ds212j.c` (DS212j-specific LED and fan code).

### 1. RAM: 128 MB → 256 MB

```diff
-		reg = <0x00000000 0x8000000>;
+		reg = <0x00000000 0x10000000>;	/* 256 MB: 2 x 128 MB chip selects */
```

**Evidence:**
- The stock U-Boot banner shows two 128 MB chip selects:
  ```
  DRAM CS[0] base 0x00000000   size 128MB
  DRAM CS[1] base 0x08000000   size 128MB
  DRAM Total size 256MB  16bit width
  ```
- The DDR init list in the stock bootloader header enables both:
  `0xFFD01504 = 0x07FFFFF1` (CS0, 128 MB, enabled) and `0xFFD0150C = 0x07FFFFF5` (CS1,
  128 MB, enabled).
- After the change Linux reports `node 0: [mem 0x00000000-0x0fffffff]`, and `free` shows
  239 MB usable.

Mainline U-Boot fixes up the memory node at boot anyway, but the DT should be right for
any bootloader.

### 2. Disk power: enable `regulators-hdd-29`

```diff
+	/* HDD1/HDD2 power switches: GPIO 29 and 31, both off at reset */
+	regulators-hdd-29 {
+		status = "okay";
+	};
```

**Symptom:** once SATA was probing (see #3), both ports stayed at
`ata1: SATA link down (SStatus 0 SControl F300)`. No disk was even electrically present,
yet DSM had seen both.

**How the pins were found:** tangrs had already found GPIO 29/31 in 2021, from Synology's
source and by toggling them through `/sys/class/gpio` until the drives spun up. That
[gist](https://gist.github.com/tangrs/c3e6bd13b849d5a5bcf9d338550427fe) enables the same
`regulators-hdd-29` block. I re-checked it independently on this unit:

1. `kirkwood-synology.dtsi` lists the HDD-power GPIOs used by the various models:
   29, 30, 31, 34, 44 and 45.
2. On the running NAS, `gpioget` showed all of them as inputs reading 0, so nothing was
   powering the disks.
3. I drove them high one at a time and rescanned SATA:
   ```
   # gpioset -c 0 -z 29=1; sleep 10; echo "- - -" > /sys/class/scsi_host/host0/scan
   ata1: SATA link up 3.0 Gbps (SStatus 123 SControl F300)
   ata1.00: ATA-8: ST32000644NS, SN11, max UDMA/133
   ```
   GPIO 29 powers disk 1, and GPIO 31 does the same for disk 2.
4. Synology's source confirms it (`synology-gpio.c`). The DS212j reuses the DS109 table,
   which has `.hdd2_pm = 31`, and adds HDD1:
   ```c
   KW_6281_212j_GPIO_init(SYNO_KW_GENERIC_GPIO *global_gpio)
   {
   	KW_6281_109_GPIO_init(global_gpio);
   	global_gpio->hdd_pm.hdd1_pm = 29;
   }
   ```
   `libata` switches a disk on with `SYNO_CTRL_HDD_POWERON(port, 1)`, so the line is
   **active high**, and DSM waits 3 s between the two disks.

**The fix:** `kirkwood-synology.dtsi` already describes exactly this, in a disabled block
called `regulators-hdd-29`: two always-on fixed regulators named `hdd1power` (GPIO 29) and
`hdd2power` (GPIO 31), active high, each with a 5 s start-up delay. The DS-212j file simply
never enabled it. The new U-Boot does the same in its board code (HDD1 at early init, HDD2
3 s later), so the disks are already spinning when U-Boot scans SATA and when Linux starts.

### 3. SATA pin conflict: route only MPP20/21 to the SATA controller

```diff
+&pinctrl {
+	pmx_sata0_act_21: pmx-sata0-act-21 {
+		marvell,pins = "mpp21";
+		marvell,function = "sata0";
+	};
+
+	pmx_sata1_act_20: pmx-sata1-act-20 {
+		marvell,pins = "mpp20";
+		marvell,function = "sata1";
+	};
+};
+
+&sata {
+	pinctrl-0 = <&pmx_sata0_act_21 &pmx_sata1_act_20>;
+	pinctrl-names = "default";
+	marvell,led-act-presence;	/* see #5 */
+};
```

**Symptom:** on the very first boot, the SATA driver didn't even load:

```
kirkwood-pinctrl f1010000.pin-controller: pin PIN21 already requested by gpio-leds-hdd-21-2; cannot claim for f1080000.sata
sata_mv f1080000.sata: error -EINVAL: Error applying setting, reverse things back
```

**Cause:** the SoC's pins are multi-purpose ("MPP"), and two blocks claimed the same ones:

- `kirkwood-synology.dtsi` gives the SATA controller the `sata0` and `sata1` pin groups,
  which `kirkwood-6281.dtsi` defines as MPP 5/21/23 and MPP 4/20/22 (the
  activity/presence LED outputs);
- `kirkwood-ds212j.dts` enabled `gpio-leds-hdd-21-2`, which uses MPP 20-23 as plain GPIOs.

The kernel won't give a pin to two drivers, so `sata_mv` gave up.

**What each pin should be:** three sources agree.

- **The stock pin-mux registers**, read from the stock U-Boot prompt:
  ```
  Marvell>> md.l f1010000 7
  f1010000: 01002222 03303311 00550000 00000000
  ```
  The third word covers MPP16-23, one nibble per pin starting from MPP16. `00550000` means
  MPP 20-23 are function 0 (GPIO) at boot, and the first word shows MPP 4/5 are GPIO as well.
- **Synology's DS212j LED code** (`synobios/mv6281/ds212j.c`, `SetHDDActLed()`): to light
  the disk LEDs, DSM switches MPP 20/21 to function `0x5`:
  ```c
  case SYNO_LED_ON:
  	SYNOMppCtrlRegWrite(20, 0x5);
  	SYNOMppCtrlRegWrite(21, 0x5);
  ```
- **The kernel's pin table** (`drivers/pinctrl/mvebu/pinctrl-kirkwood.c`) names that function:
  ```c
  MPP_VAR_FUNCTION(0x5, "sata1", "act", V(0, 0, 1, 1, 1, 0, 0)),   /* MPP20 */
  MPP_VAR_FUNCTION(0x5, "sata0", "act", V(0, 1, 1, 1, 1, 0, 0)),   /* MPP21 */
  ```
  It's valid on the 88F6281.

So the DT gains two pin-mux nodes (MPP21 → `sata0` act = HDD1 green, MPP20 → `sata1` act =
HDD2 green), and the SATA node claims only those two pins instead of the generic six.
MPP 22/23 stay GPIOs for the orange LEDs, and MPP 4/5 are left alone.

### 4. Disk LEDs: replace `gpio-leds-hdd-21-2` with `gpio-leds-hdd-fault`

```diff
-	gpio-leds-hdd-21-2 {
-		status = "okay";
-	};
+	gpio-leds-hdd-fault {
+		compatible = "gpio-leds";
+		pinctrl-0 = <&pmx_hddled_23 &pmx_hddled_22>;
+		pinctrl-names = "default";
+
+		led-hdd1-amber {
+			label = "synology:amber:hdd1";
+			gpios = <&gpio0 23 GPIO_ACTIVE_LOW>;
+			default-state = "off";
+		};
+
+		led-hdd2-amber {
+			label = "synology:amber:hdd2";
+			gpios = <&gpio0 22 GPIO_ACTIVE_LOW>;
+			default-state = "off";
+		};
+	};
```

**Why:** with the upstream node, all four disk LEDs were GPIO LEDs that nothing ever lit,
so the front panel stayed dark. DSM uses two different mechanisms:

- **Green** is hardware, driven by the SATA controller through MPP20/21 (#3 and #5).
- **Orange** is software. `synology-gpio.c` has `.hdd1_fail_led = 23, .hdd2_fail_led = 22`,
  and the LED function writes `fail_led = 0` for orange and `1` for off/green, so the LEDs
  are **active low**:
  ```c
  } else if ( DISK_LED_ORANGE_SOLID == status ||
  	DISK_LED_ORANGE_BLINK == status ) {
  	fail_led = 0;
  ```

The new node therefore keeps only the two orange LEDs, under the same names as before
(`synology:amber:hdd1/2` in `/sys/class/leds/`). The `ds212j-leds` script (step 12) lights
them when a disk is faulty in the RAID or fails SMART.

### 5. `marvell,led-act-presence`: green = present, blinking = activity

Routing MPP20/21 to the SATA controller isn't quite enough. By default the controller only
lights its "act" outputs **during I/O**. DSM's green LEDs are **on while a disk is present**
and blink on activity.

- **DSM:** the same Synology LED function begins with
  ```c
  MV_REG_WRITE(SATAHC_LED_CONFIG_REG, SATAHC_LED_ACT_PRESENT);
  ```
  and `mach-kirkwood/include/mach/synology.h` defines
  `SATAHC_LED_CONFIG_REG = SATA base | 0x2C` and `SATAHC_LED_ACT_PRESENT = 0x4`.
- **Mainline Linux:** `drivers/ata/sata_mv.c` already knows that register and bit,
  `SOC_LED_CTRL = 0x2c` and `SOC_LED_CTRL_ACT_PRESENCE = (1 << 2)` ("Multiplex dev presence
  with dev activity LED"), but nothing ever sets it.

This is the only change that also needs a driver patch,
[`0002-ata-sata_mv-optional-presence-activity-LED-mode.patch`](patches/linux/0002-ata-sata_mv-optional-presence-activity-LED-mode.patch).
It adds an optional `marvell,led-act-presence` DT property, and when the property is present
`sata_mv` sets the bit at initialisation. Using a property means only boards that ask for it
change behaviour.

### 6. Fan: delete `alarm-gpios`

```diff
 	gpio-fan-100-32-35 {
 		status = "okay";
+		/delete-property/ alarm-gpios;
 	};
```

**Symptom:** `systemd-udevd` used about 25% CPU on an idle system. tangrs describes exactly
this (19% idle CPU) in the post, and confirmed the tachometer by stopping the fan by hand
and watching the pin stop toggling.

**Diagnosis:**

- `gpio-fan-100-32-35` in `kirkwood-synology.dtsi` uses GPIO 32-34 as the 3-bit speed
  selector and GPIO 35 as `alarm-gpios`. For an alarm line, the `gpio-fan` driver requests an
  edge interrupt and, on each one, sends a `sysfs_notify()` and a uevent so userspace can react
  to a fan failure.
- But Synology's `ds212j.c` shows GPIO 35 is the fan's **tachometer**. `GetFanStatus()` samples
  it up to 200 times, 300 µs apart, and reports the fan as running only if it sees **both**
  levels. While the fan spins, it's a square wave.
- Measured on the NAS:
  ```
  $ grep -i fan /proc/interrupts
   35:     105970  f1010140.gpio   3 Edge      GPIO fan alarm
  $ sudo timeout 5 udevadm monitor --kernel | grep -c change
  263
  ```
  Every tach edge was handled as a "fan alarm", which meant a uevent and a wake-up of
  `systemd-udevd`, about 50 times a second.

**The fix:** `/delete-property/` removes that single property for the DS-212j. Fan speed
control keeps working (gpio-fan, `fan1_input` in hwmon), the interrupt disappears, and the
uevents drop to 0. GPIO 35 is now free for a userspace fan-failure check that counts its
edges, as DSM does.

tangrs fixed it differently: the gist enables the shared `gpio-fan-150-32-35` block instead of
`gpio-fan-100-32-35`. That block has no `alarm-gpios`, but it also has a **different speed
table**:

```
gpio-fan-100-32-35:  0→0  2500→1  3100→2  3800→3  4600→4  4800→5  4900→6  5000→7
gpio-fan-150-32-35:  0→0  2200→1  2500→2  3000→4  3300→3  3700→5  3800→6  4200→7
```

The `-150` ordering (value 4 below value 3) matches DSM's own `FanStatusMappingType1()` in
`synobios/mapping.c`, which maps VERY_LOW → 2, MIDDLE → 3, LOW → 4, HIGH → 5. To decide which
table is right, I **measured** the fan, now that GPIO 35 is free. For each value I waited 15 s,
then counted tach pulses for 10 s (`gpiomon -c 1 -e rising 3`), assuming 2 pulses per
revolution:

| Value | Measured | `-100` says | `-150` says |
|---|---|---|---|
| 0 | stopped | 0 | 0 |
| 1 | ~925 rpm | 2500 | 2200 |
| 2 | **stopped** (no tach pulses) | 3100 | 2500 |
| 3 | ~920 rpm | 3800 | 3300 |
| 4 | ~1620 rpm | 4600 | 3000 |
| 5 | ~1690 rpm | 4800 | 3700 |
| 6 | ~1640 rpm | 4900 | 3800 |
| 7 | ~1700 rpm | 5000 | 4200 |

Neither table matches this unit's fan. In practice it has two speeds (~920 and ~1650-1700 rpm),
and **value 2 stops it**, although both tables list value 2 as a running speed. The default
left by U-Boot (and what gpio-fan reports, "3800") is value 3, about 920 rpm.

The DT therefore lists **all eight values in DSM's order**, labelled with the measured speeds,
so `ds212j-fan` (step 13) can select exactly the level DSM would, by index through `pwm1`:

```dts
gpio-fan,speed-map = <   0 0>, < 925 1>, <   0 2>, < 920 3>,
                     <1620 4>, <1690 5>, <1640 6>, <1700 7>;
```

The value U-Boot leaves on the pins (3) must be in the table, or `gpio-fan` refuses to probe
(`missing speed array entry for GPIO value 0x…`).

### Checking the DTB on the NAS

`tools/build-kernel-deb.sh` applies the patch, `make bindeb-pkg` ships the DTB in
`/usr/lib/linux-image-<version>/kirkwood-ds212j.dtb`, and `u-boot-menu` points `extlinux.conf`
at it (`fdt …`). U-Boot loads it, fixes up the memory size and MAC address, and passes it to
the kernel. To see what the running system actually uses:

```
dtc -I dtb -O dts /usr/lib/linux-image-$(uname -r)/kirkwood-ds212j.dtb | less
ls /proc/device-tree/                       # the live tree the kernel booted with
cat /sys/kernel/debug/pinctrl/*/pinmux-pins # who owns each MPP (mount debugfs first)
```

## Coverage compared with the earlier write-ups

| Topic | tangrs (2021) | Debian wiki (DS218j) | This guide |
|---|---|---|---|
| Serial console, stop U-Boot | ✔ | ✔ (pinout) | ✔ (step 1) |
| How DSM boots (`.pat`, `linuxrc.syno`, setup mode) | ✔ | – | not needed: DSM is not used to boot |
| Debian root under the DSM kernel | ✔ (fails: kernel too old) | – | not needed |
| Boot Debian's kernel from stock U-Boot (appended DTB, `mkimage`, TFTP) | ✔ | ✔ (DS218j, from disk) | replaced by a mainline U-Boot (steps 4, 7, 9); our kernel still has `ARM_APPENDED_DTB` + `ATAG_DTB_COMPAT` for that route |
| Backup of the flash | – | – | ✔ (step 2, verified twice) |
| HDD power, GPIO 29/31 | ✔ | – | ✔ (DT + U-Boot staggered spin-up) |
| Fan GPIO 35 = tachometer, udev storm | ✔ (`gpio-fan-150`) | – | ✔ (`/delete-property/`), plus measured speed table |
| RAM 256 MB, SATA pinctrl conflict | – | – | ✔ |
| U-Boot gives up on slow-spinning drives | – | – | ✔ (`sata_mv` patch) |
| Permanent install (no TFTP or serial at boot) | listed as future work | ✔ (bootcmd + raw sectors) | ✔ (U-Boot in flash, extlinux) |
| Small initrd (`tiny-initramfs`) | listed as future work | – | not needed: no initramfs, RAID1 root autodetected |
| Debian kernel packages | uses Debian's `linux-image-marvell` (no longer in trixie) | `bindeb-pkg` | ✔ (step 11) |
| LEDs, power LED, beep, status LED | – | "some LEDs don't work" | ✔ (step 12) |
| Power-off ("LED stays on after shutdown" on DS218j) | – | ✔ (needs a kernel patch there) | driver enabled (`synology,power-off`), **not tested yet** |
| DSM firmware downgrader, kexec | mentioned | – | out of scope |
| Upstreaming the DT changes | gist, not merged | – | patches ready in `patches/`, **not submitted yet** |

## License

The scripts, the `ds212j-support` package and this documentation are released under the
GNU General Public License v2.0 or later (see [`LICENSE`](LICENSE)). The Linux and U-Boot
patches are derived works of those projects and are GPL-2.0, like the files they modify.


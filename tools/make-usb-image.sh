#!/bin/bash
# Build a bootable disk image (MBR, one ext4 partition) for the DS-212j:
#   /boot/zImage, /boot/dtbs/kirkwood-ds212j.dtb, /boot/extlinux/extlinux.conf
#   + Debian rootfs + kernel modules.
# Runs without root: the work happens inside a user namespace (unshare --map-auto),
# where file ownership in the rootfs is preserved for mkfs.ext4 -d.
#
# usage: make-usb-image.sh <rootfs.tar> <linux-build-dir> <output.img> [size]
set -euo pipefail

ROOTFS_TAR=$(realpath "$1")
KOUT=$(realpath "$2")
IMG=$(realpath -m "$3")
SIZE=${4:-2500M}
DISKID=0xd5212a01                 # -> root=PARTUUID=d5212a01-01
PARTUUID=d5212a01-01
ROOT_PASSWORD=${ROOT_PASSWORD:-ds212j}

KREL=$(cat "$KOUT/include/config/kernel.release")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ds212j-img.XXXXXX")
trap 'unshare --map-auto --map-root-user rm -rf "$WORK"' EXIT

unshare --map-auto --map-root-user --setuid 0 --setgid 0 bash -euo pipefail -s \
	"$ROOTFS_TAR" "$KOUT" "$WORK" "$KREL" "$PARTUUID" "$ROOT_PASSWORD" "$SIZE" <<'NS'
ROOTFS_TAR=$1 KOUT=$2 WORK=$3 KREL=$4 PARTUUID=$5 ROOT_PASSWORD=$6 SIZE=$7
R=$WORK/root
mkdir -p "$R"
tar -xpf "$ROOTFS_TAR" -C "$R" --numeric-owner --exclude="./dev/*"

# --- kernel, DTB, modules ---
mkdir -p "$R/boot/dtbs" "$R/boot/extlinux"
cp "$KOUT/arch/arm/boot/zImage" "$R/boot/zImage-$KREL"
ln -sf "zImage-$KREL" "$R/boot/zImage"
cp "$KOUT/arch/arm/boot/dts/marvell/kirkwood-ds212j.dtb" "$R/boot/dtbs/"
cp "$KOUT/.config" "$R/boot/config-$KREL"
cp "$KOUT/System.map" "$R/boot/System.map-$KREL"
make -s -C "$KOUT" ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- \
	INSTALL_MOD_PATH="$R" INSTALL_MOD_STRIP=1 modules_install
rm -f "$R/lib/modules/$KREL/build" "$R/lib/modules/$KREL/source"

cat > "$R/boot/extlinux/extlinux.conf" <<EOF
default debian
timeout 3

label debian
	menu label Debian GNU/Linux (kernel $KREL)
	kernel /boot/zImage
	fdt /boot/dtbs/kirkwood-ds212j.dtb
	append console=ttyS0,115200 root=PARTUUID=$PARTUUID rootwait rw
EOF

# --- basic system configuration ---
echo ds212j > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tds212j\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' > "$R/etc/hosts"
cat > "$R/etc/fstab" <<EOF
PARTUUID=$PARTUUID  /     ext4  defaults,noatime,errors=remount-ro  0 1
tmpfs               /tmp  tmpfs defaults,nosuid,nodev,size=64M     0 0
EOF
cat > "$R/etc/network/interfaces.d/eth0" <<EOF
allow-hotplug eth0
iface eth0 inet dhcp
EOF
echo 'en_US.UTF-8 UTF-8' > "$R/etc/locale.gen"
chroot "$R" locale-gen >/dev/null 2>&1 || true
echo "root:$ROOT_PASSWORD" | chroot "$R" chpasswd
chroot "$R" depmod -a "$KREL"
rm -f "$R/etc/ssh/ssh_host_"*            # regenerated on first boot
cat > "$R/etc/systemd/system/ssh-keygen-firstboot.service" <<'EOF'
[Unit]
Description=Generate SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../ssh-keygen-firstboot.service "$R/etc/systemd/system/multi-user.target.wants/ssh-keygen-firstboot.service"
# 256 MB of RAM: compressed swap in RAM helps apt a lot
echo zram > "$R/etc/modules-load.d/zram.conf"

# --- filesystem ---
mkfs.ext4 -q -F -L ds212j-root -d "$R" "$WORK/part.img" "$SIZE"
NS

# --- disk image: 1 MiB alignment, one Linux partition ---
PSIZE=$(stat -c %s "$WORK/part.img")
truncate -s 0 "$IMG"
truncate -s $((PSIZE + 1024*1024)) "$IMG"
# MBR with a single bootable Linux partition at LBA 2048 (written by hand: no sfdisk needed)
python3 - "$IMG" "$DISKID" "$((PSIZE / 512))" <<'PY'
import struct, sys
img, diskid, nsect = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3])
entry = struct.pack('<B3sB3sII', 0x80, b'\xfe\xff\xff', 0x83, b'\xfe\xff\xff', 2048, nsect)
mbr = bytearray(512)
mbr[440:444] = struct.pack('<I', diskid)
mbr[446:462] = entry
mbr[510:512] = b'\x55\xaa'
with open(img, 'r+b') as f:
    f.write(mbr)
PY
dd if="$WORK/part.img" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
echo "image: $IMG ($(du -h --apparent-size "$IMG" | cut -f1)), kernel $KREL, root=PARTUUID=$PARTUUID"

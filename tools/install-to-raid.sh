#!/bin/sh
# Run ON THE DS-212j (booted from the USB stick) after the RAID1 arrays exist:
#   md0 = sda1+sdb1, metadata 0.90 (superblock at the end: U-Boot reads it as plain ext4,
#         and the kernel autodetects it without an initramfs)  -> /
#   md1 = sda2+sdb2, metadata 1.2 -> swap
#   md2 = sda3+sdb3, metadata 1.2, internal bitmap -> /srv
# Creates the filesystems, copies the running system to md0 and makes it bootable.
set -eu

mkfs.ext4 -q -F -L ds212j-root /dev/md0
mkswap -L swap /dev/md1 >/dev/null
mkfs.ext4 -q -F -L data -m 0 /dev/md2

mkdir -p /mnt/new
mount /dev/md0 /mnt/new
cp -ax / /mnt/new/
mkdir -p /mnt/new/srv

SWAP_UUID=$(blkid -s UUID -o value /dev/md1)
DATA_UUID=$(blkid -s UUID -o value /dev/md2)

cat > /mnt/new/etc/fstab <<EOF
# md0 is assembled by the kernel (0.90 superblock, partition type fd)
/dev/md0          /     ext4  defaults,noatime,errors=remount-ro  0 1
UUID=$SWAP_UUID  none  swap  sw                                  0 0
UUID=$DATA_UUID  /srv  ext4  defaults,noatime,nofail             0 2
tmpfs             /tmp  tmpfs defaults,nosuid,nodev,size=64M     0 0
EOF

# md1/md2 are assembled by mdadm (udev incremental assembly)
mdadm --detail --scan > /mnt/new/etc/mdadm/mdadm.conf.arrays
{
	echo 'HOMEHOST <system>'
	echo 'MAILADDR root'
	cat /mnt/new/etc/mdadm/mdadm.conf.arrays
} > /mnt/new/etc/mdadm/mdadm.conf
rm /mnt/new/etc/mdadm/mdadm.conf.arrays

KREL=$(uname -r)
cat > /mnt/new/boot/extlinux/extlinux.conf <<EOF
default debian
timeout 3

label debian
	menu label Debian GNU/Linux (kernel $KREL, RAID1)
	kernel /boot/zImage
	fdt /boot/dtbs/kirkwood-ds212j.dtb
	append console=ttyS0,115200 root=/dev/md0 rootfstype=ext4 rootwait rw
EOF

sync
umount /mnt/new
echo "INSTALL OK"

#!/bin/bash
# Build Debian packages (linux-image, linux-libc-dev) of a mainline
# kernel for the Synology DS-212j, cross-compiled for armel.
#
# usage: tools/build-kernel-deb.sh <kernel-version> [debian-revision]
#   e.g. tools/build-kernel-deb.sh 7.2.10 1
#
# The sources are fetched from kernel.org (checksum verified), the DS-212j DT patch
# and config fragment from this repository are applied, and the .debs end up in
# build/debs/. Install them on the NAS with:  sudo apt install ./linux-image-*.deb
set -euo pipefail

VER=${1:?kernel version, e.g. 7.2.10}
REV=${2:-1}
TOP=$(cd "$(dirname "$0")/.." && pwd)
B=$TOP/build
SRC=$B/linux-$VER
OUT=$B/linux-out-$VER
MAJOR=${VER%%.*}

export ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
export KDEB_PKGVERSION=$VER-$REV KDEB_COMPRESS=xz
# No linux-headers package (it would need armel OpenSSL headers on the build host;
# only useful for out-of-tree/DKMS modules), and skip dpkg's build-deps check:
# the kernel's own debian/rules needs none of debhelper/libdw/libelf.
export DEB_BUILD_PROFILES="pkg.linux-upstream.nokernelheaders pkg.linux-upstream.nokerneldbg"
export DPKG_FLAGS="-d"
export DEBFULLNAME=${DEBFULLNAME:-$(git config user.name 2>/dev/null || echo DS-212j builder)}
export DEBEMAIL=${DEBEMAIL:-$(git config user.email 2>/dev/null || echo root@localhost)}

mkdir -p "$B/debs"
if [ ! -d "$SRC" ]; then
	cd "$B"
	wget -q -N "https://cdn.kernel.org/pub/linux/kernel/v$MAJOR.x/linux-$VER.tar.xz" \
		"https://cdn.kernel.org/pub/linux/kernel/v$MAJOR.x/sha256sums.asc"
	grep " linux-$VER.tar.xz\$" sha256sums.asc | sha256sum -c -
	tar xf "linux-$VER.tar.xz" && rm "linux-$VER.tar.xz"
	for p in "$TOP"/patches/linux/*.patch; do
		patch -d "$SRC" -p1 < "$p"
	done
fi

cd "$SRC"
make -s O="$OUT" mvebu_v5_defconfig
scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "$TOP/config/linux-ds212j.config" >/dev/null
make -s O="$OUT" olddefconfig
make O="$OUT" -j"$(nproc)" bindeb-pkg

# bindeb-pkg drops the packages in the parent directory of the output tree
mv "$B"/linux-*_"$VER-$REV"_armel.deb "$B"/linux-upstream_"$VER-$REV"_armel.* "$B/debs/" 2>/dev/null || true
ls -l "$B/debs/"

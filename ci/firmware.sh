#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Build the BPI-R3 boot firmware on Linux: TF-A BL2 and BL31 from
# MediaTek's tree, and mainline U-Boot packed into a FIP.  Same sources,
# patch, configuration fragment and build flags as the FreeBSD ports
# sysutils/atf-mt7986 and sysutils/u-boot-bananapi-r3 (-emmc).  Runs on
# Linux (aarch64-linux-gnu-gcc) and on FreeBSD (aarch64-none-elf-gcc and
# gmake, from packages).
#
#	firmware.sh OUTDIR [sdmmc|emmc]
#
# OUTDIR receives bl2.img, u-boot.fip and firmware-info (the versions, as
# shell variables).
set -eu

out=$1
dev=${2:-sdmmc}
case $dev in
sdmmc)	defconfig=mt7986a_bpir3_sd_defconfig ;;
emmc)	defconfig=mt7986a_bpir3_emmc_defconfig ;;
*)	echo "boot device must be sdmmc or emmc" >&2; exit 1 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
work=${WORKDIR:-$(mktemp -d)}/firmware-$dev
if [ -z "${CROSS_COMPILE:-}" ]; then
	if command -v aarch64-linux-gnu-gcc >/dev/null; then
		CROSS_COMPILE=aarch64-linux-gnu-
	else
		CROSS_COMPILE=aarch64-none-elf-
	fi
fi
cross=$CROSS_COMPILE
# TF-A and U-Boot need GNU make: "gmake" on FreeBSD.
gmake=${GMAKE:-$(command -v gmake || echo make)}
jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
atf_tools=
if [ "$(uname -s)" = FreeBSD ]; then
	# As in the ports: GNU sed under the name "sed" (TF-A's makefiles
	# use GNU syntax) and the cross compiler named explicitly.
	mkdir -p "$work/bin"
	ln -sf "$(command -v gsed)" "$work/bin/sed"
	PATH=$work/bin:$PATH
	atf_tools="CC=${cross}gcc CPP=${cross}cpp CFLAGS= CPPFLAGS= HOSTCC=cc"
fi

# Pinned as in the ports' distinfo files.
atf_commit=476cf6629f76
atf_sha256=c1386e863b4da2770204bc84402990abe993f9860d5cc95fef5a930d2e912f97
uboot_version=2026.10
uboot_sha256=3f856da3cbbc93af51ff95fde18588a348b4a26723b01d9841e999d988481015

sha256_of() {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d' ' -f1
	else
		sha256 -q "$1"
	fi
}
fetch() {	# url sha256 file
	[ -f "$3" ] || curl -fsSL --retry 3 -o "$3" "$1"
	[ "$(sha256_of "$3")" = "$2" ] || { echo "$3: checksum mismatch" >&2; exit 1; }
}

mkdir -p "$out" "$work"
out=$(cd "$out" && pwd)
cd "$work"
fetch "https://codeload.github.com/mtk-openwrt/arm-trusted-firmware/tar.gz/$atf_commit" \
    "$atf_sha256" atf.tar.gz
fetch "https://git.u-boot-project.org/u-boot/u-boot/-/archive/v$uboot_version/u-boot-v$uboot_version.tar.bz2" \
    "$uboot_sha256" u-boot.tar.bz2
rm -rf atf atf-build u-boot
mkdir atf u-boot
tar -xzf atf.tar.gz -C atf --strip-components=1
tar -xjf u-boot.tar.bz2 -C u-boot --strip-components=1

# TF-A: BL2 for the boot device, with DDR4, BL31, and fiptool for the
# host.
"$gmake" -C atf -j"$jobs" $atf_tools PLAT=mt7986 ARCH=aarch64 BOARD_BGA=1 \
    BUILD_STRING=$atf_commit CROSS_COMPILE="$cross" DRAM_USE_DDR4=1 \
    HAVE_DRAM_OBJ_FILE=yes USE_MKIMAGE=1 MKIMAGE=mkimage \
    BOOT_DEVICE="$dev" BUILD_BASE="$work/atf-build" all fiptool
bl=$work/atf-build/mt7986/release

# U-Boot: the board defconfig plus the ports' fragment (EFI loader,
# autoboot, environment in the "ubootenv" partition).
cd u-boot
patch -p0 < "$here/u-boot/patch-drivers_clk_mediatek_clk-mtk.c"
cp "$here/u-boot/bpir3_fragment" configs/
# merge_config.sh runs "make"; on FreeBSD it must be gmake (as in the port).
if [ "$(basename "$gmake")" != make ]; then
	sed -i.orig "s|make|$gmake|" scripts/kconfig/merge_config.sh
fi
CROSS_COMPILE="$cross" scripts/kconfig/merge_config.sh \
    "configs/$defconfig" configs/bpir3_fragment
"$gmake" -j"$jobs" ARCH=arm CROSS_COMPILE="$cross"
"$bl/tools/fiptool/fiptool" create --soc-fw "$bl/bl31.bin" \
    --nt-fw u-boot.bin u-boot.fip

cp "$bl/bl2.img" u-boot.fip "$out/"
cat > "$out/firmware-info" <<EOF
tfa=$atf_commit
uboot=$uboot_version
boot_device=$dev
EOF
cd "$out"
for f in bl2.img u-boot.fip; do echo "$(sha256_of $f)  $f"; done

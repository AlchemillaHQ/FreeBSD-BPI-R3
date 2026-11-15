#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Pack the SD and eMMC builds of firmware.sh into one tarball with a
# README (firmware-README.txt), for releases.
#
#	firmware-tarball.sh SD_DIR EMMC_DIR OUTDIR
#
# Writes OUTDIR/bpi-r3-firmware-tf-a-<commit>-u-boot-<version>.tar.xz
# and prints its path.
set -eu

sd=$1
emmc=$2
out=$3
here=$(cd "$(dirname "$0")" && pwd)

(. "$sd/firmware-info"; [ "$boot_device" = sdmmc ]) ||
    { echo "$sd: not an SD card build" >&2; exit 1; }
(. "$emmc/firmware-info"; [ "$boot_device" = emmc ]) ||
    { echo "$emmc: not an eMMC build" >&2; exit 1; }
. "$sd/firmware-info"
name=bpi-r3-firmware-tf-a-$tfa-u-boot-$uboot

mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$name" "$stage/$name/sd" "$stage/$name/emmc"
sed -e "s/@TFA@/$tfa/g" -e "s/@UBOOT@/$uboot/g" "$here/firmware-README.txt" \
    > "$stage/$name/README"
cp "$sd/bl2.img" "$sd/u-boot.fip" "$stage/$name/sd/"
cp "$emmc/bl2.img" "$emmc/u-boot.fip" "$stage/$name/emmc/"
chmod -R a+rX,go-w "$stage/$name"
# Files owned by root, whichever tar this is.
if tar --version 2>/dev/null | grep -q GNU; then
	owner="--owner=0 --group=0 --numeric-owner"
else
	owner="--uid 0 --gid 0"
fi
tar -cJf "$out/$name.tar.xz" $owner -C "$stage" "$name"
echo "$out/$name.tar.xz"

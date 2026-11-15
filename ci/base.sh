#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Fetch the FreeBSD base system from the newest official arm64 CURRENT
# snapshot.  CURRENT installs base with pkgbase, so the snapshot's disc1
# ISO carries an offline package repository instead of base.txz.  The ISO
# is checked against the SHA256 that FreeBSD publishes.
#
#	base.sh OUTDIR [VERSION]
#
# OUTDIR receives packages/ (the offline pkgbase repository) and
# "snapshot" (the snapshot's name).  Runs on Linux and FreeBSD; needs
# curl, xz and bsdtar (FreeBSD's tar).
set -eu

out=$1
ver=${2:-16.0}
site=https://download.freebsd.org/snapshots/arm64/aarch64/ISO-IMAGES/$ver
fail() { echo "$*" >&2; exit 1; }
bsdtar=$(command -v bsdtar || echo tar)
sha256_of() {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d' ' -f1
	else
		sha256 -q "$1"
	fi
}

mkdir -p "$out"
cd "$out"
# CHECKSUM files of the generic images have the date right after
# "aarch64-"; board images (RPI, PINE64, ...) have a board name there.
sumfile=$(curl -fsSL "$site/" |
    grep -o "CHECKSUM\.SHA256-FreeBSD-$ver-CURRENT-arm64-aarch64-[0-9]\{8\}-[0-9a-f]*-[0-9]*" |
    sort -u | tail -1)
[ -n "$sumfile" ] || fail "no snapshot found at $site"
snapshot=${sumfile#CHECKSUM.SHA256-}
curl -fsSL -o CHECKSUM.SHA256 "$site/$sumfile"

iso=$snapshot-disc1.iso
[ -f "$iso.xz" ] || curl -fsSL --retry 3 -o "$iso.xz" "$site/$iso.xz"
want=$(sed -n "s/^SHA256 ($iso\.xz) = //p" CHECKSUM.SHA256)
[ -n "$want" ] || fail "$iso.xz not in $sumfile"
[ "$(sha256_of "$iso.xz")" = "$want" ] || fail "$iso.xz: checksum mismatch"

rm -rf packages usr
# The ISO reader needs to seek, so no pipe here.
xz -dc "$iso.xz" > "$iso"
"$bsdtar" -xf "$iso" usr/freebsd-packages/offline
mv usr/freebsd-packages/offline packages
rm -rf usr "$iso" "$iso.xz"
[ -f packages/data.pkg ] || fail "no pkgbase repository in $iso"
echo "$snapshot" > snapshot
echo "$(ls packages | grep -c '\.pkg$') packages from $snapshot"

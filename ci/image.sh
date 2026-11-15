#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Assemble a BPI-R3 image for the SD card or the eMMC.  Runs as root on
# FreeBSD (in CI, a FreeBSD VM); nothing is compiled here.
#
#	image.sh INPUTS IMAGE [SIZE [sd|emmc]]
#
# The eMMC image has the same layout; its firmware/ must come from
# "firmware.sh ... emmc", and the boot ROM reads BL2 from the eMMC's boot0
# partition, so firmware/bl2.img is also written there separately.
#
# INPUTS holds:
#	firmware/bl2.img, firmware/u-boot.fip	from firmware.sh
#	kernel.txz, dtb/, kernel-info		from kernel.sh
#	packages/, snapshot			from base.sh
#
# Layout (see notes/booting.md): the first four partitions copy
# OpenWrt's SD layout, which the boot ROM and BL2 expect; then a FAT32
# ESP with loader.efi and a UFS root that growfs extends to the card on
# first boot.  The U-Boot environment partition is left empty, so U-Boot
# boots the ESP with its default environment.
set -eu
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
fail() { echo "$*" >&2; exit 1; }

[ $# -ge 2 ] || fail "usage: $0 inputs image [size]"
[ "$(id -u)" -eq 0 ] || fail "run as root"
in=$(realpath "$1")
out=$2
size=${3:-4G}
medium=${4:-sd}
case $medium in
sd|emmc) ;;
*) fail "medium must be sd or emmc" ;;
esac
overlay=mt7986a-bananapi-bpi-r3-$medium.dtbo
for f in firmware/bl2.img firmware/u-boot.fip kernel.txz kernel-info \
    dtb/mt7986a-bananapi-bpi-r3.dtb "dtb/$overlay" \
    packages/data.pkg snapshot; do
	[ -s "$in/$f" ] || fail "missing input: $f"
done
[ ! -e "$out" ] || fail "already exists: $out"
command -v sgdisk >/dev/null ||
    env ASSUME_ALWAYS_YES=yes pkg install -q gdisk >/dev/null ||
    fail "cannot install sysutils/gdisk"

work=$(mktemp -d /tmp/bpir3-image.XXXXXX)
md=
cleanup() {
	status=$?
	set +e
	for m in "$work/esp" "$work/root"; do
		if mount -p | awk -v p="$m" '$2 == p { f = 1 } END { exit !f }'
		then
			umount "$m"
		fi
	done
	[ -n "$md" ] && mdconfig -d -u "$md"
	rm -rf "$work"
	[ "$status" -eq 0 ] || echo "FAILED; $out is incomplete" >&2
	exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Partition table.  sgdisk, because gpart cannot set GPT attribute bit 2,
# which the boot ROM wants on bl2.
truncate -s "$size" "$out"
sgdisk --clear --set-alignment=1 \
	--new=1:34:8191 --typecode=1:8300 --change-name=1:bl2 \
	--new=2:8192:9215 --typecode=2:8300 --change-name=2:ubootenv \
	--new=3:9216:13311 --typecode=3:8300 --change-name=3:factory \
	--new=4:13312:21503 --typecode=4:ef00 --change-name=4:fip \
	--new=5:24576:155647 --typecode=5:ef00 --change-name=5:fbsdboot \
	--new=6:163840:0 --typecode=6:a503 --change-name=6:fbsdroot \
	--attributes=1:=:5 --attributes=2:=:1 \
	--attributes=3:=:1 --attributes=4:=:1 --hybrid=1 "$out" >/dev/null
# Working cards carry an active hybrid MBR entry for BL2.
printf '\200' | dd of="$out" bs=1 seek=462 conv=notrunc status=none
sgdisk --verify "$out"

md=$(mdconfig -f "$out" -S 512)
dd if="$in/firmware/bl2.img" of="/dev/${md}p1" bs=512 conv=sync status=none
dd if="$in/firmware/u-boot.fip" of="/dev/${md}p4" bs=512 conv=sync status=none
# FAT32 with 512-byte clusters needs an explicit FAT size: the computed
# one is two entries short (see notes/booting.md).
newfs_msdos -L EFI -F 32 -c 1 -a 1009 "/dev/${md}p5" >/dev/null
newfs -U -L rootfs "/dev/${md}p6" >/dev/null

mkdir "$work/esp" "$work/root" "$work/repos"
mount -t msdosfs "/dev/${md}p5" "$work/esp"
mount "/dev/${md}p6" "$work/root"
r=$work/root

# Userland: pkgbase from the snapshot's own repository.  The ISO it came
# from was checked against FreeBSD's published SHA256 by base.sh.
cat > "$work/repos/base.conf" <<EOF
FreeBSD-base-offline: {
	url: "file://$in/packages",
	signature_type: "none",
	enabled: yes
}
EOF
env ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes \
    pkg -o ABI=FreeBSD:16:aarch64 -o REPOS_DIR="$work/repos" \
    -o PKG_CACHEDIR="$work/cache" -r "$r" install -q FreeBSD-set-base

# Kernel, DTB and overlays.
tar -xpf "$in/kernel.txz" -C "$r"
mkdir -p "$r/boot/dtb/mediatek" "$r/boot/dtb/overlays" "$r/boot/efi"
install -m 444 "$in/dtb/mt7986a-bananapi-bpi-r3.dtb" "$r/boot/dtb/mediatek/"
install -m 444 "$in/dtb/$overlay" "$r/boot/dtb/overlays/"

# Boot path: U-Boot -> EFI/BOOT/bootaa64.efi (loader.efi) -> kernel.
mkdir -p "$work/esp/EFI/BOOT"
cp "$r/boot/loader.efi" "$work/esp/EFI/BOOT/bootaa64.efi"
cat > "$r/boot/loader.conf" <<EOF
autoboot_delay="3"
vfs.root.mountfrom="ufs:/dev/gpt/fbsdroot"
bpir3_dtb_load="YES"
bpir3_dtb_type="dtb"
bpir3_dtb_name="/boot/dtb/mediatek/mt7986a-bananapi-bpi-r3.dtb"
fdt_overlays="/boot/dtb/overlays/$overlay"
EOF
cat > "$r/etc/fstab" <<'EOF'
/dev/gpt/fbsdroot	/		ufs	rw		1	1
/dev/gpt/fbsdboot	/boot/efi	msdosfs	rw		2	2
tmpfs			/tmp		tmpfs	rw,mode=1777	0	0
EOF
cat > "$r/etc/rc.conf" <<'EOF'
hostname="bpi-r3"
ifconfig_mtketh0="DHCP"
sshd_enable="YES"
growfs_enable="YES"
growfs_swap_size="0"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
dumpdev="NO"
sendmail_enable="NONE"
EOF
# growfs is a firstboot script.
touch "$r/firstboot"

# Logins as on FreeBSD's own arm images: freebsd/freebsd (wheel) and
# root/root.  Change them after the first login.
echo freebsd | pw -R "$r" useradd freebsd -m -G wheel -s /bin/sh \
    -c "FreeBSD User" -h 0
echo root | pw -R "$r" usermod root -h 0

kinfo=$(cat "$in/kernel-info")
cat > "$r/etc/bpi-r3-image" <<EOF
image:    $(basename "$out")
built:    $(date -u '+%Y-%m-%d %H:%M UTC')
kernel:   $kinfo (github.com/AlchemillaHQ/freebsd-src)
userland: $(cat "$in/snapshot")
EOF
cat >> "$r/etc/motd.template" <<EOF

FreeBSD on the Banana Pi BPI-R3: https://github.com/AlchemillaHQ/FreeBSD-BPI-R3
Kernel $kinfo.  Build details: /etc/bpi-r3-image
Default logins are freebsd/freebsd and root/root: change them now.
EOF

for k in "$r"/boot/kernel/kernel; do
	echo "$(sha256 -q "$k")  ${k#$r}"
done
df -h "$r" "$work/esp"
sync
umount "$work/esp"
umount "$work/root"
gpart show -l "$md"
fsck_msdosfs -n "/dev/${md}p5"
fsck_ufs -fn "/dev/${md}p6"
mdconfig -d -u "$md"
md=
echo "$(sha256 -q "$out")  $out"

#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Build the eMMC installer: an SD card image that boots FreeBSD into a
# RAM disk and runs ci/installer/install.sh, which writes an eMMC image
# (from "image.sh ... emmc") and the eMMC BL2 to the board's eMMC.  Runs as
# root on FreeBSD; it compiles one small helper (emmcboot) with the host's
# clang against the eMMC image's own arm64 userland.
#
#	installer.sh INPUTS EMMC_IMAGE OUT [SIZE]
#
# INPUTS holds firmware/ (SD firmware, to boot the installer),
# firmware-emmc/bl2.img, kernel.txz, kernel-info and dtb/.
set -eu
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
fail() { echo "$*" >&2; exit 1; }

[ $# -ge 3 ] || fail "usage: $0 inputs emmc-image out [size]"
[ "$(id -u)" -eq 0 ] || fail "run as root"
here=$(cd "$(dirname "$0")" && pwd)
in=$(realpath "$1")
emmc=$(realpath "$2")
out=$3
size=${4:-1G}
for f in firmware/bl2.img firmware/u-boot.fip firmware-emmc/bl2.img \
    kernel.txz kernel-info dtb/mt7986a-bananapi-bpi-r3.dtb \
    dtb/mt7986a-bananapi-bpi-r3-emmc.dtbo; do
	[ -s "$in/$f" ] || fail "missing input: $f"
done
[ -s "$emmc" ] || fail "missing eMMC image: $emmc"
[ ! -e "$out" ] || fail "already exists: $out"
command -v sgdisk >/dev/null ||
    env ASSUME_ALWAYS_YES=yes pkg install -q gdisk >/dev/null ||
    fail "cannot install sysutils/gdisk"

work=$(mktemp -d /tmp/bpir3-installer.XXXXXX)
emd=
md=
cleanup() {
	status=$?
	set +e
	for m in "$work/esp" "$work/inst" "$work/sys"; do
		if mount -p | awk -v p="$m" '$2 == p { f = 1 } END { exit !f }'
		then
			umount "$m"
		fi
	done
	[ -n "$md" ] && mdconfig -d -u "$md"
	[ -n "$emd" ] && mdconfig -d -u "$emd"
	rm -rf "$work"
	[ "$status" -eq 0 ] || echo "FAILED; $out is incomplete" >&2
	exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# The eMMC image's root file system provides the arm64 userland for the
# RAM disk and the sysroot for emmcboot.
mkdir "$work/sys" "$work/esp" "$work/inst" "$work/mfs"
emd=$(mdconfig -f "$emmc" -S 512 -o readonly)
mount -o ro "/dev/${emd}p6" "$work/sys"
sys=$work/sys

cc --target=aarch64-unknown-freebsd16.0 --sysroot="$sys" -static -O2 \
    -Wall -Wextra -o "$work/emmcboot" "$here/installer/emmcboot.c"
strip "$work/emmcboot"

# RAM disk: /rescue, a few dynamic tools with their libraries, emmcboot
# and the installer, started on the console instead of a login.
m=$work/mfs
mkdir -p "$m/dev" "$m/tmp" "$m/media" "$m/root" "$m/etc" "$m/opt/bin" \
    "$m/lib" "$m/libexec" "$m/usr" "$m/var/db" "$m/var/run" "$m/var/empty" \
    "$m/installer"
tar -C "$sys" -cf - rescue | tar -C "$m" -xf -
ln -s rescue "$m/bin"
ln -s rescue "$m/sbin"
ln -s ../rescue "$m/usr/bin"
ln -s ../rescue "$m/usr/sbin"
needed() {	# arm64 ELF file: print the libraries it needs
	readelf -d "$1" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
}
for t in usr/sbin/devctl usr/sbin/diskinfo sbin/sha256; do
	cp "$sys/$t" "$m/opt/bin/"
	todo=$(needed "$sys/$t")
	while [ -n "$todo" ]; do
		next=
		for l in $todo; do
			[ -e "$m/lib/$l" ] && continue
			for d in lib usr/lib; do
				if [ -e "$sys/$d/$l" ]; then
					cp "$sys/$d/$l" "$m/lib/"
					next="$next $(needed "$sys/$d/$l")"
					break
				fi
			done
			[ -e "$m/lib/$l" ] || fail "library not found: $l"
		done
		todo=$next
	done
done
cp "$sys/libexec/ld-elf.so.1" "$m/libexec/"
install -m 555 "$work/emmcboot" "$m/opt/bin/"
install -m 555 "$here/installer/install.sh" "$m/installer/"
cp "$sys/etc/master.passwd" "$sys/etc/group" "$sys/etc/login.conf" "$m/etc/"
pwd_mkdb -d "$m/etc" "$m/etc/master.passwd"
cat > "$m/etc/rc" <<'EOF'
#!/rescue/sh
PATH=/rescue:/opt/bin; export PATH
mount -u -o rw /
mount -t tmpfs tmpfs /tmp
hostname bpi-r3-installer
ifconfig lo0 inet 127.0.0.1/8 up
exit 0
EOF
chmod 555 "$m/etc/rc"
echo "/dev/md0 / ufs rw 0 0" > "$m/etc/fstab"
echo 'console "/etc/autologin" xterm on secure' > "$m/etc/ttys"
cat > "$m/etc/autologin" <<'EOF'
#!/rescue/sh
exec </dev/console >/dev/console 2>&1
export TERM=xterm PATH=/rescue:/opt/bin HOME=/root
cd /root
exec /installer/install.sh
EOF
chmod 555 "$m/etc/autologin"
makefs -t ffs -s 48m -o label=installram "$work/mfsroot.ufs" "$m" >/dev/null

# Payload: the compressed eMMC image, the eMMC BL2 and their checksums.
ename=$(basename "$emmc")
echo "compressing $ename"
xz -T0 -6 -c "$emmc" > "$work/$ename.xz"
set -- $(ls -l "$emmc")
esize=$5
cat > "$work/info" <<EOF
image="$ename"
image_size="$esize"
image_sha256="$(sha256 -q "$emmc")"
image_xz_sha256="$(sha256 -q "$work/$ename.xz")"
bl2_sha256="$(sha256 -q "$in/firmware-emmc/bl2.img")"
EOF

# The installer card: SD firmware and layout, so the boot ROM starts it
# like any of our SD images; everything else in one UFS partition.
truncate -s "$size" "$out"
sgdisk --clear --set-alignment=1 \
	--new=1:34:8191 --typecode=1:8300 --change-name=1:bl2 \
	--new=2:8192:9215 --typecode=2:8300 --change-name=2:ubootenv \
	--new=3:9216:13311 --typecode=3:8300 --change-name=3:factory \
	--new=4:13312:21503 --typecode=4:ef00 --change-name=4:fip \
	--new=5:24576:155647 --typecode=5:ef00 --change-name=5:fbsdboot \
	--new=6:163840:0 --typecode=6:a503 --change-name=6:bpir3installer \
	--attributes=1:=:5 --attributes=2:=:1 \
	--attributes=3:=:1 --attributes=4:=:1 --hybrid=1 "$out" >/dev/null
printf '\200' | dd of="$out" bs=1 seek=462 conv=notrunc status=none
sgdisk --verify "$out"

md=$(mdconfig -f "$out" -S 512)
dd if="$in/firmware/bl2.img" of="/dev/${md}p1" bs=512 conv=sync status=none
dd if="$in/firmware/u-boot.fip" of="/dev/${md}p4" bs=512 conv=sync status=none
newfs_msdos -L EFI -F 32 -c 1 -a 1009 "/dev/${md}p5" >/dev/null
newfs -U -L installer "/dev/${md}p6" >/dev/null
mount -t msdosfs "/dev/${md}p5" "$work/esp"
mount "/dev/${md}p6" "$work/inst"
i=$work/inst

mkdir -p "$work/esp/EFI/BOOT"
cp "$sys/boot/loader.efi" "$work/esp/EFI/BOOT/bootaa64.efi"
# The loader's own files from the userland, then our kernel (no modules:
# the installer needs none) and the board DTB with the eMMC overlay.
(cd "$sys" && tar -cf - --exclude ./boot/kernel --exclude ./boot/dtb \
    --exclude ./boot/efi ./boot) | tar -C "$i" -xf -
mkdir -p "$i/boot/kernel" "$i/boot/dtb/mediatek" "$i/boot/dtb/overlays" \
    "$i/emmc"
tar -xpf "$in/kernel.txz" -C "$work" boot/kernel/kernel
install -m 555 "$work/boot/kernel/kernel" "$i/boot/kernel/"
install -m 444 "$in/dtb/mt7986a-bananapi-bpi-r3.dtb" "$i/boot/dtb/mediatek/"
install -m 444 "$in/dtb/mt7986a-bananapi-bpi-r3-emmc.dtbo" \
    "$i/boot/dtb/overlays/"
install -m 444 "$work/mfsroot.ufs" "$i/boot/"
cat > "$i/boot/loader.conf" <<'EOF'
autoboot_delay="3"
bpir3_dtb_load="YES"
bpir3_dtb_type="dtb"
bpir3_dtb_name="/boot/dtb/mediatek/mt7986a-bananapi-bpi-r3.dtb"
# The eMMC overlay: once switch D is flipped, the controller talks to the
# eMMC at full speed.  Until then it still reads the SD card.
fdt_overlays="/boot/dtb/overlays/mt7986a-bananapi-bpi-r3-emmc.dtbo"
mfsroot_load="YES"
mfsroot_type="md_image"
mfsroot_name="/boot/mfsroot.ufs"
vfs.root.mountfrom="ufs:/dev/md0"
EOF
install -m 444 "$work/$ename.xz" "$work/info" "$i/emmc/"
install -m 444 "$in/firmware-emmc/bl2.img" "$i/emmc/bl2.img"
cat > "$i/emmc/README" <<EOF
FreeBSD eMMC installer for the Banana Pi BPI-R3.
Payload: $ename ($(cat "$in/kernel-info"))
See https://github.com/AlchemillaHQ/FreeBSD-BPI-R3/blob/main/INSTALL.md
EOF

df -h "$i"
sync
umount "$work/esp"
umount "$work/inst"
gpart show -l "$md"
fsck_msdosfs -n "/dev/${md}p5"
fsck_ufs -fn "/dev/${md}p6"
mdconfig -d -u "$md"
md=
echo "$(sha256 -q "$out")  $out"

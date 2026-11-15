#!/rescue/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# eMMC installer for the Banana Pi BPI-R3.  Runs from a RAM disk; started
# on the console by /etc/rc of the installer image (see ci/installer.sh).
#
# The SD card and the eMMC share one controller, selected by DIP switch D.
# So the payload is copied from the SD card into RAM first, the MMC bus is
# detached, the user flips D to the eMMC, and the bus is attached again.
# Then the image goes to the eMMC's user area and BL2 to its boot0
# partition, and boot0 is enabled for booting.
#
# Nothing is written before the user types "install", and nothing is
# written to SPI-NAND or SPI-NOR at all.

PATH=/rescue:/opt/bin
export PATH
payload=/media/emmc
ram=/tmp/emmc
part_config=0x48	# BOOT_ACK, boot from boot0, access the user area

say() { printf '%s\n' "$*"; }
line() { say "------------------------------------------------------------------------"; }
ask() { printf '%s' "$1"; read -r reply; }
stop() {
	say ""
	say "*** $*"
	say "*** The installer stopped. You can power the board off now, or use"
	say "*** the shell below (type \"poweroff\" when done)."
	exec /rescue/sh -i
}
wait_for() {	# device seconds
	i=0
	while [ ! -e "$1" ] && [ $i -lt "$2" ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -e "$1" ]
}

line
say "FreeBSD on the Banana Pi BPI-R3: eMMC installer"
line

# 1. Copy the payload into RAM while the SD card is still connected.
wait_for /dev/gpt/bpir3installer 15 ||
    stop "The installer partition on the SD card was not found."
if [ -e /dev/mmcsd0boot0 ]; then
	stop "The controller already sees an eMMC. Set switch D to ON (SD card) and boot the installer again."
fi
mkdir -p /media "$ram"
mount -o ro /dev/gpt/bpir3installer /media || stop "Cannot mount the installer partition."
. "$payload/info" || stop "No payload description on the SD card."
say "Image:  $image"
say "Copying it into memory and checking it..."
cp "$payload/$image.xz" "$payload/bl2.img" "$ram/" || stop "Copy failed."
umount /media
[ "$(sha256 -q "$ram/$image.xz")" = "$image_xz_sha256" ] ||
    stop "The image on the SD card is damaged (checksum mismatch)."
[ "$(sha256 -q "$ram/bl2.img")" = "$bl2_sha256" ] ||
    stop "bl2.img on the SD card is damaged (checksum mismatch)."
say "OK."

# 2. Confirm.
line
say "This ERASES EVERYTHING on the eMMC and installs FreeBSD on it."
say "The SD card, SPI-NAND and SPI-NOR are not changed."
line
ask "Type \"install\" to continue, anything else to stop: "
[ "$reply" = install ] || stop "Cancelled. Nothing was written."

# 3. Hand the bus from the SD card to the eMMC.
devctl detach mmc0 || stop "Cannot detach the MMC bus."
while :; do
	line
	say "Now flip DIP switch D to OFF (leave A, B and C as they are)."
	say "The board keeps running; do not power it off."
	line
	ask "Press Enter when switch D is OFF: "
	devctl attach mmc0
	if wait_for /dev/mmcsd0boot0 10; then
		break
	fi
	say "No eMMC found. Check switch D and try again."
	devctl detach mmc0
done
set -- $(diskinfo /dev/mmcsd0)	# name sectorsize mediasize ...
size=$3
say "eMMC found: $((size / 1000000)) MB."
[ "$size" -ge "$image_size" ] || stop "The eMMC is smaller than the image."

# 4. Write and verify the system.
say "Writing the system to the eMMC (a few minutes)..."
xzcat "$ram/$image.xz" | dd of=/dev/mmcsd0 bs=1m status=progress ||
    stop "Writing the eMMC failed."
say "Verifying..."
[ "$(dd if=/dev/mmcsd0 bs=1m count=$((image_size / 1048576)) 2>/dev/null |
    sha256 -q)" = "$image_sha256" ] || stop "Verification of the eMMC failed."
say "OK."

# 5. BL2 to boot0, then enable boot0.  mmcsd writes its cached copy of
# PARTITION_CONFIG back on every partition switch, so: finish with boot0,
# go back to the user area, set the byte, and re-attach before checking.
say "Writing the boot loader (BL2) to the eMMC boot partition..."
dd if="$ram/bl2.img" of=/dev/mmcsd0boot0 bs=512 conv=sync 2>/dev/null ||
    stop "Writing boot0 failed."
set -- $(ls -l "$ram/bl2.img")	# mode links owner group size ...
bl2_len=$5
[ "$(dd if=/dev/mmcsd0boot0 bs=512 count=$(((bl2_len + 511) / 512)) 2>/dev/null |
    head -c "$bl2_len" | sha256 -q)" = "$bl2_sha256" ] ||
    stop "Verification of boot0 failed."
dd if=/dev/mmcsd0 of=/dev/null bs=512 count=1 2>/dev/null
emmcboot -s "$part_config" /dev/mmcsd0 >/dev/null ||
    stop "Cannot enable booting from boot0."
devctl detach mmc0
devctl attach mmc0
wait_for /dev/mmcsd0boot0 10 || stop "The eMMC did not come back."
[ "$(emmcboot /dev/mmcsd0 | sed -n 's/^PARTITION_CONFIG //p')" = "$part_config" ] ||
    stop "The boot configuration did not stick."
say "OK."

# 6. Done.
line
say "FreeBSD is installed on the eMMC."
say ""
say "  1. Press Enter. The installer halts the board; then unplug the"
say "     power (the BPI-R3 firmware cannot switch itself off)."
say "  2. Set the DIP switches to boot from the eMMC:"
say "       A off, B on, C on, D off   (0110)"
say "  3. Plug the power back in. The first boot grows the root file"
say "     system to the whole eMMC. Logins: freebsd/freebsd and root/root."
line
ask "Press Enter to halt: "
halt

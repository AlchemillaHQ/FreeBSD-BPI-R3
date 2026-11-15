# Booting FreeBSD and the image layout

FreeBSD boots on the BPI-R3 through the normal arm64 EFI path. The boot
ROM loads TF-A BL2, BL2 loads BL31 and U-Boot from a FIP, U-Boot starts
FreeBSD's stock `loader.efi`, and the loader boots the kernel with the
stock device tree plus an overlay for the boot medium.

The SD card layout keeps the firmware partitions where OpenWrt puts
them, followed by a FAT EFI system partition and a UFS root that grows
to fill the card on first boot. Two details of that layout broke boots
before we understood them, which is the traditional order of events:
the GPT attribute bit that the boot ROM needs on the BL2 partition, and
an undersized FAT on the EFI partition. A third, gpart's handling of
the hybrid MBR, is still an open question. There is no public image
yet.

The firmware itself and the ports that build it are described in
[firmware.md](firmware.md).

## Boot media and the DIP switch

The board can boot from the SD card, the onboard eMMC, SPI-NAND or
SPI-NOR. The SD card and the eMMC share one controller (MSDC0) through
an analog mux, so only one of them is reachable at a time. The
four-way DIP switch SW1 selects both the boot device and the mux.
According to a Banana Pi forum guide:

- A and B select the boot device.
- C selects SPI-NAND (on) or SPI-NOR (off).
- D selects SD (on) or eMMC (off) on the shared bus.

The schematic shows that D only drives the mux select lines; it is not
a boot strap.

Settings we have used (A B C D, 1 = on):

| Setting | Boots from | MSDC0 bus | Used for |
|---|---|---|---|
| 1111 | SD | SD | Normal FreeBSD on SD |
| 0110 | eMMC | eMMC | Ported firmware on the eMMC |
| 1010 | SPI-NAND | eMMC | OpenWrt recovery, eMMC work |
| 1011 | SPI-NAND | SD | SD work from the NAND U-Boot |

NOR boot was not tested. For SD or eMMC boot, D must match A and B: by
the schematic, 1110 asks the ROM for SD boot while the bus goes to the
eMMC.

### Pitfalls

- **The switch orientation is easy to misread**, and the boot ROM does
  not give partial credit. Several boots halted in the boot ROM because
  a switch was set wrong. A NAND boot with C off printed a NAND read
  error (`F9: 3905 0036`). The ROM log ends in `System halt!` on
  failure and in `Jump to BL` when it found BL2.
- **Flipping D while the board runs.** From the eMMC-booted U-Boot it
  works: after `mmc rescan` it reads the SD card, and the eMMC again
  after flipping back. The same flip from the SD-booted U-Boot made the
  board go silent; we have not diagnosed that. Under FreeBSD running from
  a RAM disk it works from SD to eMMC: detach the MMC bus
  (`devctl detach mmc0`), flip D, attach it again, and the eMMC comes up
  at HS400. The eMMC installer is built on this (see
  [eMMC layout](#emmc-layout)).

## SD card layout

Sectors are 512 bytes. The first four partitions copy OpenWrt's BPI-R3
SD layout. The boot ROM loads BL2 from partition 1, and BL2 finds the
FIP by its GPT name.

| # | Name | Start | Size | GPT type | Attr | Contents |
|---|---|---|---|---|---|---|
| 1 | bl2 | sector 34 | to 4 MiB | Linux data | 0x5 | BL2 |
| 2 | ubootenv | 4 MiB | 512 KiB | Linux data | 0x1 | U-Boot environment |
| 3 | factory | 4.5 MiB | 2 MiB | Linux data | 0x1 | Empty |
| 4 | fip | 6.5 MiB | 4 MiB | EFI system | 0x1 | BL31 and U-Boot |
| 5 | fbsdboot | 12 MiB | 64 MiB | EFI system | 0 | FAT32 ESP |
| 6 | fbsdroot | 80 MiB | Rest | freebsd-ufs | 0 | UFS2 root |

The ESP holds only `EFI/BOOT/bootaa64.efi`, a copy of `loader.efi`,
and is mounted on `/boot/efi`. The kernel and the DTBs live in `/boot`
on the UFS root. In our current images the environment partition is
left empty.

### GPT attribute bit 2 on bl2

Our first image halted in the boot ROM before BL2 (`System halt!`, no
`Jump to BL`). BL2's bytes and position were identical to a working
card, but the image builder had written zero GPT attributes. The
working card has 0x5 on bl2 (bit 0, platform required, and bit 2,
legacy BIOS bootable) and 0x1 on the other three firmware partitions.
The right bytes in the right place were not enough; the ROM also wanted
one more bit of paperwork.

The ROM picks BL2 by the bootable attribute: a MediaTek
[post to the U-Boot list](https://lists.denx.de/pipermail/u-boot/2022-August/491184.html)
says it uses the first bootable GPT partition, and MediaTek's TF-A tree
has an SD layout example with bit 2 set on BL2. An active MBR entry
alone was not enough. With 0x5 the card booted.

### Use sgdisk, not gpart

FreeBSD's gpart cannot set GPT attribute bit 2; its `bootme` attribute
is a different bit (59). We create the table with sgdisk from
sysutils/gdisk on the image file, before attaching it with mdconfig, so
GEOM sees the finished table.

### Hybrid MBR

The working card has a hybrid MBR: the protective entry plus an active
Linux-type entry covering BL2. Our builders reproduce it. sgdisk's
`--hybrid` creates that entry without the active flag, so the builder
sets the flag byte itself. Whether the ROM needs the MBR entry is not
established.

Note that `gpart recover` replaces a hybrid MBR with a plain protective
one. We saw this during a manual root growth and restored the MBR by
hand. The FreeBSD growfs startup script also runs `gpart recover` (see
[Root filesystem and growfs](#root-filesystem-and-growfs)).

### FAT geometry

A 64 MiB FAT32 ESP needs 512-byte clusters, because FAT32 needs at
least 65525 clusters and `newfs_msdos` refuses the default size. With
one-sector clusters the automatic FAT size is 1008 sectors, which holds
129024 entries, while the data area needs 129026 including the two
reserved entries. `fsck_msdosfs` then reports clusters that continue
out of range, and the boot-time check failed on the board; one
`fsck_msdosfs -n` run crashed. Our first image builder and FreeBSD's
native `newfs_msdos` both produced this geometry. The fix is an
explicit FAT size:

```
newfs_msdos -L EFI -F 32 -c 1 -a 1009 /dev/mdXp5
```

The ESP on our board was repaired in place by reducing the total-size
fields in its boot sectors by two sectors; no data moved.

## eMMC layout

On the eMMC, BL2 sits in the boot0 hardware partition, and boot0 must
be enabled for booting in the eMMC's partition configuration. The eMMC
user area has a GPT from an OpenWrt install. It uses the same offsets
as the SD card for `ubootenv` (4 MiB), `factory` (4.5 MiB) and `fip`
(6.5 MiB), followed by OpenWrt's `recovery` and `production`
partitions. As on SD, BL2 finds `fip` and the ported U-Boot finds
`ubootenv` by name.

FreeBSD installs on the eMMC with only an SD card, through the eMMC
installer from our image builds ([INSTALL.md](../INSTALL.md)):

1. The installer card boots FreeBSD into a RAM disk: the loader preloads
   a small UFS image as `md0` (`GENERIC` already has `MD_ROOT`) and
   applies the eMMC overlay, so the controller is set up for the eMMC
   before it is even connected. (FreeBSD's MMC layer ignores `no-sd`, so
   the SD card still works with that overlay until the flip.)
2. It copies its payload (the eMMC image and the eMMC BL2) into memory,
   detaches the MMC bus, waits for the user to flip D, and attaches the
   bus again.
3. It writes the eMMC image to the user area, verifies it, writes BL2 to
   `mmcsd0boot0` and verifies that too. mmcsd exposes the boot partitions
   as devices and writes them directly.
4. It sets PARTITION_CONFIG to 0x48 (boot acknowledge, boot from boot0,
   access the user area) with a CMD6 through mmcsd's `MMC_IOC_CMD`
   ioctl, then detaches and attaches the bus and reads EXT_CSD back.
   mmcsd keeps its own copy of PARTITION_CONFIG and writes it back on
   every partition switch, so the byte is set last, from the user area
   device, and checked only after the bus was attached again. Opening the
   whole disk for writing (which the ioctl needs) is refused while any of
   its partitions is mounted, another reason the installer runs from
   RAM.

The eMMC image uses the SD card layout above with the eMMC firmware in
`fip` and the eMMC overlay in `loader.conf`; growfs grows it to the
whole eMMC on the first boot. On our board the installer took a blank
eMMC (no BL2, FIP or ESP) to a FreeBSD that boots from it, at HS400,
with nothing but the installer card.

## From U-Boot to the kernel

The ported U-Boot has autoboot, the EFI loader and the standard boot
flow enabled (see [firmware.md](firmware.md)). With its default
environment it finds `\EFI\BOOT\BOOTAA64.EFI` on partition 5 and starts
it through the `efi_mgr` boot flow. U-Boot prints
`Cannot persist EFI variables without system partition`: EFI variables
are not stored, so the loader always runs through this removable-media
path. The loader then reads `/boot/loader.conf` from the UFS root.

U-Boot does not know a DTB file name for this board (`fdtfile` is
unset), so it passes its own built-in DTB to EFI applications. The
FreeBSD loader replaces it with the stock DTB from `/boot/dtb`.

Our older images, built with OpenWrt's U-Boot, used a custom
environment instead: load the DTB and `loader.efi` from the ESP and
run `bootefi` with both. The ported U-Boot needs no custom environment.

## Device tree and overlays

The board's device tree is the stock one from Linux, which FreeBSD
imports. Because SD and eMMC share MSDC0, the base DTB leaves that
controller disabled. Linux ships an overlay for each medium that
enables and configures it, plus overlays for the NAND and NOR flash.

OpenWrt's U-Boot environment picks overlays at boot by probing the
hardware. FreeBSD's loader has no such logic: the overlay is named in
`loader.conf`, so an installed system matches one medium. Our SD images
use:

```
vfs.root.mountfrom="ufs:/dev/gpt/fbsdroot"
bpir3_dtb_load="YES"
bpir3_dtb_type="dtb"
bpir3_dtb_name="/boot/dtb/mediatek/mt7986a-bananapi-bpi-r3.dtb"
fdt_overlays="/boot/dtb/overlays/mt7986a-bananapi-bpi-r3-sd.dtbo"
```

The three `bpir3_dtb_*` lines use the loader's generic module syntax
(the prefix is arbitrary) to load the DTB as type `dtb`. The loader
then reports `Using DTB from loaded file` and applies the overlay.

The overlay must match the position of switch D. The SD overlay is
built with the MMC driver branch; the eMMC tests so far used a DTB with
the eMMC overlay merged in ahead of time. See [mmc.md](mmc.md).

## Root filesystem and growfs

Root is UFS2 with soft updates, mounted by its GPT label
`/dev/gpt/fbsdroot`. The image's root partition fills the image (2 GiB
for our current development image), and growfs extends it on first
boot:

```
growfs_enable="YES"
growfs_swap_size="0"
```

plus an empty `/firstboot`. By default growfs adds a swap partition on
disks over 15 GB. Swap on an SD card is slow and wears the card, so we
turn it off. On our second board the root grew to fill a 32 GB card on
first boot, and the board has booted normally since.

Before growth, FreeBSD warns that the backup GPT is not at the end of
the disk, and `gpart show` marks the table `[CORRUPT]`. That looks
alarming but is expected for an image written to a larger card; growfs
runs `gpart recover` before resizing. As noted above, that also
replaces the hybrid MBR, and we have not checked the MBR on cards grown
this way.

An earlier, manual growth on a slow card failed with SD write timeouts
in an early version of the MMC driver: some writes on that card took
17 s. The
driver now allows for that. See [mmc.md](mmc.md).

## Development boot paths

Test kernels are installed next to the default one and booted once
with `nextboot -k`, so a bad kernel costs only a reboot.

For work on the storage itself we boot without the card: U-Boot loads
over TFTP a kernel with an embedded root file system and a DTB with the
overlay merged in, and starts it with `booti`. Nothing on the SD card
or the eMMC is mounted. This is how we work on the eMMC: with the bus
on the eMMC, the SD card is disconnected.

## Known boot issues

- **First DHCP in U-Boot after a warm reboot** fails, and a retry
  works. This only affects network boots. A probable cause, not
  verified: U-Boot resets the switch, and an 802.1D bridge at the far
  end (configured with an 8 s forward delay) holds the port for about
  16 s.
- **SD read failure before the kernel.** On the first SD card, warm
  reboots sometimes failed in the loader with EFI read errors (status
  7). Raw U-Boot reads of the same sectors also failed until
  `mmc rescan 0`. This was with OpenWrt's U-Boot and early FreeBSD SD
  drivers. Adding `mmc rescan 0` to the boot command passed two warm
  boots and failed on the third, so it is not a fix. We have not seen
  the failure since, on two other cards; one passed a 10-cycle
  warm-reboot soak. The cause is not known.
- **Serial noise can stop autoboot.** With our second board in its
  case, the serial link was corrupted and the board waited at the
  U-Boot prompt with no network, probably because noise on the console
  RX line aborted autoboot. Out of the case it booted normally. U-Boot
  is very attentive to its console, even when nobody is typing.
- **`shutdown -p` resets the board.** TF-A prints
  `Power-down unsupported` and the board reboots. Use `shutdown -h`,
  then remove power. This was seen with OpenWrt's TF-A build.
- **`unable to read ssr`.** U-Boot prints this with some SD cards.
  OpenWrt's U-Boot prints it too, and it has no effect on booting.
- **Random MAC address in U-Boot.** U-Boot uses a random MAC address on
  each boot. FreeBSD's Ethernet driver picks its own; see
  [ethernet.md](ethernet.md).

## Images

Ready-to-flash SD card images come from this repository's Images
workflow ([INSTALL.md](../INSTALL.md) says how to use them;
[ci/](../ci/README.md) has the scripts, which also run by hand on
FreeBSD or Linux). Each image holds:

- TF-A and U-Boot built from source exactly as the firmware ports build
  them (see [firmware.md](firmware.md));
- a kernel and modules built from the `bpi-r3/integration` branch, in a
  `GENERIC-NODEBUG` and a debug (`GENERIC`) flavour;
- the stock DTB with the SD overlay;
- the base system of the newest official FreeBSD 16.0-CURRENT arm64
  snapshot, installed with pkgbase, so `pkg` can update it later;
- the layout above, with growfs on first boot and the logins of
  FreeBSD's own arm images (freebsd/freebsd and root/root).

The first such image cold booted the board, grew its root to the full
32 GB card, got a DHCP address and ran a bridged bhyve guest (see
[bhyve.md](bhyve.md)). Each build also has an eMMC image and an eMMC
installer (see [eMMC layout](#emmc-layout)).

An official FreeBSD image needs the firmware ports committed and the
drivers in the tree, so that it can use a GENERIC kernel. A board
configuration for FreeBSD's arm64 release tooling with the layout above
exists, but it has not been used for a full source release build.

## Open work

- Install FreeBSD on the eMMC and boot it through EFI.
- Find out whether the hybrid MBR matters to the boot ROM.
- Diagnose the silent board after flipping switch D from the SD-booted
  U-Boot.
- Qualify warm reboots over many cycles with the ported firmware.

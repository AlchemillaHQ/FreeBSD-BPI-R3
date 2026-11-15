# Boot firmware from FreeBSD ports

The BPI-R3 boots through the MT7986 boot ROM, Arm Trusted Firmware-A
(TF-A) BL2 and BL31, and U-Boot. Our first FreeBSD images reused BL2
and the FIP (BL31 plus U-Boot) taken from a working OpenWrt SD card,
which works fine right up until someone asks where the binaries came
from. Four new ports now build all of it from source:

- sysutils/fiptool
- sysutils/atf-mt7986
- sysutils/u-boot-bananapi-r3
- sysutils/u-boot-bananapi-r3-emmc

Firmware built by the ports cold boots the board from both the SD card
and the eMMC and hands over to FreeBSD. All four ports are accepted.
One question is open: the licence of the prebuilt MediaTek libraries that MediaTek's TF-A tree links into BL2
and BL31.

The partition layouts and the steps after U-Boot are in
[booting.md](booting.md).

## The boot chain

1. **Boot ROM.** Part of the SoC, and not open to negotiation. DIP
   switches A and B pick the boot device. On SD the ROM loads BL2 from
   the GPT partition that has the "legacy BIOS bootable" attribute; on
   eMMC, from the boot0 hardware partition; on SPI-NAND, from the start
   of the flash.
2. **BL2** (TF-A). Initializes DRAM (DDR4 on this board), finds the GPT
   partition named "fip" and loads BL31 and U-Boot from it.
3. **BL31** (TF-A). The EL3 secure monitor. It starts U-Boot and stays
   resident to provide PSCI to the operating system.
4. **U-Boot.** Starts FreeBSD's `loader.efi` through its EFI support.

The FIP is TF-A's Firmware Image Package, a container for the later
boot stages. For this board it holds BL31 (`soc-fw`) and U-Boot
(`nt-fw`). A cold boot of the ported firmware from SD prints:

```
NOTICE:  BL2: v2.14.0(release):476cf6629f76
NOTICE:  EMI: Using DDR4 settings
NOTICE:  DRAM: 2048MB
NOTICE:  Located partition 'fip' at 0x680000, size 0x400000
NOTICE:  BL2: Booting BL31
NOTICE:  BL31: v2.14.0(release):476cf6629f76
U-Boot 2026.10 (Nov 14 2026 - 09:37:21 +0000)
```

## Why ports

The binaries we started with were TF-A 2.13 and U-Boot
2025.10-OpenWrt, extracted from an SD card. We could not rebuild those
exact binaries from pinned sources, and a FreeBSD release image should
take its boot firmware from packages, as the other arm64 board images
do. Ports review is also a separate queue from src review, so the
firmware can move forward while the drivers are reviewed.

## The ports

| Port | Builds | Review | State |
|---|---|---|---|
| sysutils/fiptool | fiptool from upstream TF-A lts-v2.14.11 | [D61533](https://reviews.freebsd.org/D61533) | Accepted |
| sysutils/atf-mt7986 | BL2 (SD and eMMC, DDR4) and BL31 | [D61536](https://reviews.freebsd.org/D61536) | Accepted |
| sysutils/u-boot-bananapi-r3 | U-Boot 2026.10 for SD boot, BL2, FIP | [D61539](https://reviews.freebsd.org/D61539) | Accepted |
| sysutils/u-boot-bananapi-r3-emmc | The same for eMMC boot | [D61540](https://reviews.freebsd.org/D61540) | Accepted |

### sysutils/fiptool

fiptool lives in the upstream TF-A tree, and the port builds only that
target. The version is lts-v2.14.11, the same TF-A release that
sysutils/atf-master builds, so fiptool and the other atf-* ports come
from one release. The fiptool sources are unchanged in lts-v2.14.14,
and v2.15.0 only adds a helper to `uuid.h` that fiptool does not use.

Ports review found that `fiptool version` printed "Unknown version",
which is honest but not very helpful. TF-A's `MAKE_TOOL_C` rule
compiles with `FIPTOOL_CPPFLAGS` only, so the `-DVERSION` that the
top-level Makefile puts in `CPPFLAGS` never reaches the compiler.
Upstream master still behaves this way. The port now patches the
fiptool Makefile to use `CPPFLAGS` (and drops `-Werror`), and sets
`BUILD_STRING`. Without `BUILD_STRING` the top-level Makefile runs
`git describe`, which would pick up any git tree that happens to
contain the work directory. The tool now prints
`v2.14.11(release):lts-v2.14.11`, as a build from the upstream tag
does.

### sysutils/atf-mt7986

Upstream TF-A has no MT7986 platform, so the port builds MediaTek's
fork, mtk-openwrt/arm-trusted-firmware, at commit 476cf6629f76 on the
`mtksoc` branch, which is the commit OpenWrt pins. It is a standalone
port, not a slave of sysutils/atf-master, because atf-master builds
upstream TF-A.

The port runs the TF-A build once per boot device (`sdmmc` and `emmc`)
for DDR4 in the BGA package, as fitted on the BPI-R3. It installs
`bl2.img` and `bl31.bin` under `share/atf-mt7986/sdmmc-ddr4/` and
`share/atf-mt7986/emmc-ddr4/`. SPI-NAND and NOR BL2 variants are not
built.

Build details that matter:

- The tree builds with GCC only (devel/aarch64-none-elf-gcc). The port
  forces `CC` and `CPP`, and clears `CFLAGS` and `CPPFLAGS` so the
  framework's flags cannot change code size.
- `ARCH=aarch64` is passed explicitly. The ports framework exports the
  host's `ARCH`, and TF-A's make picks it up.
- TF-A's make helpers use GNU sed syntax. With base sed the toolchain
  detection fails, so textproc/gsed is aliased to `sed`. fiptool needs
  the same alias.
- BL2 is wrapped with `mkimage` from sysutils/u-boot-tools.
- `HAVE_DRAM_OBJ_FILE=yes` selects the prebuilt DRAM library, the only
  form in which MediaTek ships the DRAM code.
- `BUILD_STRING` is the commit, so the banners show what was built.

### sysutils/u-boot-bananapi-r3 and -emmc

Mainline U-Boot already has `mt7986a_bpir3_sd_defconfig` and
`mt7986a_bpir3_emmc_defconfig`. The SD port adds a new `mt7986` family
to sysutils/u-boot-master in the same commit, as earlier board ports
did. The family build-depends on atf-mt7986 and fiptool, runs
`fiptool create --soc-fw bl31.bin --nt-fw u-boot.bin u-boot.fip` after
the U-Boot build, and copies the matching BL2 into the package. The
package installs `bl2.img` and `u-boot.fip`. The eMMC port is a slave
that changes only the defconfig and the boot device (`emmc`), so it
picks the eMMC BL2 and BL31.

A config fragment adds what the defconfigs leave out:

```
CONFIG_EFI_LOADER=y
CONFIG_AUTOBOOT=y
CONFIG_BOOTSTD_DEFAULTS=y
CONFIG_ENV_MMC_USE_SW_PARTITION=y
CONFIG_ENV_MMC_SW_PARTITION="ubootenv"
```

The board defconfigs disable the EFI loader and autoboot, and FreeBSD
needs both. The last two lines move the environment; see below.

**Clock fix backport.** The first U-Boot 2026.10 build reset in a loop
right after BL31: `serial_mtk: baud clock not defined`,
`No serial driver found`, `resetting`. In 2026.10 the MediaTek clock
code keeps its clock providers in a static array, which cannot be used
before relocation, so the UART gets no clock. Upstream fixed this in
3ffad26f17cb ("clk: mediatek: fix using clocks before relocation"),
which is in v2027.01-rc1 and later but not in v2026.10. The port
carries it as a patch until sysutils/u-boot-master moves to 2027.01. A
first guess, missing `bootph-all` properties on the clock nodes, was
wrong: the MT7986 clock drivers already mark themselves for use before
relocation.

**Environment location.** Mainline U-Boot keeps the environment at a
fixed offset of 3 MiB on the boot device. On the SD layout that is
inside the bl2 partition; on the eMMC it is in the area before the
environment partition. The fragment instead uses the GPT partition
named "ubootenv", which both layouts already have. The environment is
512 KiB, non-redundant.

**Device tree file name.** We first set `CONFIG_DEFAULT_FDT_FILE` and
then dropped it, because on MT7986 it has no effect. In 2026.10 the
option only reaches the environment through a board `.env` file or a
board config header, and MT7986 has neither, so `fdtfile` stays unset.
U-Boot then passes its own control DTB to EFI applications. FreeBSD's
loader loads its own DTB anyway (see [booting.md](booting.md)).

## The prebuilt MediaTek libraries

MediaTek's tree links prebuilt archives into the images. The link maps
of a build with the port's flags show:

- BL2: `dram.a`, `plat_efuse.a`, `efuse_cmd.a` and `mtk_plat_key.a`.
- BL31: `plat_efuse.a` and `efuse_cmd.a`.

No build option leaves them out: the platform makefile always includes
the eFuse and image decryption makefiles, and BL2's setup code always
calls into the platform key library.

The archives have no licence text of their own. The repository's
licence file (`license.rst` in the TF-A documentation) says the
software is provided under BSD-3-Clause, and the MediaTek source files
around the archives carry SPDX BSD-3-Clause headers. OpenWrt builds BL2
and BL31 from the same commit, ships them in its BPI-R3 images and
labels the package BSD-3-Clause.

The port declares `LICENSE=BSD3CLAUSE` on the basis of the
repository's licence statement and the SPDX headers. Whether that
statement covers the archives is an open question. We asked MediaTek
to state the licence explicitly in
[issue 24](https://github.com/mtk-openwrt/arm-trusted-firmware/issues/24).
If the answer gives different terms, the port will change.

## Installing

For SD boot, on a card with GPT partitions named "bl2" and "fip":

```
cd /usr/local/share/u-boot/u-boot-bananapi-r3
dd if=bl2.img of=/dev/gpt/bl2 bs=512 conv=sync
dd if=u-boot.fip of=/dev/gpt/fip bs=512 conv=sync
```

For eMMC boot, BL2 goes into the boot0 hardware partition and the FIP
into the "fip" partition of the eMMC user area. We wrote both from
U-Boot, with the image already loaded at `$loadaddr`:

```
mmc partconf 0 1 1 1                  # access boot0
mmc erase 0x0 0x400
mmc write $loadaddr 0x0 <BL2 blocks>
mmc partconf 0 1 1 0                  # back to the main area
mmc erase 0x3400 0x2000               # the fip partition
mmc write $loadaddr 0x3400 <FIP blocks>
```

Read each image back and compare before resetting; it is much cheaper
than finding out from the boot ROM. The eMMC must also have boot0
enabled for booting (`BOOT_PARTITION_ENABLE`); ours already had it from
an OpenWrt install.

## How the ports were tested

- **poudriere testport** of all four ports on 14.4, 14.5 and 15.1, on
  amd64 and aarch64: 24 of 24 pass, after the review fixes. The aarch64
  runs used a native arm64 builder. Under qemu user emulation, pkg
  itself failed to build in the 14.x aarch64 jails, which is a problem
  of the emulated environment. `stage-qa` and `check-plist` are clean,
  apart from two warnings that come from u-boot-master and apply to
  every U-Boot port.
- **Faster testport.** `poudriere testport -b latest` only uses an
  official package when its version matches the ports tree exactly. We
  tested on a tree checked out at the commit of the repository's newest
  package build (the `ports_top_git_hash` annotation in
  `packagesite.yaml`) with the port applied on top, so only pkg and the
  port under test were built.
- **FIP round trip.** With the packaged fiptool on amd64 and aarch64:
  `fiptool info` and `unpack` on the FIP that booted the board, then
  `create` from the parts. The new FIP is byte for byte identical.
- **SD cold boot.** The SD build, written to the bl2 and fip
  partitions, boots BL2, BL31 and U-Boot, which autoboots FreeBSD
  through `loader.efi` to a login prompt.
- **eMMC cold boot.** The eMMC build of exactly the reviewed content,
  written to boot0 and the fip partition, cold boots to U-Boot. From
  there FreeBSD was started over TFTP (a RAM-root kernel), and the eMMC
  ran in HS400 with clean data checks.
- **saveenv.** On both media: set a variable, `saveenv`, `reset`, and
  the variable is still there. On the eMMC, a CRC32 of OpenWrt's
  `factory` partition, which follows `ubootenv`, was unchanged.
- **Second board.** Our current development SD image carries the
  firmware from the poudriere-built u-boot-bananapi-r3 package, and a
  second, new BPI-R3 boots it.

## Pitfalls

- **Old environments are ignored.** An environment left by OpenWrt's
  U-Boot (redundant format) fails the CRC check of the new U-Boot,
  which then uses its default environment. That is harmless, and the
  first `saveenv` replaces it.
- **Do not copy OpenWrt's eMMC FIP command.** OpenWrt's U-Boot command
  for writing the FIP to the eMMC also erases 0x800 sectors from
  0x2000. That runs past `ubootenv` into `factory`. We did not copy it.
- **Keep a second boot path while experimenting.** When our first eMMC
  FIP reset in a loop, the board booted from SPI-NAND (OpenWrt's
  firmware) with the bus on the eMMC, and that U-Boot could rewrite the
  eMMC. With the network down, the fixed `u-boot.bin` was sent over the
  serial console with `loady`, started with `go`, and wrote its own
  FIP: a bootloader pulling itself up by its own bootstraps.
- **No `hash` command.** The mainline U-Boot build has no `hash`
  command; use `crc32` to check data read back from the card.
- Other U-Boot messages and quirks seen at boot (EFI variables, random
  MAC address) are listed in [booting.md](booting.md).

## Status and open work

- All four ports are accepted. The licence question above is still
  open.
- Drop the clock backport when sysutils/u-boot-master moves to 2027.01.
- Only SD and eMMC boot are covered. SPI-NAND and NOR firmware is not
  ported.
- Flipping switch D from SD to eMMC while the SD-booted U-Boot was
  running made the board go silent. From the eMMC-booted U-Boot, flipping
  to SD and back worked. This is not diagnosed (see
  [booting.md](booting.md)).
- A FreeBSD release image for the board should take `bl2.img` and
  `u-boot.fip` from these packages. That needs the ports committed and
  the drivers in the tree first.

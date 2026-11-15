# Image build scripts

The [Images workflow](../.github/workflows/images.yml) runs these on
GitHub. They also run by hand, on FreeBSD (the whole image) or on Linux
(everything except the final assembly).

| Script | Produces |
|---|---|
| `firmware.sh OUT [sdmmc\|emmc]` | `bl2.img` and `u-boot.fip`: TF-A from MediaTek's tree and mainline U-Boot, built exactly as the FreeBSD ports `sysutils/atf-mt7986` and `sysutils/u-boot-bananapi-r3` build them |
| `kernel.sh SRC OUT [KERNCONF]` | `kernel.txz` (kernel and modules), the board DTB, and the SD and eMMC overlays |
| `base.sh OUT` | `packages/`: the offline pkgbase repository of the newest FreeBSD 16.0-CURRENT arm64 snapshot, checked against FreeBSD's published SHA256 |
| `image.sh INPUTS IMAGE [SIZE [sd\|emmc]]` | the SD card image, or the eMMC image (with the eMMC firmware in `INPUTS/firmware`) (FreeBSD only, as root) |
| `installer.sh INPUTS EMMC_IMAGE OUT [SIZE]` | the eMMC installer: an SD card image that boots into a RAM disk and writes `EMMC_IMAGE` and the eMMC BL2 to the eMMC (`installer/install.sh`, with `installer/emmcboot.c` for the boot configuration) (FreeBSD only, as root) |
| `firmware-tarball.sh SD_DIR EMMC_DIR OUT` | the release's firmware tarball: both `firmware.sh` builds with a README (`firmware-README.txt`) |
| `release-notes.sh FILES BUILD_INFO ...` | the release notes, in Markdown, for the files in `FILES` |

`u-boot/` holds the U-Boot patch and configuration fragment from the
ports.

## On FreeBSD

Everything runs natively; the kernel is a plain cross build with the
base system's clang.

```
pkg install git curl gmake gsed aarch64-none-elf-gcc bison swig \
    u-boot-tools gnutls pkgconf gdisk

git clone --depth 1 -b bpi-r3/integration \
    https://github.com/AlchemillaHQ/freebsd-src.git src
sh ci/firmware.sh out/firmware sdmmc
sh ci/kernel.sh src out/kernel GENERIC-NODEBUG     # or GENERIC for debug
sh ci/base.sh out/base

mkdir inputs
cp -R out/firmware inputs/firmware
cp -R out/base/packages out/base/snapshot inputs/
cp -R out/kernel/kernel.txz out/kernel/kernel-info out/kernel/dtb inputs/
sh ci/image.sh inputs freebsd-16.0-current-bpi-r3-sd.img   # as root
```

Once the firmware ports are in the tree, `pkg install
u-boot-bananapi-r3` gives the same `bl2.img` and `u-boot.fip` in
`/usr/local/share/u-boot/u-boot-bananapi-r3/`, and `firmware.sh` is not
needed.

## On Linux

What GitHub's runners do. The kernel goes through
`tools/build/make.py`, FreeBSD's build wrapper for other hosts. Ubuntu
24.04 packages:

```
sudo apt-get install build-essential gcc-aarch64-linux-gnu bison flex bc \
    libssl-dev libgnutls28-dev python3-dev python3-setuptools \
    python3-pyelftools swig u-boot-tools device-tree-compiler uuid-dev \
    bmake time m4 file zlib1g-dev libbz2-dev libarchive-dev \
    libarchive-tools clang-18 lld-18 llvm-18 git curl xz-utils
```

The same commands as above produce the firmware, kernel and package
repository. `image.sh` needs FreeBSD (pkgbase, newfs, mdconfig), so
copy `inputs/` to a FreeBSD machine or VM for the last step; the
workflow uses a FreeBSD VM for it.

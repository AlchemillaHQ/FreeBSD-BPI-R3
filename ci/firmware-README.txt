Boot firmware for the Banana Pi BPI-R3
======================================

TF-A (BL2, BL31) and U-Boot for booting the BPI-R3 from an SD card or
from its eMMC. Built from source by the Images workflow of
https://github.com/AlchemillaHQ/FreeBSD-BPI-R3 (ci/firmware.sh), with the
same sources, patch, configuration and build flags as the FreeBSD ports
sysutils/atf-mt7986 and sysutils/u-boot-bananapi-r3 (-emmc).

  sd/bl2.img      TF-A BL2 for SD boot, DDR4
  sd/u-boot.fip   FIP: TF-A BL31 and U-Boot (mt7986a_bpir3_sd_defconfig)
  emmc/bl2.img    TF-A BL2 for eMMC boot, DDR4
  emmc/u-boot.fip FIP: TF-A BL31 and U-Boot (mt7986a_bpir3_emmc_defconfig)

U-Boot has the EFI loader, autoboot and standard boot enabled, keeps its
environment in a GPT partition named "ubootenv", and boots
EFI/BOOT/bootaa64.efi from the first EFI system partition it finds.

Where the files go
------------------

SD card (DIP switches A B C D = on on on on):
  bl2.img     the first GPT partition, at sector 34. The boot ROM wants
              GPT attribute bit 2 (legacy BIOS bootable) and bit 0 on it.
  u-boot.fip  the GPT partition named "fip" (BL2 finds it by name).

eMMC (switches = off on on off):
  bl2.img     the eMMC's boot0 hardware partition, with boot0 enabled
              for booting: EXT_CSD PARTITION_CONFIG = 0x48.
  u-boot.fip  the GPT partition named "fip" in the eMMC's user area.

The SD and eMMC images of the same build already contain the right
files in the right places; the eMMC installer also writes the eMMC
bl2.img to boot0. The partition layout is described in notes/booting.md
of the repository above.

Sources and licences
--------------------

TF-A:   MediaTek's tree, https://github.com/mtk-openwrt/arm-trusted-firmware
        at commit @TFA@ (BSD-3-Clause). BL2 links MediaTek's
        prebuilt DRAM, eFuse and platform key libraries, which are part
        of that tree.
U-Boot: v@UBOOT@ from https://git.u-boot-project.org/u-boot/u-boot
        (GPL-2.0), with the patch and configuration fragment in ci/u-boot/
        of the repository above. That patch, the fragment and the build
        script are the complete corresponding source together with the
        U-Boot release.

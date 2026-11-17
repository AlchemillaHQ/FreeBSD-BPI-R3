# MSDC: SD card and eMMC

The MT7986 has one MSDC (MediaTek SD/MMC) host controller. On the
BPI-R3 it drives either the microSD slot or the onboard 8 GB eMMC, and
a DIP switch selects which: one controller, two storage devices, and a
small plastic switch to keep the peace. The FreeBSD driver runs SD
cards in default and high-speed mode and the eMMC up to HS400, with
interrupts and descriptor DMA. On this board's eMMC it reads at about
170 MB/s, the same as Linux.

## Status

- Works on SD and eMMC; ready for review. The code is on branch
  `bpi-r3/mmc` of
  [AlchemillaHQ/freebsd-src](https://github.com/AlchemillaHQ/freebsd-src),
  on top of `bpi-r3/golden` (the first series, D61186 to D61191 and the
  ns8250 changes D61610, D61620 and D61611, rebased on current FreeBSD
  main).
- Planned as one driver commit for SD and eMMC, to be posted after the
  first series (D61186 to D61191) is reviewed. That commit was
  boot-tested on top of the first series alone, on SD and on eMMC.
- Uses the legacy mmc(4)/mmcsd(4) bridge interface, not MMCCAM.
- Not supported: SD UHS-I, SDIO, suspend/resume, HS400 enhanced strobe.

## Hardware

### One controller, two devices

The SoC has a single MSDC, `mmc0` at 0x11230000. On the BPI-R3, three
SGM7222 analog switches route its CLK, CMD and DAT0-3 to either the
microSD slot or the eMMC; DAT4-7 and the eMMC reset go straight to the
eMMC. Switch D of DIP switch SW1 drives the select line (on: SD, off:
eMMC). No GPIO controls it: the resistor that would connect GPIO_0 is
not fitted. Changing devices takes a fingernail, not a driver.

We tested with SW1 (A B C D) at 1111 (boot from SD, bus on SD), 1011
(boot from SPI NAND, bus on SD) and 1010 (boot from SPI NAND, bus on
eMMC); see [booting.md](booting.md). In U-Boot booted from eMMC,
flipping switch D at the prompt and running `mmc rescan` worked in both
directions, with each device reading correctly afterwards. From the
SD-booted U-Boot, flipping to eMMC made the board go silent (not
diagnosed). Under FreeBSD running from a RAM disk, flipping from SD to
eMMC works: `devctl detach mmc0`, flip, `devctl attach mmc0`, and the
eMMC is tuned to HS400 as on a normal boot. The eMMC installer relies on
it (see [booting.md](booting.md)).

### Device tree

`mt7986a-bananapi-bpi-r3.dts` leaves `mmc0` disabled and gives it a
fixed 3.3 V `vmmc-supply`, a fixed 1.8 V `vqmmc-supply`, and pin states
`default` and `state_uhs`. One of two upstream overlays enables it, and
the overlay must match switch D:

- `mt7986a-bananapi-bpi-r3-sd.dtso` sets 4-bit, 52 MHz,
  `cap-sd-highspeed`.
- `mt7986a-bananapi-bpi-r3-emmc.dtso` sets 8-bit, 200 MHz,
  `mmc-hs200-1_8v`, `mmc-hs400-1_8v`, `hs400-ds-delay = <0x14014>`,
  `non-removable`, `no-sd` and `no-sdio`.

We loaded the overlay with loader(8) `fdt_overlays`, or merged it into
the DTB with fdtoverlay for netboot.

### Registers, interrupt, clocks

- Two register windows: the MSDC block at 0x11230000 and the pad timing
  block ("top") at 0x11c20000. The top block holds the command and data
  sample delays (`TOP_CMD` 0x04 bits 9:5, `TOP_CONTROL` 0x00 bits 11:7)
  and the HS400 data strobe delay (`PAD_DS_TUNE` 0x0c).
- Interrupt: GIC SPI 143, level high.
- Clocks, by DT name: `source` is `emmc_416m_sel` on MPLL (416 MHz),
  `hclk` comes from `emmc_250m_sel` (250 MHz), and `source_cg` is a
  gate. The optional `bus_clk` and `sys_cg` run at 156.25 and
  78.125 MHz from the system AXI clock. `assigned-clocks` sets the
  parents; see [clocks.md](clocks.md). An optional `hrst` reset is
  supported, but the MT7986 DT has none.
- Initialization writes the MT7986 asynchronous FIFO and stopped-clock
  settings (`PATCH0` 0xb0 = 0x403c0046, `PATCH1` 0xb4 = 0xffff4309,
  response wait 3 in `PATCH2` 0xb8 bits 3:2) and turns off the internal
  card detect (`MSDC_PS` bit 0). We did not try other values.

### Card clock

The card clock is the 416 MHz source through an integer divider n in
`MSDC_CFG` bits 19:8, with the mode in bits 21:20:

| Mode (bits 21:20) | Card clock |
|---|---|
| 0, SDR | source / (4n), or source / 2 for n = 0 |
| 1 | Bypasses the divider |
| 2, DDR52 | source / (8n), or source / 4 for n = 0 |
| 3, HS400 | source / (8n), or source / 4 for n = 0 |

The driver never rounds above the request, so the card can end up well
below the requested clock:

| Timing | Requested | Actual |
|---|---|---|
| SD high speed | 50 MHz | 34.67 MHz |
| eMMC high speed | 52 MHz | 52 MHz |
| eMMC HS200, HS400 (DDR) | 200 MHz | 104 MHz |

Linux on this board also runs HS400 at 104 MHz for a 200 MHz request.

### Descriptor DMA

Each request uses one GPD (general packet descriptor, 28 bytes) that
points to a chain of BDs (buffer descriptors, 16 bytes), one per
physical segment; a second, empty GPD ends the chain.

| Descriptor | Word | Contents |
|---|---|---|
| GPD | 0 | HWO (bit 0), BDP (bit 1), checksum (bits 15:8) |
| GPD | 1 | Next GPD |
| GPD | 2 | First BD |
| BD | 0 | EOL (bit 0), checksum (bits 15:8), address bits 35:32 (in bits 31:28) |
| BD | 1 | Next BD |
| BD | 2 | Address bits 31:0 |
| BD | 3 | Length |

The checksum in word 0 bits 15:8 is 0xff minus the byte sum of the
descriptor's first 16 bytes. With `DMA_CFG` (0x9c) bit 1 set and bit 16
clear, the controller checks it and raises interrupt bit 17 (BD) or 18
(GPD) on a bad sum.

The engine is driven through these registers:

- `DMA_SA` (0x90) takes the chain address, with `DMA_HIGH` (0x8c) 0.
- `DMA_CTRL` (0x98) gets descriptor mode (bit 8), 64-byte bursts
  (6 << 12) and start (bit 0).
- `PATCH2` bit 1 enables 36-bit data addresses.
- `DMA_CFG` bit 0 shows the engine active.

## FreeBSD driver

Code: `sys/arm64/mediatek/mt7986_msdc.c` and `mt7986_msdc.h` (about
1,980 lines), `device mt7986_msdc` in `sys/arm64/conf/std.mediatek`,
and an entry in `sys/conf/files.arm64`. The driver attaches to
`mediatek,mt7986-mmc` on simplebus and implements the mmcbr methods
(request, update_ios, switch_vccq, tune, retune, get_ro, acquire_host,
release_host) under the stock mmc(4) and mmcsd(4). The eMMC shows up
as `mmcsd0` plus `mmcsd0boot0`, `mmcsd0boot1` and `mmcsd0rpmb`.

How it got here: a polled PIO prototype came first and had write
timeouts and filesystem panics on a slow card. It was educational,
mostly about fsck. The rewrite used interrupts and DMA through a
128 KiB bounce buffer, then descriptor DMA, which raised SD reads from
14.5 to 16.5 MB/s. HS200, HS400 and retuning came last.

### Requests and interrupts

One request runs at a time, driven by the interrupt thread and one
callout; done callbacks run outside the driver mutex.

Buffers are mapped directly with busdma (`BUS_DMA_NOWAIT`): up to
512 KiB and 129 segments, 36-bit addresses, so mmcsd sees a 1024-block
limit. The descriptors live below 4 GiB. A mapping failure rejects the
request before any command goes out.

The command is sent first and DMA starts after its response, as in the
manual's flow. A transfer is done once transfer complete (interrupt
bit 12) and DMA done (bit 13) have both arrived, in either order, and
`DMA_CFG` shows the engine idle. Multi-block transfers end with the
CMD12 that mmcsd supplies; R1b commands and single-block writes then
wait for DAT0 (`MSDC_PS` bit 16), checked every 1 ms.

Error bits: command timeout 9, response CRC 10, data timeout 14, data
CRC 15, DMA protection 19, AXI error 23.

### Timeouts

| Phase | Software deadline |
|---|---|
| Commands and reads | 10 s |
| Write data (from DMA start) | 30 s |
| Stop after a write | Another 30 s |
| Tuning reads | 100 ms |

The long write deadlines are there for slow cards; see the APPSD card
under [Pitfalls](#pitfalls). The hardware data timeout (`SDC_CFG` bits
31:24, units of 2^20 card clocks) is about 2 s, or its minimum during
tuning.

A stop error is copied to the main command, with `xfer_len` cleared,
because `mmcsd_rw()` checks only the main command. Otherwise a failed
stop would look like successful I/O.

### Error recovery

The driver logs the command and controller state, masks interrupts,
stops DMA, syncs and unloads the map, then resets the controller
(`MSDC_CFG` bit 2) and FIFO (`MSDC_FIFOCS` bit 31). If `DMA_STOP` does
not idle the engine within 10 ms, a controller reset follows. Only if
the engine is still active after that does the driver panic, since it
could still write to memory that is being handed back.

### Voltages and modes

Only `regulator-fixed` supplies are accepted: `vmmc` 3.3 V, `vqmmc`
3.3 V or 1.8 V. Nothing is switched. A request for 3.3 V signaling
always succeeds; 1.8 V is reported only when HS200 is enabled. HS200
needs the DT capability and a 1.8 V `vqmmc`; HS400 also needs
`hs400-ds-delay`. Supported timings: SD default and high speed; eMMC
high speed, HS200 and HS400.

### HS200 tuning

The command and data sample delays move together over 32 cells. At
each cell the driver issues CMD21 itself; a cell passes if the read has
no error and matches the JEDEC tuning block. The falling edge
(`MSDC_IOCON` bits 1, 2, 8) is swept only if the rising-edge window is
under 16 cells. The middle of the longest window must pass 8 more
reads. Tuned values apply only above 52 MHz. On our eMMC all 32 cells
pass on the rising edge at 104 MHz, and cell 16 is used.

### HS400 strobe tuning

In HS400 the data strobe clocks read data in. Before the HS200 sweep
the driver loads the DT `hs400-ds-delay` into `PAD_DS_TUNE` and sets
`EMMC50_CFG3` (0x220) OUTS_WR to 2, as MediaTek does; afterwards only
the command delay is kept.

FreeBSD's MMC layer has no hook after its switch to HS400, so the
strobe is tuned the first time update_ios runs in HS400 above 52 MHz.
The driver sweeps DLY1 (`PAD_DS_TUNE` bits 14:10, select bit 16) over
0-31 with EXT_CSD reads. A delay passes if its read has no error and
returns the contents most reads agree on (compared by hash). If fewer
than two reads agree, the DT value stays. Taking the first good read as
the reference was rejected: a misread with a valid CRC could become the
reference.

On our board 23 cells (9 to 31) pass, cell 20 is used, and
`PAD_DS_TUNE` ends at 0x15014, the same value Linux's tuning reaches on
this board.

### Retuning

A command or data CRC error above 52 MHz after a successful tuning sets
a retune request. The `RETUNE_REQ` ivar then always returns
`retune_req_reset`, because mmc.c ignores a non-reset retune in HS400.
The MMC layer switches HS400 to HS200, calls tune, switches back, and
the strobe sweep runs again. There is no periodic retuning.

Writing 1 to the sysctl `dev.mt7986_msdc.0.retune` forces one. The
same node has request, DMA, `errors`, `sw_timeouts` and `retunes`
counters, the real `clock_hz`, and the tuning results.

## Testing

A storage driver is judged by what it does to your data, so every
version started out cautious:

- New versions first booted with a read-only root and compared file and
  raw partition hashes with known values before any write. eMMC tests
  ran from a netbooted kernel with a memory-disk root, so nothing on
  the device was mounted, after a backup taken under Linux.
- Write workload: a 256 MiB file written with O_DIRECT, a distinct
  pattern in every 512-byte sector. Each of four rounds rewrites it,
  makes 512 random overwrites of 512 bytes to 512 KiB, and reads it all
  back. Persistence: reboot, mount read-only, verify, check that
  `dma_bytes` grew by the file size, then `fsck_ufs -fn`.
- Each version also ran against a userland model of the registers and
  card under ASan and UBSan (12,722 scenarios for the final version).

| Device and mode | Clock | Read | Workload |
|---|---|---|---|
| SanDisk 32 GB SDHC, high speed | 34.67 MHz, 4-bit | 16.5 MB/s | 237.8 s |
| eMMC high speed | 52 MHz, 8-bit | 40.7 MB/s | 94.2 s |
| eMMC HS200 | 104 MHz, 8-bit | 94 MB/s | 70.3 s |
| eMMC HS400 | 104 MHz DDR, 8-bit | 170.4 MB/s | 59.3 s |
| Linux 6.12, eMMC HS400 | 104 MHz DDR, 8-bit | 167.5 MB/s | not run |

The SD read figure is a 256 MiB file read from the card, close to the
17.3 MB/s a 4-bit bus at 34.67 MHz carries. The eMMC read figures are
1 GiB raw reads. The eMMC is a Kioxia 8 GB eMMC 5.1 (`008GB0`).

Other results, all with zero errors and zero software timeouts:

- **SD:** 11 warm reboots and a cold power cycle passed with the
  descriptor-DMA version, each cycle re-verifying all earlier files.
  The final driver repeated the workload (237.8 s, before 237.5 s).
- **SD erase:** an aligned 4 MiB delete sent CMD32, CMD33, CMD38 and
  read back zeros. An unaligned delete sent nothing; mmcsd erases only
  whole erase sectors (4 MiB on this card).
- **eMMC:** the whole 7.8 GB user area and both boot partitions matched
  hashes taken under Linux. Workloads and persistence passed in every
  mode. 9 forced retunes (8 under read load) all chose the same delays.
  TRIM works on exact sectors (CMD35, CMD36, CMD38). 10 netboot cycles
  and a cold power cycle each tuned the same and verified every file.
- **First series plus this commit only** (no pinctrl driver, firmware
  pin setup): SD and eMMC HS400 both passed.

## Pitfalls

- **The eMMC bus test write wedges the card under descriptor DMA.**
  `mmc_test_bus_width()` sends CMD19 BUSTEST_W (8 bytes) to every MMC
  card. Through descriptor DMA the data never left the controller: DMA
  stayed active with no interrupt and no hardware data timeout for
  30 s, and `DMA_STOP` did not stop it (a controller reset did). A
  smaller burst did not help, and we do not know why. The card then
  answered no command until a power cycle; CMD0 and a warm reboot did
  not recover it. The driver now sends this data by PIO through
  `MSDC_TXDATA` (0x18). That ends in a hardware data timeout,
  consistent with the card sending no CRC status, and the card stays
  usable. FreeBSD ignores the BUSTEST_W result and CMD14 picks the
  width. Linux and U-Boot do not send CMD19 here; they compare EXT_CSD
  instead.
- **Some SD cards take over 10 s to finish a write.** On a 16 GB card
  that identifies as APPSD, 4 KiB writes took up to 17.4 s, most about
  1.5 or 3 s, and CMD12 after a write stayed busy for over 10 s. During
  a stall the controller sat in the data phase with DAT0 low, DMA idle
  and no transfer-complete interrupt; the 2 s hardware data timeout
  does not cover this. A lower clock (20.8 MHz) did not help. A SanDisk
  card ran the same workload about 20 times faster (slowest write
  0.79 s), so for once it really was the card and not the driver. With
  30 s deadlines, a rewrite of all 64 UFS backup superblocks on the
  APPSD card passed (187 s).
- **The DT gives the SD slot a 1.8 V VQMMC too.** SD cards still use
  3.3 V signaling. The public schematics show SD_VDD and the bus
  switches on 3.3 V but do not settle the SoC pad supply. The driver
  switches nothing and does not enable UHS; the upstream SD overlay
  lists no UHS modes either.
- **`no-sd` is not enforced.** A boot with the eMMC overlay and switch
  D still at SD attached the SD card at 4-bit high speed.
- **The DT strobe value is only a start.** The DT gives 0x14014 (DLY1
  16); our sweep and Linux both end at 0x15014 (DLY1 20).
- **Misleading messages and counters.** The `mmcsd0` line prints the
  requested clock (50 or 200 MHz); `clock_hz` has the real one. The
  `mmc0` bus line lists the card's best timing ("HS400 with enhanced
  strobe" here), not the one in use. Each eMMC boot adds 13 expected
  probe failures to `errors` (four each of CMD8, CMD55 and CMD2, one
  CMD19), so compare deltas during I/O. Tuning probes are not counted.
- **Testing traps.** Without `options DIRECTIO`, a same-boot verify was
  served from the page cache even with O_DIRECT; reboot or watch
  `dma_bytes`. Opening the whole disk for writing with
  `kern.geom.debugflags=16` while a partition was mounted panicked an
  INVARIANTS kernel in GEOM ("spoiling cp->ace = 1"), not in the
  driver.

## Open items

- SD UHS-I (needs voltage switching and the board's pad wiring), SDIO
  interrupts, MMCCAM, suspend/resume, runtime power management.
- The BPI-R3 DT has no card detect or write protect GPIO, so the card
  is assumed present. Removal is untested.
- Untested: power loss during writes, the APPSD card with the
  descriptor-DMA or final driver, and flipping D from the eMMC back to
  the SD card under FreeBSD (SD to eMMC works, see above).
- Erase and other data-less R1b commands get the 10 s deadline; the
  legacy request API passes no per-command busy timeout. Our erase and
  TRIM tests finished in under 1 s.

## References

- MT7986A Reference Manual for BPI-R3, v1.0, section 2.3, MMC and SD
  Controller. Distributed by Banana Pi:
  <https://wiki.banana-pi.org/Banana_Pi_BPI-R3>
- Linux v6.12 `drivers/mmc/host/mtk-sd.c`, hardware reference only:
  <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/mmc/host/mtk-sd.c?h=v6.12>
- U-Boot v2025.10 `drivers/mmc/mtk-sd.c`, hardware reference only:
  <https://source.denx.de/u-boot/u-boot/-/blob/v2025.10/drivers/mmc/mtk-sd.c>
- `sys/contrib/device-tree/Bindings/mmc/mtk-sd.yaml`; `mt7986a.dtsi`
  and the BPI-R3 DTS and overlays in
  `sys/contrib/device-tree/src/arm64/mediatek/`.
- `sys/dev/mmc/mmc.c`, `mmcsd.c`, `mmc_subr.c`, `mmcbr_if.m`.
- JEDEC eMMC standard (JESD84-B51): CMD21 tuning block pattern.
- BPI-R3 schematic, linked from
  <https://docs.banana-pi.org/en/BPI-R3/BananaPi_BPI-R3>; SD/eMMC mux
  excerpt:
  <https://forum.banana-pi.org/t/bpi-r3-what-is-sd-emmc-sel-connected-to/14976>
- DIP switch settings:
  <https://forum.banana-pi.org/t/banana-pi-r3-how-to-flash-nor-nand-or-emmc-from-the-sd-cards-bootmenu/19719>

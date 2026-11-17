# Clocks, resets and SoC support

The MT7986 spreads its clock tree over three controllers: APMIXEDSYS
(the PLLs), TOPCKGEN (fixed dividers and top-level muxes) and INFRACFG
(peripheral muxes, gates and software resets). FreeBSD gets one common
MediaTek clock and reset base driver plus one table file per controller.

The drivers read the clock state the boot firmware left, gate and
reparent clocks, set PLL rates, and implement the INFRACFG resets. TF-A
sets the PLLs up before FreeBSD is even loaded, and so far no driver has
found a reason to argue with it, but the option is there.

## Status

The clock and reset drivers are in review on Phabricator, together with
the SoC skeleton. The UART driver, which completes this first series, is
described in [uart.md](uart.md). The same series, rebased on current
FreeBSD main, is the branch `bpi-r3/golden` of
<https://github.com/AlchemillaHQ/freebsd-src>; all other feature
branches sit on top of it.

| Review | Subject |
|---|---|
| [D61186](https://reviews.freebsd.org/D61186) | arm64: Add MediaTek SoC support skeleton |
| [D61187](https://reviews.freebsd.org/D61187) | clk/mediatek: Add common MediaTek clock and reset support |
| [D61188](https://reviews.freebsd.org/D61188) | clk/mediatek: Add MT7986 APMIXEDSYS PLL controller |
| [D61189](https://reviews.freebsd.org/D61189) | clk/mediatek: Add MT7986 TOPCKGEN clock controller |
| [D61190](https://reviews.freebsd.org/D61190) | clk/mediatek: Add MT7986 INFRACFG clock and reset controller |

The series was reworked in mid-November 2026 after the first review
feedback, which arrived on the UART and asked, among other things, for
set/clear registers to be the exception rather than the rule. This note
describes the reworked code. Every commit builds on its own. With the
first series alone (these five plus the UART), arm64 `GENERIC` boots on
the BPI-R3 with the stock DTB to `mountroot>`, with a working console.

The ETHSYS and SGMIISYS clock controllers, and a gate type they need,
live on the `bpi-r3/ethernet` branch (see [ethernet.md](ethernet.md)).

## Hardware

The reference manual does not document any of these three controllers,
so the facts below were collected the traditional way: from MediaTek's
TF-A (BSD licensed), the Linux and U-Boot drivers and MediaTek's SDK
(GPL, used for facts only), and from measurements on the board. Where
the sources disagree, we say which one we followed and why.

| Node | Compatible | Provides |
|---|---|---|
| `apmixedsys@1001e000` | `mediatek,mt7986-apmixedsys` | PLLs |
| `topckgen@1001b000` | `mediatek,mt7986-topckgen`, `syscon` | dividers, muxes |
| `infracfg@10001000` | `mediatek,mt7986-infracfg`, `syscon` | muxes, gates, resets |

None of these nodes has child nodes, so no driver has to be both a bus
and a clock provider. The clock ids are in
`sys/contrib/device-tree/include/dt-bindings/clock/mt7986-clk.h`. The
APMIXEDSYS binding has no `clocks` property, so the 40 MHz crystal is
found by name (`clkxtal`).

### APMIXEDSYS PLLs

Each PLL has a block of registers at its own offset:

| Offset | Register | Contents |
|---|---|---|
| +0x0 | CON0 | bit 0 enable, bits 6:4 post divider (log2), bit 24 reset bar |
| +0x4 | CON1 | PCW, all 32 bits: 7 integer bits, 25 fractional bits |
| +0x8 | CON2 | follows CON1 when CON1 is written (the register, not the rate in use) |
| +0xc | PWR | bit 0 power on, bit 1 isolation enable |

MPLL and APLL2 are the exception: their PWR register sits at +0x10. The
output rate is

    rate = 40 MHz * PCW / 2^25 / 2^postdiv

The rates below are the ones firmware leaves, decoded from the
registers. They match the BL2 boot log for ARMPLL and Linux's clock
summary on the same board.

| PLL | CON0 offset | Rate |
|---|---|---|
| ARMPLL | 0x200 | 2000 MHz |
| NET2PLL | 0x210 | 800 MHz |
| MMPLL | 0x220 | 1440 MHz |
| SGMPLL | 0x230 | 325 MHz |
| WEDMCUPLL | 0x240 | 760 MHz |
| NET1PLL | 0x250 | 2500 MHz |
| MPLL | 0x260 | 416 MHz |
| APLL2 | 0x278 | about 196.6 MHz |

The enable sequence follows TF-A: set power on, wait 1 us, clear
isolation, wait 1 us, set enable, wait 20 us, then set the reset bar on
the PLLs that have one. Disabling runs the same steps in reverse.

Three facts about these PLLs are in no source we found. They were
measured on APLL2, which nothing uses, with the frequency meter
described below:

- A new PCW is only taken over when the PLL is enabled. Written to a
  running PLL it appears in CON2 at once and changes nothing else; the
  output moves when the enable bit is cleared and set again.
- The post divider takes effect at once. Values 0 to 4 divide by 1 to
  16; values 5 to 7 give no usable clock.
- The VCO followed the PCW from 1000 to 3800 MHz, the highest we tried.
  Firmware's own settings use 1520 to 2880 MHz.

### TOPCKGEN

TOPCKGEN has fixed dividers of the PLL outputs and 37 muxes. The muxes
sit in `CLK_CFG_n` registers, 0x10 apart, with four 8-bit fields per
register. Each field holds the selection in its low bits and a gate bit
in bit 7 (set means gated). The registers can be written directly; there
are set and clear registers at +4 and +8 as well. A new selection takes
effect only after its bit is written to one of the two update registers,
0x1c0 and 0x1c4. The gate bit works without that.

### Frequency meter

TOPCKGEN also contains a frequency meter. TF-A uses it for one line of
its boot log, the CPU speed, and no document or driver says what else it
can measure. It can measure the output of every TOPCKGEN mux, which
makes it the most useful undocumented block on the chip.

| Offset | Use |
|---|---|
| 0x200 | cleared while measuring, restored afterwards (as TF-A does) |
| 0x240 | input select: bits 1:0 = 1 and bits 13:8 = n pick the output of the n-th mux, counted from 1 in `CLK_CFG` order |
| 0x324 | bits 25:16: window in crystal cycles, minus one; bits 15:0: the count |
| 0x320 | writing 0x1010 starts a measurement; bit 4 clears when it is done |

With the longest window, 1024 cycles of the 40 MHz crystal, one count is
about 39 kHz. A clock that is stopped or gated never finishes the
measurement, which is a result too. The input numbering was found by
scanning every input and matching the rates, then confirmed by switching
muxes and watching the right input follow.

### INFRACFG

- Muxes: single fields in `MODULE_CLK_SEL_0` (0x10) and
  `MODULE_CLK_SEL_1` (0x20). Set register at the base, clear at +4,
  status at +8. No gate or update bits.
- Gates: three banks at 0x40, 0x50 and 0x60. Set (gate) at the base,
  clear (ungate) at +4, status at +8.
- The mux and gate status registers are read-only: a direct write
  changes nothing (measured). Set and clear are the only way in.
- Software resets: three banks. Assert at the base, deassert at +4,
  status at +8. Reset id n is bit n % 32 of bank n / 32.

| Bank | Offset | Binding ids | Source |
|---|---|---|---|
| 0 | 0x70 | 6, 7, 8, 13, 14, 17 | TF-A (TRNG reset) |
| 1 | 0x80 | 32 to 39, 43 | found and verified on the board |
| 2 | 0x90 | 66, 68 | found and verified on the board |

No Linux or MediaTek SDK driver implements MT7986 INFRACFG resets. The
SDK's MT7987 and MT7988 drivers use a 0x10 stride between banks, which
agrees with what we found.

## FreeBSD driver

### SoC skeleton

- `sys/arm64/conf/std.mediatek`: options `SOC_MEDIATEK` and
  `SOC_MEDIATEK_MT7986`, `FDT`, the ns8250 UART, and the DTB module.
- `sys/arm64/conf/GENERIC` includes `std.mediatek`, and `NOTES` lists
  the two options, so `LINT` builds the drivers too.
- `sys/arm64/conf/MEDIATEK` is a kernel configuration with only the
  MediaTek parts, like the ones the other SoC families have.
- `sys/modules/dtb/mediatek/Makefile` builds the stock
  `mt7986a-bananapi-bpi-r3.dts`.
- Drivers are selected in `sys/conf/files.arm64` with
  `optional fdt soc_mediatek`. There is no `#ifdef SOC_...` in the code.

### Common code

Files in `sys/dev/clk/mediatek/`:

| File | Role |
|---|---|
| `mtk_clk.h`, `mtk_clk.c` | base driver class, table macros, resets |
| `mtk_clk_pll.c` | PLL node, with the MT7986 register layout |
| `mtk_clk_mux.c` | mux written directly or through set/clear registers, optional gate and update bits |
| `mtk_clk_gate.c` | gate with set, clear and status registers |
| `mt7986_apmixedsys.c`, `mt7986_topckgen.c`, `mt7986_infracfg.c` | tables and probe |

The layout follows `sys/dev/clk/rockchip`. The base class owns the
register resource, a mutex and the clock domain, and implements the
`clkdev` register and lock methods. Each controller derives from it with
`DEFINE_CLASS_1` and supplies nothing but a table.

- Fixed clocks and fixed-factor dividers use the generic `clk_fixed`.
- Clocks of another controller are `clk_link` nodes, so lookups do not
  depend on registration order.
- The mux and gate are our own node types. TOPCKGEN's muxes need the
  update latch, and INFRACFG's muxes and gates can only be changed
  through set/clear registers; the generic `clk_mux` and `clk_gate` can
  express neither.
- A PLL table entry has only its CON0 offset, its PWR offset and its
  reset bar mask; the rest of the layout is in `mtk_clk_pll.c`.

### Design decisions

- **Critical clocks.** `CLK_NODE_CANNOT_STOP` keeps only the node itself
  from being gated, not its parents. So the base driver also takes one
  enable reference on each such clock at attach and never releases it.
  If it cannot take one it panics, since another consumer could then
  stop a clock the system runs on. The critical clocks are
  ARMPLL, `dramc_sel`, `dramc_md32_sel`, `sysaxi_sel`, `sysapb_sel`,
  `sgm_reg_sel`, `csw_f26m_sel`, and the two SEJ gates (`infra_sej`,
  `infra_sej_13m`), which OP-TEE uses; MediaTek's SDK marks them
  critical for that reason.
- **Attach order.** The reference only reaches the parents if they are
  registered. The fixed clocks (`clk_fixed`, which provides the crystal)
  attach at `BUS_PASS_BUS + BUS_PASS_ORDER_MIDDLE`, then APMIXEDSYS at
  +1, TOPCKGEN at +2 and INFRACFG at +3.
- **Registration failures panic**, naming the clock. Registered nodes
  cannot be removed once others reference them. A mux selection that the
  table does not describe panics in the framework when the node is
  initialized, as it does for the Rockchip muxes.
- **Muxes are written directly where the hardware allows it.**
  TOPCKGEN's mux registers are ordinary read-write registers, so a
  change is one read-modify-write plus the update bit. INFRACFG's status
  registers are read-only, so its muxes and gates go through set and
  clear. An earlier version used set/clear everywhere, as Linux does;
  review asked for plain register writes where the hardware allows them.
- **PLL rates can be set.** A request picks the smallest post divider
  that keeps the VCO between 1500 and 3000 MHz, the rule all eight of
  firmware's settings follow, and then the nearest PCW. With 25
  fractional bits that lands within about 1 Hz, so rounding up or down
  only means taking the neighbouring PCW. A running PLL is stopped,
  programmed and started again, because that is the only way the
  hardware takes a new PCW. ARMPLL cannot stop, so it accepts only the
  rate it already has; changing it needs the CPU moved to another clock
  first. The clock framework already refuses to change a clock that
  several consumers have enabled. There is no datasheet for the VCO
  limits: they are firmware's range, and the measured range is wider.
- **Reparent while disabled.** The framework does not move enable
  references when a mux changes parent. Consumers should reparent a clock
  while it is off; the UART driver does.
- **Resets.** Only INFRACFG registers a reset provider, as the binding
  requires `#reset-cells` there. Any id within the three banks is
  accepted. The driver keeps no list of the binding's 17 ids: they come
  from the device tree.
- **SPI1 clock selection.** `infra_spi1_sel` selects between `i2c_sel`
  and `spim_mst_sel`. Linux's MT7986 table uses `spi_sel`. MediaTek's
  SDK, the `sel-clk` of `spi1` in the DTS, and Linux's MT7981 driver for
  the same field all say `spim_mst_sel`.
- **`top_jtag`** is the external JTAG clock input. Its rate is nominal,
  as in Linux; it only feeds a debug mux.
- **syscon deferred.** TOPCKGEN and INFRACFG are also `syscon`, but no
  MT7986 node uses them that way. The drivers match the specific
  compatible, so `syscon_generic` does not take the nodes. A syscon
  interface will come with its first consumer, and must share the clock
  driver's mapping and lock.

## Boot contract

FreeBSD arrives after the firmware has done the hard part, and the
drivers rely on it for exactly this:

- TF-A BL2 sets up every PLL and leaves the CPU, bus and DRAM clocks
  running. FreeBSD leaves the rates alone unless a consumer asks for
  another one.
- The console UART's clock selection and baud rate are kept as firmware
  set them (see [uart.md](uart.md)).
- Pin multiplexing stays as firmware set it until there is a pinctrl
  driver (see [pinctrl.md](pinctrl.md)).

Everything else is set up by FreeBSD: peripheral gates and muxes,
resets, and the clocks of the other UARTs. The PLL code decides whether
a PLL runs from the CON0 enable bit alone. It does not detect or repair
a PLL that firmware left partly initialized.

## Testing

Setup: BPI-R3 booting from SD, OpenWrt's TF-A v2.13 and U-Boot 2025.10,
arm64 `GENERIC` with the series, stock DTB. Most tests used a kernel
with a test-only hook (not part of the series) that enables, disables
and reparents clocks, asserts resets through hwreset(9), and reads and
writes registers through a kernel device mapping (`pmap_mapdev()`).
The frequency meter and PLL rate tests came later and ran on a board
with the image our CI builds.

- **Clock tree against Linux.** `sysctl hw.clock` was compared with
  `/sys/kernel/debug/clk/clk_summary` from OpenWrt on the same board.
  123 clocks match in rate and parent. Six differ, as expected:
  `spim_mst_sel` (Linux reparents it at runtime for SPI1), `top_jtag`
  (Linux models it with a dummy parent), `infra_spi1_sel` and
  `infra_spi1` (our SPI1 parent), and `top_net2pll_d3_d2` with
  `arm_db_main_sel` below it, where Linux's divider is wrong (see
  Pitfalls). The only Linux clocks missing are the 13 ETHSYS and
  SGMIISYS ones, which are not in this series.
- **Every mux output, measured.** The frequency meter read all 37
  TOPCKGEN mux outputs, and the rates were compared with
  `sysctl hw.clock`. 36 agree. The other one has no clock at all:
  `arm_db_jtsel` selects the external JTAG clock, and nobody was
  driving it. One of the 36, `ap2cnn_host_sel`, agrees only after its
  first enable (see Pitfalls). This is the test that caught the
  `net2pll_d3_d2` divider.
- **Write paths.** Gating `infra_pwm2` (CG0 bit 4) also gated its parent
  mux `pwm_sel` (CLK_CFG_1 bit 15); NET1PLL, held by a critical clock,
  stayed on. `a1sys_sel` switched parents through the update latch
  (CLK_CFG_5 bit 24) and its gate bit 31 toggled. APLL2 and WEDMCUPLL
  powered down and up: enable, power, isolation and WEDMCUPLL's reset bar
  were cleared and restored, and the rates were unchanged.
- **PLL rates.** APLL2 was set to other rates through the test hook and
  measured with the frequency meter: 200 MHz (same post divider),
  180.6336 MHz (divide by 16) and 1600 MHz (divide by 1) all came out as
  requested, with the PLL running and with it stopped. Rounding up, down
  and to nearest picks the expected neighbour. Requests outside 93.75
  MHz to 3 GHz fail with `ERANGE` unless the rounding points back into
  the range, and dry runs leave the registers alone. The same on
  WEDMCUPLL, which has a reset bar, on a boot without the Ethernet
  driver so that nothing else held it. ARMPLL refuses any rate but its
  own, and a PLL with several consumers is refused by the framework.
- **PLL arithmetic on the host.** The rate-setting functions, compiled
  unmodified against a model of the measured register behaviour, pass
  three million random requests: rounding direction, range limits, dry
  runs, error paths, and the rule that the PCW is never written while
  the PLL runs.
- **Critical clocks** each hold one enable reference, which reaches
  their PLLs. "Unresolved linked clock" is never printed.
- **Resets.** UART1 (id 38) and UART2 (id 39): with the port programmed,
  assert and deassert returned its registers to their reset values, and
  the port worked again after reattaching. I2C (id 33): two written
  registers returned to their reset values and could be written again;
  no I2C transfer was tried. PWM (id 68): a written register returned to
  its reset value. The status register showed exactly the asserted bit.
  An id beyond the three banks is rejected with `EINVAL`.

## Pitfalls

- **Register access from userland.** On arm64 FreeBSD, `mmap` of
  `/dev/mem` maps device registers as normal cacheable memory. Reads
  were stale, writes reached the device as cache line write-backs, and a
  CPU stalled on the UART. Early results taken this way were wrong (an
  I2C block that seemed not to recover from reset). Use a kernel device
  mapping for register experiments.
- **The reset bar is CON0 bit 24**, as in TF-A, not bit 27 as in Linux.
  MediaTek's SDK defines bit 27 but flags no PLL with it. TF-A sets bit
  24 on NET2PLL, MMPLL, WEDMCUPLL, NET1PLL and MPLL, and the boot state
  matches exactly.
- **CON1 bit 31 is part of the PCW**, not a "PCW change" strobe as on
  older MediaTek SoCs. MMPLL and SGMPLL run with it set. Linux's PLL
  code writes a new PCW and then sets bit 31 as a change bit. On MT7986
  that bit is the PCW's top bit, and a running PLL takes no new PCW at
  all (see Hardware), so that path cannot work here.
- **CON2 is not a status register.** It follows CON1 the moment CON1 is
  written, whatever the PLL is actually doing, so it says nothing about
  the rate in use. It looks like a readback of the PLL. It is a mirror.
- **PWR bit 31** reads 1 while a PLL runs and 0 while it is off. It did
  not drop when APLL2's PCW was changed at runtime. It is undocumented,
  so the driver does not use it as a lock indicator.
- **`top_net2pll_d3_d2` divides by 6**, as its name says. Linux and
  U-Boot have 2, and so did our table until the frequency meter read
  133.3 MHz where 400 MHz was expected, through two different muxes.
  Agreement with Linux's clock summary had proved nothing, since both
  sides used the same table. A clock name is a hint, not a contract, but
  this time the hint was right.
- **A mux register holds the pending selection.** After boot,
  `ap2cnn_host_sel` reads as parent 1 while its output is still parent
  0: firmware wrote the field and never the update bit. The first enable
  or parent change through the driver latches it. Nothing uses this
  clock, which is presumably how it stayed that way.
- **Do not touch a peripheral whose clocks are gated.** A write to a PWM
  register after gating the PWM clocks never completed, and the kernel
  panicked a moment later. Enable first, then poke.
- **The architected timer** runs at 12,986,200 Hz while firmware's
  CNTFRQ says 13 MHz, about 1062 ppm off. On our board ntpd pinned its
  correction at +500 ppm. A DTB `clock-frequency` override would fix it;
  the series does not carry one.
- **Firmware-owned blocks.** Like SEJ, the TRNG belongs to firmware;
  OpenWrt reaches it through SMC calls. No FreeBSD consumer can gate its
  clock today, so it is not marked critical.

## Open items

- Changing ARMPLL's rate needs the CPU moved to another clock first;
  that belongs with cpufreq.
- The VCO limits are firmware's range, not a documented one.
- SPI1's output rate is computed (40 MHz with firmware settings), not
  measured. That needs an SPI driver.
- The syscon interface of TOPCKGEN and INFRACFG.
- Timer frequency: carry a DTB override or not.
- Other MediaTek SoCs only need new table files, but none is done yet.

## References

- MT7986A Reference Manual for BPI-R3, v1.0, and MT7986A Datasheet v1.15,
  distributed by Banana Pi:
  https://wiki.banana-pi.org/Banana_Pi_BPI-R3
- MediaTek TF-A, `plat/mediatek/mt7986/drivers/pll/pll.c` and `pll.h`:
  https://github.com/mtk-openwrt/arm-trusted-firmware/tree/a229810586d8
- Linux `drivers/clk/mediatek/clk-mt7986-apmixed.c`,
  `clk-mt7986-topckgen.c`, `clk-mt7986-infracfg.c`,
  `clk-mt7981-infracfg.c` and `clk-pll.c` (v7.1):
  https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/clk/mediatek?h=v7.1
- U-Boot `drivers/clk/mediatek/clk-mt7986.c` (v2025.10):
  https://source.denx.de/u-boot/u-boot/-/blob/v2025.10/drivers/clk/mediatek/clk-mt7986.c
- MediaTek SDK feed, `21.02/.../clk-mt7986.c` and the 25.12 patch
  `999-clk-05-clk-mediatek-mt7986-mark-sej-clks-as-critical.patch`:
  https://github.com/mediatek/mtk-openwrt-feeds/tree/f185b9c74f1d
- DT bindings in tree: `sys/contrib/device-tree/Bindings/clock/` and
  `sys/contrib/device-tree/include/dt-bindings/`.

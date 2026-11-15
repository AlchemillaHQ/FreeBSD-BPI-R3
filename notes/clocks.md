# Clocks, resets and SoC support

The MT7986 spreads its clock tree over three controllers: APMIXEDSYS
(the PLLs), TOPCKGEN (fixed dividers and top-level muxes) and INFRACFG
(peripheral muxes, gates and software resets). FreeBSD gets one common
MediaTek clock and reset base driver plus one table file per controller.

The drivers read the clock state the boot firmware left, gate and
reparent clocks, and implement the INFRACFG resets. They do not change
PLL rates. TF-A programs those before FreeBSD is even loaded, and so far
nobody has found a good reason to argue with it.

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

As of 8 November 2026 these five had no review comments. Every commit
builds on its own. With the first series alone (these five plus the
UART), arm64 `GENERIC` boots on the BPI-R3 with the stock DTB to
`mountroot>`, with a working console.

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
| +0x8 | CON2 | follows CON1 when CON1 is written |
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

### TOPCKGEN

TOPCKGEN has fixed dividers of the PLL outputs and 37 muxes. The muxes
sit in `CLK_CFG_n` registers, 0x10 apart, with four 8-bit fields per
register. Each field holds the selection in its low bits and a gate bit
in bit 7 (set means gated). Writes go through set and clear registers at
+4 and +8. A new selection takes effect only after its bit is written to
one of the two update registers, 0x1c0 and 0x1c4.

### INFRACFG

- Muxes: single fields in `MODULE_CLK_SEL_0` (0x10) and
  `MODULE_CLK_SEL_1` (0x20). Set register at the base, clear at +4,
  status at +8. No gate or update bits.
- Gates: three banks at 0x40, 0x50 and 0x60. Set (gate) at the base,
  clear (ungate) at +4, status at +8.
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
- `sys/arm64/conf/GENERIC` includes `std.mediatek`.
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
| `mtk_clk_mux.c` | mux with set/clear registers, optional gate and update bits |
| `mtk_clk_gate.c` | gate with set, clear and status registers |
| `mt7986_apmixedsys.c`, `mt7986_topckgen.c`, `mt7986_infracfg.c` | tables and probe |

The layout follows `sys/dev/clk/rockchip`. The base class owns the
register resource, a mutex and the clock domain, and implements the
`clkdev` register and lock methods. Each controller derives from it with
`DEFINE_CLASS_1` and supplies nothing but a table.

- Fixed clocks and fixed-factor dividers use the generic `clk_fixed`.
- Clocks of another controller are `clk_link` nodes, so lookups do not
  depend on registration order.
- The mux and gate are our own node types. The hardware uses set/clear
  registers and the TOPCKGEN update latch, which the generic `clk_mux`
  and `clk_gate` cannot express.
- A PLL table entry has only its CON0 offset, its PWR offset and its
  reset bar mask; the rest of the layout is in `mtk_clk_pll.c`.

### Design decisions

- **Critical clocks.** `CLK_NODE_CANNOT_STOP` keeps only the node itself
  from being gated, not its parents. So the base driver also takes one
  enable reference on each such clock at attach and never releases it.
  Without that reference the system panics. The critical clocks are
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
  table does not describe counts as a failure, because the framework has
  no parentless clocks. Mux fields are validated at registration (shift
  and width within 31 bits, parent count fits the field).
- **PLL rates are fixed.** `set_freq` accepts the current rate, or a
  rounding request that the current rate satisfies, and returns `ERANGE`
  otherwise. Either way the request stops there. The default method
  would pass it on to the parent and report success without changing
  anything. Runtime PLL rate changes are deferred: no consumer needs one
  yet, and the latch procedure on MT7986 is unknown (see Pitfalls).
- **Reparent while disabled.** The framework does not move enable
  references when a mux changes parent. Consumers should reparent a clock
  while it is off; the UART driver does.
- **Resets.** Only INFRACFG registers a reset provider, as the binding
  requires `#reset-cells` there. Only the 17 ids in
  `dt-bindings/reset/mt7986-resets.h` are accepted; any other id gets
  `EINVAL`, since the other bits are not documented.
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

- TF-A BL2 programs every PLL rate (PCW and post divider) and leaves the
  CPU, bus and DRAM clocks running. FreeBSD only gates PLLs and never
  reprograms them.
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

- **Clock tree against Linux.** `sysctl hw.clock` was compared with
  `/sys/kernel/debug/clk/clk_summary` from OpenWrt on the same board.
  125 clocks match in rate and parent. Four differ, as expected:
  `spim_mst_sel` (Linux reparents it at runtime for SPI1), `top_jtag`
  (Linux models it with a dummy parent), and `infra_spi1_sel` and
  `infra_spi1` (our SPI1 parent). The only Linux clocks missing are the
  13 ETHSYS and SGMIISYS ones, which are not in this series.
- **Write paths.** Gating `infra_pwm2` (CG0 bit 4) also gated its parent
  mux `pwm_sel` (CLK_CFG_1 bit 15); NET1PLL, held by a critical clock,
  stayed on. `a1sys_sel` switched parents through the update latch
  (CLK_CFG_5 bit 24) and its gate bit 31 toggled. APLL2 and WEDMCUPLL
  powered down and up: enable, power, isolation and WEDMCUPLL's reset bar
  were cleared and restored, and the rates were unchanged.
- **Rate requests.** APLL2 to 40 MHz and `top_apll2_d4` to 10 MHz fail
  with `ERANGE`; APLL2 at its current rate succeeds.
- **Critical clocks** each hold one enable reference, which reaches
  their PLLs. "Unresolved linked clock" is never printed.
- **Resets.** UART1 (id 38) and UART2 (id 39): with the port programmed,
  assert and deassert returned its registers to their reset values, and
  the port worked again after reattaching. I2C (id 33): two written
  registers returned to their reset values and could be written again;
  no I2C transfer was tried. PWM (id 68): a written register returned to
  its reset value. The status register showed exactly the asserted bit.
  Id 5 is rejected with `EINVAL`.
- **Mux validation** was checked in a host harness built from the source
  under UBSan: an undescribed selector gives `ENXIO`, width 31
  registers, and width 32 and a wrapping shift give `EINVAL`.

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
  older MediaTek SoCs. MMPLL and SGMPLL run with it set. On the unused
  APLL2, a written bit 31 stays set and CON2 follows CON1 at once.
  Linux's PLL code sets bit 31 as a change bit after a new PCW, which on
  MT7986 overlaps the PCW. We suspect Linux's rate-setting path is wrong
  here but have not reproduced a failure. How a new PCW is latched, and
  whether the loop relocks without an enable toggle, is unknown. The
  next step is to measure APLL2's output and settling after a controlled
  PCW change.
- **PWR bit 31** reads 1 while a PLL runs and 0 while it is off. It did
  not drop when APLL2's PCW was changed at runtime. It is undocumented,
  so the driver does not use it as a lock indicator.
- **`top_net2pll_d3_d2` divides by 2** in Linux, U-Boot and our table,
  although its name and an older MediaTek SDK suggest 6. A clock name is
  a hint, not a contract. Agreement with Linux's clock summary proves
  nothing here, since both use the same table. TF-A has frequency meter
  code, but it ignores its selector and overwrites a bus PLL divider, so
  it is not a usable recipe.
- **The architected timer** runs at 12,986,200 Hz while firmware's
  CNTFRQ says 13 MHz, about 1062 ppm off. On our board ntpd pinned its
  correction at +500 ppm. A DTB `clock-frequency` override would fix it;
  the series does not carry one.
- **Firmware-owned blocks.** Like SEJ, the TRNG belongs to firmware;
  OpenWrt reaches it through SMC calls. No FreeBSD consumer can gate its
  clock today, so it is not marked critical.

## Open items

- Runtime PLL rate changes, when a consumer (cpufreq, audio) needs them
  or review asks for them.
- The `net2pll_d3_d2` ratio (/2 or /6).
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

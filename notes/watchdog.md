# Watchdog and TOPRGU resets

TOPRGU, the MT7986 top reset generation unit, holds three things: the
system watchdog timer, a reset status register, and a software reset
register for nine subsystems. The FreeBSD driver `mt7986_wdt` provides
`watchdog(4)` on top of the timer and a `hwreset` provider for the
subsystem resets. On the BPI-R3 a deliberately starved 20-second
watchdog resets the board, and the boot firmware reports a watchdog
reset. This is one of the few drivers where the board rebooting by
itself counts as a passing test.

## Status

| Part | State |
|---|---|
| Timeout programming, feeding, disable | Works |
| Reset on expiry | Works (20 s test) |
| `hwreset` provider, nine reset lines | Host-tested; no live consumer yet |
| Pretimeout interrupt (GIC SPI 110) | Not implemented |
| DT `timeout-sec`, suspend and resume | Not implemented |

The driver is `sys/arm64/mediatek/mt7986_wdt.c`, plus
`device mt7986_wdt` in `sys/arm64/conf/std.mediatek` and one line in
`sys/conf/files.arm64`. It sits on top of the first series in review
(D61186 to D61191; the same series rebased on current FreeBSD main is
branch `bpi-r3/golden`) and does not depend on any other feature branch. It has
not been posted for review yet; the code is on branch
`bpi-r3/watchdog` of <https://github.com/AlchemillaHQ/freebsd-src>.

## Hardware

### Registers

TOPRGU is at `0x1001c000` (size `0x1000`), compatible
`mediatek,mt7986-wdt`, with `#reset-cells = <1>` and GIC SPI 110 (level
high) for the optional watchdog interrupt. The SoC `.dtsi` disables it
and the BPI-R3 DTS enables it. The manual describes the block in
section 1.2.

| Register | Offset | Fields used |
|---|---|---|
| MODE | `0x00` | Key `0x22` in 31:24; enable bit 0, external reset bit 2, IRQ bit 3, dual mode bit 6, counter reset select bit 8 |
| LENGTH | `0x04` | Length in 15:5 (11 bits); key `0x08` in the low bits |
| RESTART | `0x08` | Write `0x1971` to reload the counter |
| STA | `0x0c` | Bit 31 watchdog reset, bit 30 software reset; read only |
| SWSYSRST | `0x18` | Key `0x88` in 31:24; bits 23:0 are reset lines, 1 asserts |
| SWRST_SEN | `0xfc` | Listed in the manual; not used |

Every write to MODE, LENGTH and SWSYSRST must carry its key. On a read,
the key byte of MODE and SWSYSRST comes back as zero, so a
read-modify-write has to put the key back in. The block will happily
tell you what a register holds, but never its password.

### Timing

The counter loads `{length[10:0], 9'b111111111}`, so one length unit is
512 ticks of the watchdog clock. Linux and U-Boot treat that as 64
units per second, which assumes a 32.768 kHz clock. The full range is
then 1/64 s to 2047/64 = 31.984375 s. The nine low bits loaded as ones
add almost one more unit to every timeout.

Which clock actually feeds TOPRGU has not been established. TOPCKGEN
has a 32 kHz clock (40 MHz / 1250); if TOPRGU ran from it, every
timeout would be about 2.4 % longer, but nothing shows that it does.

### Reset lines

From `dt-bindings/reset/mt7986-resets.h`:

| ID | Subsystem | ID | Subsystem |
|---|---|---|---|
| 0 | APMIXEDSYS | 6 | PCIe |
| 1 | SGMII0 | 7 | SSUSB |
| 2 | SGMII1 | 20 | ETHDMA |
| 3 | INFRA | 23 | CONSYS (Wi-Fi) |
| 5 | U2PHY | | |

The other bits are reserved. In the stock DTS only the Wi-Fi node uses
a TOPRGU reset (CONSYS). On our board SWSYSRST reads `0x00800000` after
boot: CONSYS is held in reset and nothing else is.

### Use by the boot firmware

FreeBSD is not the first software on the board to touch this block.
TF-A's BL2 prints the reset reason from STA (`WDT: Cold boot` after
power-on, `WDT: [80000000] Watchdog timeout` after a watchdog reset)
and disables any watchdog it inherits. BL31 implements PSCI system
reset with the TOPRGU software reset, so a normal FreeBSD reboot also
goes through this block.

## FreeBSD driver

### Attach

The driver attaches at `BUS_PASS_BUS` (order last), before ordinary
peripherals, so the reset provider exists by the time consumers look
for it.

Attach maps the one register window and checks its size, reads the
`mediatek,disable-extrst` and `mediatek,reset-by-toprgu` DT properties,
stops any timer the firmware left running, registers a
`watchdog_sbt_list` handler, and registers as a `hwreset` OFW provider.
It never arms the timer itself; userland arms it through `watchdog(4)`.

### Arming and feeding

Each arm or feed request:

1. Stops the current timer, so a request the hardware cannot honor
   leaves the watchdog off rather than running with the old timeout.
2. Stops there for a zero timeout (disable), for a timeout above
   31.984375 s, or once shutdown has begun. In that case it leaves the
   shared error value alone, so another provider's result is kept; on
   this board an over-long request fails with `EOPNOTSUPP`.
3. Rounds the timeout up to whole units, writes LENGTH, then RESTART.
4. Writes MODE with enable set, IRQ and dual mode clear, external reset
   set unless `mediatek,disable-extrst` is present, and bit 8 set if
   `mediatek,reset-by-toprgu` is present. Other MODE bits (reset
   polarity, pulse width) are preserved.
5. Reports the rounding in `error_sbt`. This is the nominal length
   quantization only, not clock tolerance.

The driver uses the SBT interface because the older interface expresses
timeouts only as powers of two nanoseconds, which in this range means
about 1, 2, 4, 8 or 17 s.

### Resets

`hwreset_map` accepts one cell naming one of the nine valid IDs and
refuses reserved bits. Assert and deassert do a read-modify-write of
SWSYSRST that keeps the other 23 low bits and replaces the key byte.
`hwreset_is_asserted` reads the bit back.

### Locking, shutdown and detach

A spin mutex covers both the watchdog and the reset register, and each
MMIO write is followed by a write barrier. Shutdown stops the timer and
refuses any later arming. Detach returns `EBUSY`, because the reset
framework does not track consumer handles. The driver does not register
a system reset handler, so PSCI stays the reboot path. It does not
allocate SPI 110 and leaves IRQ and dual mode off.

### Using it

Run `watchdogd` with an explicit timeout, for example
`watchdogd -t 8 -s 2`. This watchdog has a short attention span: the
`watchdogd` default of 128 s is beyond the hardware range, so that
request fails and the watchdog stays off.

## Testing

### Host harness

A host harness compiles the unmodified driver against real FreeBSD
arm64 headers (built in and as a module) and runs it on a keyed
register model under ASan and UBSan. Its 6,256 scenarios cover:

- all 2,047 timeout steps at their boundaries;
- zero, negative and too-long requests;
- the error handling shared with other providers;
- the order of disable and feed writes;
- both DT properties and the preservation of unrelated bits;
- all valid and reserved reset IDs;
- attach failures, detach refusal and shutdown.

### On the board

Board test, November 2026, in single-user mode with a read-only root.
All writes went through the watchdog API; registers were read through a
test-only kernel hook.

- `mt7986_wdt0` attached and the timer was found unarmed.
- Requested timeouts and the LENGTH values read back:

  | Request | LENGTH |
  |---|---|
  | 8 s | `0x4000` |
  | 16 s | `0x8000` |
  | 31 s | `0xf800` |
  | 31.984375 s | `0xffe0` |
  | 8.0078125 s | `0x4020` (rounded up) |

  MODE showed reset mode with IRQ and dual mode clear.
- A 32 s request failed with `EOPNOTSUPP` and disabled the previous
  timeout.
- An 8 s watchdog fed every 2 s survived 20 s. After it was disabled,
  the board stayed up for 10 more seconds. SWSYSRST did not change.
- **Expiry.** With no writable UFS or FAT file system mounted, a 20 s
  watchdog (`LENGTH=0xa000`) was armed and feeding stopped. The board
  reset, the BootROM started, and BL2 printed
  `WDT: [80000000] Watchdog timeout`. The first BootROM line reached
  the host 20.691 s after the armed message. That figure includes console and BootROM latency and
  is not a clock measurement. The 20 s length needs the eleventh length
  bit.
- After the reset the board booted normally to multiuser mode with
  clean file systems and working SD and network.

No peripheral was reset through the `hwreset` interface on the board.

## Pitfalls

- **U-Boot stops at 10 bits.** U-Boot's generic MediaTek watchdog
  driver clamps the length to 10 bits (about 16 s). The MT7986 field
  has 11 bits.
- **Seconds are an assumption.** The documented unit is 512 clock
  ticks. Seconds depend on the clock, which is assumed to be 32.768 kHz
  and has not been measured.
- **Take the reset reason from BL2, not from STA.** After the watchdog
  reset, MODE and STA read zero under FreeBSD, although BL2 had printed
  `0x80000000`. After a PSCI reboot, STA still read `0x40000000`
  (software reset) under FreeBSD, with LENGTH `0xffe0` and MODE
  `0x00000004` as the firmware left them. Why the two cases differ was
  not investigated; use the BL2 console output.
- **SWRST_SEN is left alone.** The manual lists SWRST_SEN at `0xfc`.
  Linux only uses it on MT7988. The driver does not touch it; it reads
  zero on this board.
- **To the SD card, a watchdog reset is a warm reset.** The first
  expiry test booted cleanly, but a later watchdog reset hit the same
  pre-kernel SD read failure that some software reboots hit at the
  time (on the first SD card, with OpenWrt's U-Boot), and needed
  `mmc rescan` in U-Boot. That problem is outside this
  driver; see [booting.md](booting.md).
- **Wi-Fi starts out in reset.** The Wi-Fi block (CONSYS) is in reset
  after boot. A future Wi-Fi driver has to deassert it through this
  provider.

## Open items

- Pretimeout: use the IRQ and dual mode bits with GIC SPI 110.
  FreeBSD's software pretimeout is a separate facility and works
  without it.
- A policy for DT `timeout-sec`. It is ignored now; no watchdog runs
  until userland asks for one.
- Suspend and resume, and keeping a watchdog that the bootloader left
  running (attach currently stops it).
- Test the reset lines with real consumers. The stock DTS gives TOPRGU
  resets only to Wi-Fi, for which there is no driver. The Ethernet and
  USB drivers do not use the SGMII, ETHDMA, U2PHY or SSUSB lines, and
  Linux and U-Boot do not use them for Ethernet either.
- Measure the watchdog clock, and find out what SWRST_SEN does.

## References

- MT7986A Reference Manual for BPI-R3, v1.0, section 1.2 (TOPRGU),
  distributed by Banana Pi: <https://wiki.banana-pi.org/Banana_Pi_BPI-R3>
- DT bindings and DTS in tree:
  `sys/contrib/device-tree/Bindings/watchdog/mediatek,mtk-wdt.yaml`,
  `watchdog.yaml`,
  `sys/contrib/device-tree/include/dt-bindings/reset/mt7986-resets.h`,
  `sys/contrib/device-tree/src/arm64/mediatek/mt7986a.dtsi` and
  `mt7986a-bananapi-bpi-r3.dts`.
- Linux `drivers/watchdog/mtk_wdt.c` (v6.12), hardware reference only:
  <https://github.com/torvalds/linux/blob/v6.12/drivers/watchdog/mtk_wdt.c>
- U-Boot `drivers/watchdog/mtk_wdt.c` (v2025.10):
  <https://github.com/u-boot/u-boot/blob/v2025.10/drivers/watchdog/mtk_wdt.c>
- MediaTek TF-A, `plat/mediatek/apsoc_common/drivers/wdt/mtk_wdt.c` and
  the MT7986 BL2 platform code:
  <https://github.com/mtk-openwrt/arm-trusted-firmware>
- FreeBSD `sys/sys/watchdog.h`, `sys/dev/watchdog/watchdog.c`,
  `watchdog(9)`, `watchdogd(8)`, `sys/dev/hwreset/hwreset.c` and
  `hwreset_if.m`.

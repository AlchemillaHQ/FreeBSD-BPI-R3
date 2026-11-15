# UART

The MT7986 has three MediaTek UARTs. Each is a 16550 with 32-bit spaced
registers and an extended baud rate generator: high-speed modes, a
programmable number of samples per bit, and a fractional divider that
lengthens selected bits of a frame.

The FreeBSD driver, `sys/dev/uart/uart_dev_mtk.c`, is a uart(4) class
for the generic FDT attachment. It uses the ns8250 code for everything
except the baud generator and the clocks.

We measured how the fractional divider really behaves, because the
vendor tables, Linux and U-Boot all set one of its bits for 8N1 where it
does nothing (see Pitfalls). One result: the console
everyone knows as "115200" has been running at 115273 baud all along,
and terminals have been too polite to mention it.

## Status

In review as [D61191](https://reviews.freebsd.org/D61191), the last
commit of the first series. It needs D61186 to D61190, the SoC skeleton
and clock drivers (see [clocks.md](clocks.md)). The whole series,
rebased on current FreeBSD main, is also the branch `bpi-r3/golden` of
<https://github.com/AlchemillaHQ/freebsd-src>. D61191 has been accepted
by one reviewer, who noted that the clock and baud-rate details were not
checked in depth.

The console works with the first series alone. UART1 and UART2 attach
and transmit as well, but rely on firmware for their pin multiplexing
until the pinctrl driver lands (see [pinctrl.md](pinctrl.md)).

## Hardware

| Port | Address | Default clock parent | BPI-R3 use |
|---|---|---|---|
| UART0 | 0x11002000 | `uart_sel` (40 MHz crystal) | debug console |
| UART1 | 0x11003000 | `csw_f26m_sel` (26 MHz) | 26-pin header, TX pin 8, RX pin 10 |
| UART2 | 0x11004000 | `csw_f26m_sel` (26 MHz) | 26-pin header, TX pin 11, RX pin 13 |

The DT compatible is `"mediatek,mt7986-uart", "mediatek,mt6577-uart"`.
Each port has two clocks:

- `baud` is the INFRACFG mux `infra_uartN_sel`. It selects either
  `csw_f26m_sel` (26 MHz) or TOPCKGEN's `uart_sel`, which all three
  ports share.
- `bus` is the INFRACFG gate `infra_uartN` (CG1 bits 2 to 4).

The parents in the table are what firmware leaves and what the stock DTS
assigns. UART0's node also assigns the parent of the shared `uart_sel`.
INFRACFG has a software reset per port (ids 37 to 39); the driver does
not use them.

The registers beyond the 16550 set are listed below as register indices;
the byte offset is four times the index. Source: MT7986A Reference
Manual, section 2.6.

| Index | Register | Use |
|---|---|---|
| 0x09 | HIGHSPEED | mode 0, 1, 2: 16, 8, 4 samples per bit; mode 3: SAMPLE_COUNT |
| 0x0a | SAMPLE_COUNT | samples per bit, minus one (mode 3) |
| 0x0b | SAMPLE_POINT | sample position within the bit |
| 0x0d | RATEFIX_AD | bit 0 divides the clock by 2; bit 2 makes it 4 |
| 0x15 | FRACDIV_L | one bit per data bit 0 to 7 |
| 0x16 | FRACDIV_M | bit 0 parity bit, bit 1 a stop bit |

In mode 3 a bit lasts DLM:DLL * (SAMPLE_COUNT + 1) clock cycles. Each
set FRACDIV bit adds one sample period to its bit of the frame, if the
frame has that bit (with the exceptions listed under Pitfalls). With n
extended bits in a frame of b bits:

    baud = rclk / (div * (count + n / b))

## FreeBSD driver

### Attachment

The driver has no newbus driver of its own. It declares a `uart_class`
and registers it with `UART_FDT_CLASS_AND_DEVICE()`, as `uart_dev_imx.c`
does, so the generic `uart_bus_fdt.c` attachment and the early console
both find it by compatible. Review feedback on an earlier MediaTek
submission (D57732) asked for this. The clock work is therefore done in
the class methods instead of device methods.

The low-level console operations wrap the ns8250 ones, because `init`
has to program the MediaTek generator. The ns8250 `init` would write a
16550 divisor under firmware's mode 3.

### Clocks and the console

- **Where clocks are taken.** The class's `UART_PROBE` method takes and
  enables the clocks. `uart_bus_probe()` calls it after it has mapped
  the registers and found out whether the port is the console or debug
  port, and before any register access. So no clock is enabled while the
  port's role is unknown.
- **Where they are kept.** In a driver-wide list keyed by DT node, not
  in the softc. While probing, the softc is only a `struct uart_softc`,
  and a failed attach frees it. A repeated probe, or a new attach after
  a failure, reuses the port's entry instead of taking new references.
  The list is protected by the newbus topology lock.
- **Order.** Assigned clocks first (with the clocks still off), then the
  bus clock, then the baud clock, then the rate from the clock
  framework. The framework does not move enable references on a
  reparent, so the driver only reparents disabled clocks.
- **Assigned clocks, own clocks only.** The driver applies
  `assigned-clocks` itself rather than with `clk_set_assigned()`, and
  only to the port's own `baud` and `bus` clocks. UART0's stock node
  also reparents the shared `uart_sel`, which could move the clock of a
  console on another port. Shared clocks are left alone.
- **The console and debug port** keep the firmware's clock parents and
  attach at the firmware's baud rate. No assigned clocks are applied to
  them. Their clocks are never released, not even on detach: the
  low-level console code keeps using the port. `devctl disable uart0`
  removes the tty, and kernel messages still reach the serial line.
- **Failures.** If probe or attach fails, the references already
  enabled stay in the list for the next attempt. At that point the
  driver cannot tell whether a console that has not attached yet depends
  on a shared parent. The cost is a running clock on a port that failed
  to attach. Detach of an ordinary port releases everything.
- **Probe.** Ports other than the console are put back in plain 16550
  mode (HIGHSPEED, RATEFIX_AD and FRACDIV cleared) before
  `ns8250_bus_probe()`, which sets a 16550 divisor and times its FIFO
  test by it.
- **Pins.** Attach calls `fdt_pinctrl_configure_by_name(dev, "default")`.
  Without a pinctrl driver this does nothing, and firmware's mux stays.
- **`uc_rclk = 0`.** The class has no default clock rate. A nonzero
  value would override the clock framework's rate for the console in
  `uart_bus_probe()`. The early console therefore starts without a rate,
  and its `init` keeps the firmware's generator settings.

### Baud generator

- Mode 3 is used for every rate.
- The divisor is the smallest one whose bit time fits SAMPLE_COUNT. A
  bit must last between 4 and 256 sample periods.
- The frame time is computed in sample periods for the actual framing.
  The remainder is spread evenly over the bits the hardware can extend:
  the data bits, the parity bit, and a stop bit only with two stop bits
  and more than five data bits.
- With five data bits and two stop bits, the frame is one sample period
  shorter than two full stop bits (measured, see Pitfalls).
- SAMPLE_POINT is set to the middle of the bit.
- RATEFIX_AD is cleared when programming. It is decoded when the rate is
  read back for `UART_IOCTL_BAUD`, along with the high-speed mode, the
  framing from LCR and the FRACDIV bits that apply to it.
- Rates more than 3 % off are rejected with `EINVAL`. The check is an
  exact cross-multiplication. At 26 and 40 MHz, 8N1 rates up to 921600
  baud are within 0.1 %.
- The calculation reproduces Table 2-6 of the reference manual, except
  at 7200 baud, where it picks the extension count closer to the
  requested rate.

Values the driver programs on UART1 (26 MHz). SAMPLE_COUNT,
SAMPLE_POINT and FRACDIV_L were read back on the board; the divisor and
the rate follow from them.

| Baud (8N1) | Divisor | SAMPLE_COUNT | SAMPLE_POINT | FRACDIV_L | Computed |
|---|---|---|---|---|---|
| 9600 | 11 | 0xf5 | 0x79 | 0x88 | 9600 |
| 115200 | 1 | 0xe0 | 0x6f | 0xfe | 115197 |
| 921600 | 1 | 0x1b | 0x0c | 0x88 | 921985 |
| 3000000 | 1 | 0x07 | 0x02 | 0xfe | 2988505 |

## Testing

Setup as in [clocks.md](clocks.md): BPI-R3 from SD, OpenWrt's TF-A and
U-Boot, `GENERIC` with the series, stock DTB. Register values were read
through a test-only kernel hook with a device mapping.

- **Series alone.** A kernel with only the first series attaches the
  clock controllers and the three UARTs and stops at `mountroot>` (no
  SD driver). Console input works there, and `reset` in DDB reboots.
- **Console.** It attaches with firmware's settings, reported as
  `console (115273,n,8,1)`. That is U-Boot's "115200" (see Pitfalls).
  With getty stopped, the console echoed a line in both directions at
  9600, 57600, 115200, 230400, 460800 and 921600 baud.
- **Rate table.** For 9600 to 921600, 1 and 3 Mbaud and 50 baud, in each
  of 8N1, 7E1, 8N2, 5N1 and 5N2, the programmed HIGHSPEED, SAMPLE_COUNT,
  SAMPLE_POINT, RATEFIX_AD and FRACDIV values match a host model of the
  computation in all 55 cases. 1 baud and 20 Mbaud are rejected.
- **Clock references.** `devctl disable uart2` drops the enable counts
  of `infra_uart2` and `infra_uart2_sel` from 1 and 2 to 0 and 0, and
  closes the bus gate. `devctl enable uart2` restores 1 and 2, and the
  port works. With UART2 disabled, its mux was moved to `uart_sel`;
  enabling the port restored the DT's `csw_f26m_sel` before the clocks
  were enabled, and the shared `uart_sel` kept its references
  throughout.
- **Console detach.** `devctl disable uart0` keeps the console's clock
  references and bus gate. A kernel message printed meanwhile appears on
  the serial line, and `devctl enable uart0` reattaches it.
- **Failure paths.** A host harness built from the driver source, with
  mocks of the FDT attachment and the clock framework, under UBSan and
  ASan, injects every probe and attach failure for an ordinary port and
  for the console, plus a port probed twice. In all 22 cases no clock
  handle is left without an owner, retries reuse references, the console
  never loses one, and no clock is reparented while enabled.
- **Reset.** With UART1 or UART2 programmed at 230400 7E1, asserting
  and deasserting its INFRACFG reset returned LCR, IER and the generator
  registers to their reset values. The port worked again after
  reattaching: 1 MB at 921600 8N1 in 10.96 s, against 10.85 s of line
  time.
- **Physical loopback** (with the `bpi-r3/pinctrl` driver): UART1 and
  UART2, TX jumpered to RX on the header, passed binary payloads byte
  for byte at six rates from 9600 to 921600 baud. After switching the
  pins to GPIO and back, attach restored the DT's UART mux and traffic
  passed again. A loopback cannot measure absolute rate, since TX and RX
  share the clock.

### Measured generator behaviour

The tables describe what the fractional divider should do; these runs
show what it does. UART1 ran at 26 MHz with divisor 11 and 4 sample
periods per bit, so that one extra period lengthens a 10-bit frame by
2.5 %. Each run timed a 200,000-byte transmit:

| Framing | Setting | Time | Effect |
|---|---|---|---|
| 8N1 | base / FRACDIV_L bit 0 | 3.52 / 3.60 s | data bit extended |
| 8N1 | FRACDIV_M = 1, 2, 3 | 3.52 / 3.51 / 3.52 s | none |
| 8E1 | base / M bit 0 / M bit 1 | 3.86 / 3.93 / 3.85 s | parity extended; M bit 1 none |
| 8N2 | base / M bit 1 | 3.86 / 3.94 s | stop bit extended |
| 7N1 | base / L bit 7 / L bit 6 | 3.18 / 3.18 / 3.26 s | only the frame's data bits |
| 8N1 | RATEFIX_AD = 1 / 5 | 6.90 / 13.67 s | clock / 2, / 4 |

Five data bits with LCR_STOPB, in sample periods per frame (from
transmit time):

| Bit time | 5N1 | 5 + STOPB | 5 + STOPB + M bit 1 | 6N2 |
|---|---|---|---|---|
| 4 | 28.0 | 31.0 | 32.0 | 36.0 |
| 5 | 35.0 | 39.0 | 40.0 | 45.0 |
| 8 | 56.0 | 63.0 | 64.0 | |

At the driver's 230400 5N2 setting (113 periods per bit) a frame took
34730.0 ns, against 34730.8 ns computed and 34769.2 ns for two full stop
bits.

Line rates at 921600 baud, transmitting 4 MB:

| Framing | Measured | Computed | If the extension had no effect |
|---|---|---|---|
| 8N1 | 922083 | 921985 | |
| 7E1 | 922083 | 921986 | 925267 (no parity extension) |
| 8N2 | 922625 | 922580 | 925566 (no stop extension) |

## Pitfalls

- **FRACDIV_M bit 0 does nothing in 8N1.** It extends the parity bit.
  The manual's Table 2-5, Linux and U-Boot set it for 8N1, so one of
  their extensions is lost. U-Boot's console at "115200" really runs at
  115273 baud, which is what FreeBSD reports.
- **FRACDIV_M bit 1 works only with two stop bits.** With one stop bit
  it has no effect, with or without parity.
- **FRACDIV_L bits only apply to data bits the frame has.** In 7N1,
  bit 7 has no effect.
- **Five data bits with LCR_STOPB give two stop bits minus one sample
  period.** That is neither the 1.5 stop bits of a 16550 nor the one
  stop bit the manual's LCR description gives. In this framing, M bit 1
  alone adds one period, but M bit 1 together with data bit extensions
  gave inconsistent frame lengths over repeated runs, while the same
  combination is exact in 8N2. The driver does not use the stop
  extension with five data bits.
- **RATEFIX_AD** divides the baud clock by 2 (bit 0) or 4 (bits 0 and
  2). A driver that ignores it computes the wrong rate if firmware left
  it set.
- **The manual's 4800 baud example** appears to have DLL and DLM
  swapped. Not verified.
- **Do not write the console's divisor registers from U-Boot** with
  `mw`. The console hung and the board needed a power cycle. It is a
  very efficient way to lose your only window into the board.
- **At 3 Mbaud** the measured transmit rate is 2 to 2.5 % low, because
  interrupt-driven refill does not keep the FIFO full. It is not a
  generator error (the computed rate is 0.4 % low).
- **Timing measurements** occasionally gave outlier runs. Repeat a run
  before drawing a conclusion.
- **Testing detach.** After `devctl detach` the device loses its name
  and cannot be reattached by name. Use `devctl disable` and `enable`.
- **No userland `/dev/mem` mappings** for UART registers on arm64; see
  [clocks.md](clocks.md#pitfalls).

## Open items

- Pin multiplexing for UART1 and UART2 depends on firmware until the
  pinctrl driver is in the tree.
- Why the stop extension combined with data extensions is inconsistent
  with five data bits. The driver avoids that case.
- Review of D61191 together with the clock series.

## References

- MT7986A Reference Manual for BPI-R3, v1.0, section 2.6 (UART), Tables
  2-5 and 2-6. Distributed by Banana Pi:
  https://wiki.banana-pi.org/Banana_Pi_BPI-R3
- DT binding: `sys/contrib/device-tree/Bindings/serial/mediatek,uart.yaml`.
- BPI-R3 schematic, page 4 (header pinout):
  https://cdn.hackaday.io/files/1861277963257568/BPI-R3-V11-SCH-Public.pdf
- Earlier MediaTek review with feedback on the UART attachment:
  https://reviews.freebsd.org/D57732

# Pin control, GPIO and external interrupts

The MT7986A pin controller is one device tree node with eight register
blocks: the GPIO block (mux, direction, data), six IOCFG blocks (pull,
input buffer, Schmitt trigger, drive strength) and the EINT external
interrupt controller. FreeBSD gets one driver that is at the same time
the FDT pinctrl provider, a GPIO controller and an INTRNG interrupt
controller for all 101 pins.

It works on the BPI-R3. Two drive-strength fields remain unresolved:
every published table agrees on where they are, and every published
table gives them overlapping bits.

## Status

| Part | State |
|---|---|
| Pin states (mux, bias, input, Schmitt, drive, output) | Works; all 101 pins and 39 groups of the binding |
| GPIO (gpiobus, gpioc, gpioled) | Works |
| EINT, edge triggers | Works (Reset and WPS buttons) |
| EINT, level triggers | Host-tested only |
| Drive strength on GPIO89 and GPIO100 | Refused on purpose, see Pitfalls |
| MT7986B variant | Not supported |

The driver is ready for review:

- Files: `sys/arm64/mediatek/mt7986_pinctrl.c`, the hardware tables in
  `sys/arm64/mediatek/mt7986_pinctrl_data.h`, `device mt7986_pinctrl` in
  `sys/arm64/conf/std.mediatek` and one line in `sys/conf/files.arm64`.
- It sits on top of the first series in review (D61186 to D61191), that
  is on `bpi-r3/golden`, and does not depend on any other feature branch.
- It is not posted for review yet. The code is on branch
  `bpi-r3/pinctrl` of
  <https://github.com/AlchemillaHQ/freebsd-src>.

Without this driver, UART1, UART2 and the SD pins keep whatever setup
the boot firmware left (see [uart.md](uart.md) and [mmc.md](mmc.md)),
and the MT7531 switch reset and the SFP I2C buses have no GPIO provider.

## Hardware

The reference manual documents the GPIO block (section 2.8) and EINT
(section 1.4). It gives the IOCFG block addresses but not the per-pin
field layout, so you know where the registers are but not what is in
them. The layout comes from MediaTek's tables in Linux, U-Boot and the
MediaTek SDK, used as hardware references only.

| `reg-names` | Address | Contents |
|---|---|---|
| `gpio` | `0x1001f000` | DIR, DOUT, DIN, MODE |
| `iocfg_rt` | `0x11c30000` | Pins 21-32, 50-61 |
| `iocfg_rb` | `0x11c40000` | Pins 0, 5-6, 11-20, 39-49, 62-65 |
| `iocfg_lt` | `0x11e20000` | Pins 1-2, 7-10, 33-38 |
| `iocfg_lb` | `0x11e30000` | Pins 3-4, 66-68 |
| `iocfg_tr` | `0x11f00000` | Pins 69-85 |
| `iocfg_tl` | `0x11f10000` | Pins 86-100 |
| `eint` | `0x1000b000` | External interrupts, parent GIC SPI 225 |

The driver finds each block by its name, not by position or address.

### GPIO block

DIR (`0x000`), DOUT (`0x100`) and DIN (`0x200`) have one bit per pin,
32 pins per register, with registers `0x10` apart. MODE (`0x300`) has
eight four-bit slots per register, also `0x10` apart; only the low three
bits of a slot select the function. DIR, DOUT and MODE have SET and CLR
aliases at +4 and +8. Function 0 is GPIO.

### IOCFG blocks

Each block has its own register offsets, and pins are not in GPIO order
inside a block. Per pin there is:

- An IES bit (input buffer enable) and an SMT bit (Schmitt trigger),
  with the same bit number.
- A pull control. Pins 0-68 (blocks RT, RB, LT, LB) use PUPD for the
  direction (0 up, 1 down) and R1:R0 to choose which of two resistors
  are connected (00 none). Pins 69-100 (TR, TL) have plain PU and PD
  bits.
- A drive field, three bits for 2 to 16 mA in 2 mA steps (value =
  mA / 2 - 1), in registers `0x00`, `0x10` and `0x20` of the block.
  Pins 3 and 4 (`I2C_SCL`, `I2C_SDA`) have one-bit fields, so only 2
  and 4 mA fit; the driver refuses larger values with `ERANGE`.

| Block | IES | SMT | Pull registers |
|---|---|---|---|
| RT | `0x30` | `0xc0` | PUPD `0x40`, R0 `0x50`, R1 `0x60` |
| RB | `0x40` | `0xf0` | PUPD `0x60`, R0 `0x70`, R1 `0x80` |
| LT | `0x20` | `0x90` | PUPD `0x30`, R0 `0x40`, R1 `0x50` |
| LB | `0x20` | `0x90` | PUPD `0x40`, R0 `0x50`, R1 `0x60` |
| TR | `0x30` | `0x80` | PD `0x40`, PU `0x50` |
| TL | `0x30` | `0x70` | PD `0x40`, PU `0x50` |

### EINT

Pin n is EINT n, for pins 0-100, when the pin is in GPIO mode with its
input buffer on. All sources share one parent interrupt. Each register
family is four 32-bit words, four bytes apart.

| Register | Offset | Meaning |
|---|---|---|
| STA / ACK | `0x000` / `0x040` | Pending / write 1 to acknowledge |
| MASK, SET, CLR | `0x080`, `0x0c0`, `0x100` | 1 masks the source |
| SENS, SET, CLR | `0x140`, `0x180`, `0x1c0` | 1 level, 0 edge |
| SOFT, SET, CLR | `0x200`, `0x240`, `0x280` | Software pending bit |
| POL, SET, CLR | `0x300`, `0x340`, `0x380` | 1 high/rising, 0 low/falling |
| D0EN | `0x400` | Route the source to domain 0 |
| DBNC, SET, CLR | `0x500`, `0x600`, `0x700` | Debounce, four 8-bit fields per word, EINT 0-15 only |

Each source has a single polarity, so the hardware cannot trigger on
both edges.

## FreeBSD driver

### Attach

The driver attaches at `BUS_PASS_INTERRUPT` with the driver name
`gpio`, so it appears as `gpio0` with `gpiobus0` and `/dev/gpioc0`. In
order, it:

1. maps the eight blocks and the parent interrupt;
2. masks every EINT source, sets D0EN for exactly the 101 valid sources
   (`ffffffff` in the first three words, `0000001f` in the fourth),
   clears pending and software bits and disables debounce;
3. adds the GPIO bus, registers the 101 interrupt sources and the
   parent handler;
4. only then registers the PIC, the last step that can fail;
5. registers with `fdt_pinctrl`, applies all default pin states and
   attaches its children.

Detach returns `EBUSY`.

### Pin states

The driver implements the stock binding,
`sys/contrib/device-tree/Bindings/pinctrl/mediatek,mt7986-pinctrl.yaml`:

- `function` and `groups`, all 39 groups. The number of groups per node
  is limited as in the schema (two for `uart`, `spi` and `pwm`, three
  for `pcie` and `wifi`, one otherwise).
- `pins` with `bias-disable`, `bias-pull-up` and `bias-pull-down`
  (boolean, or 100-103 for R1:R0 on PUPD pads), `mediatek,pull-up-adv`
  and `mediatek,pull-down-adv` (0-3), `input-enable`, `input-disable`,
  `input-schmitt-enable`, `input-schmitt-disable`, `output-enable`,
  `output-low`, `output-high` and `drive-strength`.

A boolean pull selects R1:R0 = 01 on PUPD pads; the R1:R0 forms are
refused on PU/PD pads. `input-enable` sets IES only and does not change
the GPIO direction.

A referenced state, with all its child nodes, is parsed into a per-pin
table before any register is written. Unknown properties, bad strings or
cells, unknown pins or groups, conflicting values from two children and
values a pin cannot hold all fail the whole state. The writes then
happen under one spin lock, per pin in this order: IES, SMT, drive,
pull, output latch, direction, mux. When a pull changes, both resistors
are disconnected before PUPD moves.

### GPIO

Every pin offers input, output, push-pull, open drain, pull-up,
pull-down, both output presets and the five interrupt modes.

`GPIO_PIN_SETFLAGS` needs exactly one direction and refuses
contradictory flags. It selects function 0, enables the input buffer,
sets the pull (none if no pull flag is given) and writes the latch
before enabling the output. Set and toggle return `EBUSY` while the pin
belongs to another function. Reads always come from DIN. DT specifiers
have two cells; the flags cell is passed through and the consumer
handles active-low.

The hardware has no open-drain mode, so the driver emulates it: DOUT
stays low, driving low sets DIR to output and releasing sets it to
input. A released pin still reports `GPIO_PIN_OUTPUT |
GPIO_PIN_OPENDRAIN`.

### EINT

The PIC accepts two-cell FDT specifiers (`<pin type>`, types 1, 2, 3, 4
and 8) and GPIO interrupt mappings. Setting up an interrupt puts the pin
in GPIO input mode with the input buffer on and keeps its pull. While an
interrupt is set up, GPIO and pin-state requests that would make the pin
an output, turn off its input buffer or change its function fail with
`EBUSY`. Handlers may share a pin if they ask for the same mode.

Edge sources are acknowledged before dispatch, so an edge during the
handler stays pending. Level sources are acknowledged after the filter
or the interrupt thread. Threaded handlers run with the source masked;
an explicit disable is tracked separately, so a late thread cannot
unmask a closed source. Sources with no handler are masked.

Both-edge mode flips the polarity in software after each event. It
reads DIN before and after the write, retries up to four times, and sets
the SOFT bit for another pass if the level moved meanwhile. That is
enough for buttons but cannot count short pulses. Debounce is disabled
and not exposed; consumers must debounce switches themselves.

## Testing

### Host harness

A host harness compiles the unmodified driver against a register model
and FreeBSD's own `ofw_fdt` property code, under ASan and UBSan. It runs
106 DT, register and failure cases, 14 GPIO scenarios and 23 EINT
scenarios. Of the 12 pin states in the stock BPI-R3 DTS, 10 apply; the
two Wi-Fi states are refused with no register written.

### On the board

Tested in November 2026 with the stock DTB and the SD overlay:

- **Boot.** Default states apply; SD root, console and network work. Ten
  masked register readbacks match the DT: the UART1 and UART2 mux, and
  the SD pins' mux, input buffers, PUPD/R0/R1 and drive (6 mA clock,
  4 mA command and data). For example `0x1001f330` reads `0x14411111`,
  function 4 on GPIO29/30 for UART2.
- **GPIO.** All 101 pins enumerate. The green and blue LEDs (GPIO69,
  GPIO86) pass presets, set and toggle with DIN, DOUT and DIR read back,
  and work through `gpioled` as `/dev/led/led-0` and `led-1`. A held
  blue-on, green-off state was confirmed by eye, the most low-tech
  instrument used in this project. Open-drain low and release work on
  GPIO86. Neighboring bits stay untouched. The Reset and WPS buttons
  (GPIO9 and GPIO10, active low, pull-up) read press and release by
  polling.
- **EINT.** All pins advertise the five modes, D0EN routes exactly 101
  sources and the debounce enables read clear. Rising, falling and
  both-edge setup, masking on close and output refusal pass on GPIO9 and
  GPIO10. With each button pressed once, GPIOC `poll`/`read` delivered
  one low and one high event for Reset, and two low and one high for WPS
  (probably contact bounce; not checked). The GIC SPI 225 count (5)
  matched the per-pin counts.
- **UART pads.** Jumpers on the 26-pin header join pin 8 to 10 (UART1 TX
  to RX, GPIO43/42, `uart1_rx_tx`, function 1) and pin 11 to 13 (UART2,
  GPIO30/29, `uart2_0_rx_tx`, function 4). Both ports pass loopback at
  six rates from 9600 to 921600 baud. Each UART was then detached with
  `devctl`, its pads driven as GPIO in both directions across the jumper
  (32 levels each way), and reattached; the UART attach reapplies the DT
  mux and traffic passes again. In all, 20 transfers and 821,248 bytes
  matched.
- **Consumers.** The MT7531 switch driver resets the switch through
  `reset-gpios` (GPIO5) and configures it from there. `gpioiic` runs on
  the SFP I2C buses (`i2c-gpio`, pins 16/17 and 18/19) through the
  open-drain emulation and reads a module EEPROM. See
  [ethernet.md](ethernet.md).

Register reads went through a test-only kernel hook. Do not `mmap`
`/dev/mem` for this on FreeBSD/arm64: the mapping is cacheable, and in
an earlier experiment it gave stale reads and stalled a CPU.

## Pitfalls

- **GPIO89 and GPIO100 drive fields overlap.** Linux, U-Boot, the
  MediaTek SDK feed, the Banana Pi SDK and the original Linux driver all
  put GPIO89 (`WF1_TOP_CLK`) at IOCFG_TL + `0x10` bits 8:6 and GPIO100
  (`WF1_HB8`) at bits 7:5, sharing bits 7:6. Both stock Wi-Fi states ask
  for 4 mA (value 1) on both pins, which these fields cannot hold at
  once; the result depends on write order. The manual does not cover
  them. The driver refuses `drive-strength` on these two pins with
  `EOPNOTSUPP`, and boot prints `cannot configure wf-2g-5g-pins: error
  45`. The same tables put GPIO99 (`WF1_HB7`) at bits 4:2. A plausible
  fix moves GPIO99 to bits 2:0 and GPIO100 to 5:3, leaving GPIO89 at
  8:6; that removes the overlap and matches the three-bit layout of the
  neighbors, but nothing confirms it, and readback cannot show which pad
  a bit drives.
- **Pin count.** The manual's introduction says "100 I/O pins", which
  would be news to pin 100, and its EINT counts and block diagram
  disagree with each other. The detailed register tables and the DTS
  have 101 pins (0-100) and four EINT words. The MediaTek SDK sets an
  EINT port count of seven; the driver follows the manual's register
  tables.
- **UART pads 42-49** have the pull bit one above the IES bit; on all
  other pins they match. Linux fixed its table for this in late 2022.
- **The `mdc_mdio` group.** The binding's description omits pin 68. The
  manual puts MDC on GPIO67 and MDIO on GPIO68, both function 1; the
  driver's group has both.
- **UART2 on the BPI-R3** is routed to GPIO29/30 (`uart2_0_rx_tx`), not
  to the UART2 pads 46-49, which carry SFP cage signals on this board.
- **Refused states do not stop consumers.** FreeBSD's
  `fdt_pinctrl_configure()` ignores the provider's return value, so a
  consumer attaches even if its state was refused; the driver prints the
  error itself.
- **Pulls survive a UART reattach.** The stock UART states set only the
  mux, so pull changes made through the GPIO API stay. In the mux test
  the UART1 pull-ups moved from R1 (firmware default) to R0 (the GPIO
  boolean pull) until the next reboot.
- **No pull flag means no pull.** `GPIO_PIN_SETFLAGS` without a pull
  flag turns the pull off. `gpioiic` releases lines by switching them to
  input without one, so the bus needs external pull-ups; the BPI-R3 SFP
  buses have them.
- **PIC registration order.** In the FreeBSD revision these drivers are
  based on, `intr_pic_deregister()` panics, so the PIC must be
  registered after every step that can fail.

## Open items

- Have the GPIO89, GPIO99 and GPIO100 drive fields confirmed by
  MediaTek, or by an electrical test that tells the pads apart. Until
  then the binding is not fully supported.
- Test a physical level-triggered consumer. The MT7531 interrupt on
  EINT 66 (level high) is the obvious one; the switch driver polls for
  now. GPIOC offers only edge events to userland.
- Test the stock `gpio-keys` node with FreeBSD's `gpiokeys`.
- Measure drive strength; no currents have been measured.
- MT7986B (fewer pins and groups), wakeup routing, suspend and resume,
  and a debounce interface are not done.

## References

- MT7986A Reference Manual for BPI-R3, v1.0, sections 1.4 (EINT) and
  2.8 (GPIO), distributed by Banana Pi:
  https://wiki.banana-pi.org/Banana_Pi_BPI-R3
- BPI-R3 schematic V1.1, header CON1 on page 4:
  https://cdn.hackaday.io/files/1861277963257568/BPI-R3-V11-SCH-Public.pdf
- DT binding and DTS in tree:
  `sys/contrib/device-tree/Bindings/pinctrl/mediatek,mt7986-pinctrl.yaml`
  and `sys/contrib/device-tree/src/arm64/mediatek/mt7986a.dtsi`,
  `mt7986a-bananapi-bpi-r3.dts`, `mt7986a-bananapi-bpi-r3-sd.dtso`.
- Linux `drivers/pinctrl/mediatek/pinctrl-mt7986.c`,
  `pinctrl-mtk-common-v2.c` and `mtk-eint.c` (v6.12), and the GPIO42-49
  pull fix:
  https://github.com/torvalds/linux/tree/v6.12/drivers/pinctrl/mediatek
  https://github.com/torvalds/linux/commit/3476b354c65db442580ef355885c69e60c546ef0
- U-Boot `drivers/pinctrl/mediatek/pinctrl-mt7986.c`:
  https://github.com/u-boot/u-boot/blob/main/drivers/pinctrl/mediatek/pinctrl-mt7986.c
- MediaTek SDK feed, `21.02/.../pinctrl-mt7986.c`:
  https://github.com/mediatek/mtk-openwrt-feeds/tree/f185b9c74f1d
- FreeBSD `sys/dev/fdt/fdt_pinctrl.c`, `sys/kern/subr_intr.c`,
  `sys/dev/gpio/gpiobus.c`, `gpioc.c` and `gpioiic.c`.

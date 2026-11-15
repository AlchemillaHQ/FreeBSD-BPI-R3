# USB: SSUSB xHCI and T-PHY

The MT7986A has one USB host controller: an xHCI (MediaTek calls the block
SSUSB) behind a vendor power and port control block, the IPPC. A MediaTek
T-PHY (version 2) provides one USB 3.0 and two USB 2.0 PHY ports.

It is a perfectly standard xHCI, apart from the parts that are not. FreeBSD
needs a T-PHY driver, a small glue driver, and one optional hook in the
shared xHCI code so the glue can fill in two endpoint-context dwords that
the xHCI specification calls reserved and MediaTek's scheduler calls
essential. With that, high-speed devices and full-speed keyboards work.

## Status

| Piece | File | State |
|---|---|---|
| T-PHY driver | `sys/arm64/mediatek/mtk_tphy.c` | Ready for review |
| Endpoint-context hook | `sys/dev/usb/controller/xhci.c`, `xhci.h` | Ready for review, by the USB maintainers in particular |
| xHCI glue | `sys/arm64/mediatek/mtk_xhci.c` | Ready for review; works with high-speed devices and a full-speed keyboard on a root port |
| LS/FS devices behind a hub | | Untested (no small USB hub at hand) |
| SuperSpeed | | Untested (no USB 3 device at hand) |

The code is on branch `bpi-r3/usb` of
<https://github.com/AlchemillaHQ/freebsd-src>, three commits on top of
`bpi-r3/golden`: the T-PHY driver, the xHCI hook, and the glue. No new
kernel options are needed: the files build with `options SOC_MEDIATEK`,
`device phy` and `device xhci`, which arm64 `GENERIC` already has.

## Hardware

The MT7986 reference manual we have does not cover USB at all, which is one
way to keep a chapter short. The facts below come from MediaTek's Linux and
U-Boot drivers (read as a hardware reference only), the mainline device
tree and the board schematics.

### Board topology

```
xHCI root hub
  port 1  SuperSpeed (IPPC U3 port 0) ---+
                                         +--- USB-A connector (CN9)
  port 3  high speed (IPPC U2 port 1) ---+
  port 2  high speed (IPPC U2 port 0) ------- FE1.1s USB 2.0 hub (U10)
                                                port 1: mini PCIe (CN11)
                                                ports 2, 3: header (CON9)
                                                port 4: not connected
```

- Root port 3 is confirmed: its PORTSC changed when a stick in the USB-A
  port was moved, and a keyboard plugged in there shows up on it. Root
  port 1 is inferred (SuperSpeed ports come first); port 2 follows by
  elimination.
- The schematic also has a direct path from USB2 port 0 to the mini PCIe
  slot through option resistors (R187/R188, "NC/0R"). On our board the
  slot is behind the hub.
- VBUS is always on. The USB-A port and the header are each fed by an
  SY6280AAC power switch whose enable pin sits on a resistor divider from
  +5 V. No GPIO or regulator is involved and the DT has no `vbus-supply`.

### Device tree

Compatibles: `"mediatek,mt7986-xhci", "mediatek,mtk-xhci"` and
`"mediatek,mt7986-tphy", "mediatek,generic-tphy-v2"`. Neither Linux nor
U-Boot has MT7986-specific data; both bind on the generic strings.

| Block | Address | Size |
|---|---|---|
| xHCI ("mac") | 0x11200000 | 0x2e00 |
| IPPC ("ippc") | 0x11203e00 | 0x100 |
| T-PHY u2port0 | 0x11e10000 | 0x700 |
| T-PHY u3port0 | 0x11e10700 | 0x900 |
| T-PHY u2port1 | 0x11e11000 | 0x700 |

- One interrupt, GIC SPI 173, level high. No resets, power domains,
  regulators or PHY tuning properties. The controller reports HCIVERSION
  1.10, 32-byte contexts and 64-bit addressing.
- Controller clocks in DT order, with the rates measured on the board
  (see [clocks.md](clocks.md)): `sys_ck` 125 MHz, `ref_ck` 26 MHz,
  `mcu_ck` 156.25 MHz, `dma_ck` 78.125 MHz, `xhci_ck` 125 MHz. Each USB2
  PHY port has `ref` and `da_ref` (48 MHz); the USB3 port only `ref`
  (26 MHz).
- `phys` lists u2port0, u3port0 and u2port1, each with one cell holding
  the PHY type (`PHY_TYPE_USB2` or `PHY_TYPE_USB3`).

### IPPC

Power-up, after the clocks and PHYs are on (offsets from the IPPC base):

1. IP_PW_CTRL0 (0x00): pulse bit 0, IP_SW_RST, for 1 us.
2. IP_PW_CTRL2 (0x08): set bit 0, IP_DEV_PDN (device IP off). Linux does
   this ("otherwise ip-sleep will fail"); U-Boot does not.
3. IP_XHCI_CAP (0x24): bits 7:0 give the U3 ports, 15:8 the U2 ports;
   1 and 2 on the MT7986.
4. IP_PW_CTRL1 (0x04): clear bit 0, IP_HOST_PDN. Then in every
   U3_CTRL_P(n) (0x30 + 8n) and U2_CTRL_P(n) (0x50 + 8n): clear DIS
   (bit 0) and PDN (bit 1), set HOST_SEL (bit 2).
5. IP_PW_STS1 (0x10): poll, 20 ms timeout, until SYSPLL_STABLE (0),
   REF_RST (8), SYS125_RST (10), XHCI_RST (11) and, with a U3 port,
   U3_MAC_RST (16) are all set.

Only then are xHCI registers touched. Power-down sets PDN and DIS on
every port and then IP_HOST_PDN.

### T-PHY v2

In version 2 each port has all its banks in its own window. USB2 port:
MISC +0x000, FMREG (frequency meter) +0x100, COM +0x300. USB3 port:
SPLLC +0x000, CHIP +0x100, PHYD +0x200, PHYA +0x400, PHYA_DA +0x500.
The port clocks (`ref`, then `da_ref`) are enabled before init.

USB2 init, read-modify-write, in this order:

| Register | Change |
|---|---|
| COM+0x68 U2PHYDTM0 | clear FORCE_UART_EN (26), FORCE_SUSPENDM (18); XCVRSEL [5:4] = 1 |
| COM+0x6c U2PHYDTM1 | clear RG_UART_EN (16) |
| COM+0x00 USBPHYACR0 | set RG_USB20_INTR_EN (5) |
| COM+0x14 USBPHYACR5 | clear RG_U2_HS_100U_U3_EN (11) |
| COM+0x20 U2PHYACR4 | clear RG_USB20_GPIO_CTL (9), USB20_GPIO_MODE (8) |
| COM+0x18 USBPHYACR6 | clear RG_U2_BC11_SW_EN (23); RG_U2_SQTH [3:0] = 2 |
| COM+0x14 USBPHYACR5 | RG_U2_HSTX_SRCTRL [14:12] = 4 (fixed HS slew rate) |

USB2 power-on: in U2PHYDTM0 clear XCVRSEL, DATAIN [13:10], the force
bits 23, 21, 20, 19, 17 and bits 7, 6, 2; in USBPHYACR6 set
RG_U2_OTG_VBUSCMP_EN (20); in U2PHYDTM1 set RG_VBUSVALID (5) and
RG_AVALID (2) and clear RG_SESSEND (4). Power-off reverses the last two.

Yes, the USB2 PHY has a UART mode, and yes, it is on until you turn it
off.

USB3 init (Linux and U-Boot agree); there is no USB3 power step:

| Register | Change |
|---|---|
| SPLLC+0x18 XTALCTL3 | set bits 9 and 8 (gate the PCIe analog XTAL clock) |
| PHYA_DA+0x00 | RG_XTAL_EXT_EN_U3 [11:10] = 2 |
| PHYA+0x24 REG9 | RG_RX_DAC_MUX [5:1] = 4 |
| PHYA+0x18 REG6 | RG_TX_EIDLE_CM [31:28] = 0xe |
| PHYD+0x5c CDR1 | RG_CDR_BIR_LTD0 [12:8] = 0xc, RG_CDR_BIR_LTD1 [28:24] = 3 |
| PHYD+0x0c LFPS1 | RG_FWAKE_TH [21:16] = 0x34 |
| PHYD+0x128 RXDET1 | RG_RXDET_STB2_SET [17:9] = 0x10 |
| PHYD+0x12c RXDET2 | RG_RXDET_STB2_SET_P3 [8:0] = 0x10 |

### Endpoint context DW5 and DW6

The MediaTek host schedules periodic transfers from fields in dwords 5
and 6 of the xHCI endpoint context. The xHCI specification marks these
reserved; the silicon did not get the memo. A generic xHCI driver leaves
them zero, and with BPKTS = 0 the host schedules no packets at all.

| Field | Dword | Bits | Meaning |
|---|---|---|---|
| BPKTS | 5 | 6:0 | packets per scheduled microframe |
| BCSCOUNT | 5 | 10:8 | number of complete-splits (behind a TT), at most 7 |
| BBM | 5 | 11 | burst mode (SuperSpeed) |
| BOFFSET | 6 | 13:0 | first scheduled microframe in the service interval |
| BREPEAT | 6 | 30:16 | gap between scheduled microframes |

Linux writes them before Configure Endpoint:

- Control and bulk: nothing.
- LS/FS periodic on a root port: BPKTS = 1 only; the root hub schedules
  these itself.
- LS/FS periodic behind a high-speed hub's TT (here: anything on the
  FE1.1s): BPKTS = 1, BCSCOUNT and a BOFFSET from its scheduler.
- High-speed periodic: BPKTS = Max Burst + 1 and a BOFFSET.
- SuperSpeed: BBM = 1 and BPKTS from the Max ESIT Payload; isochronous
  endpoints are spread over the interval with BREPEAT = 1.

U-Boot's generic xHCI driver, with its MediaTek quirk set, writes
BPKTS = 1 and BBM = 1 for every endpoint. That shows control and bulk
work with these values; it says little about periodic endpoints, since
U-Boot rarely meets a keyboard it needs to listen to for long.

## FreeBSD driver

### T-PHY: `mtk_tphy.c`

- Attaches early on simplebus (`BUS_PASS_SUPPORTDEV`) and creates one
  phynode (`phynode_usb` class, host mode only) per enabled child node.
- The children's `reg` is only meaningful through the parent's `ranges`,
  so each is translated with `ofw_reg_to_paddr()` and then mapped.
- `phynode_enable`: on the first enable, turn on the port clocks and run
  the USB2 or USB3 init; USB2 ports then power on or off with every enable
  or disable.
- Its own `phydev_map`. FreeBSD's default, `phydev_default_ofw_map()`,
  uses a single cell as the phynode id. Here the cell is the PHY type, so
  both USB2 ports would resolve to the same phynode. The driver finds the
  port by the xref's node instead and records the type from the cell.

### Endpoint-context hook: `xhci.c`, `xhci.h`

- `xhci.h`: a new optional `struct xhci_softc` member, `sc_endp_quirk`,
  of type `void (device_t, struct usb_device *, struct xhci_endp_ctx *)`.
  It sits next to `sc_port_route`, the existing hook of the same kind.
- `xhci.c`: `xhci_configure_endpoint()` calls it once the standard dwords
  of the input endpoint context are filled in, before the context is
  flushed to the controller. It is NULL for every other controller, so
  nothing else changes. Total cost: one function pointer and an `if`.

### xHCI glue: `mtk_xhci.c`

- A subclass of `generic_xhci_driver`, named `xhci` so the device is
  `xhci0`; `dwc3.c` was the model. `generic_xhci_fdt.c` matches only
  `generic-xhci` and Marvell compatibles and takes a single `usb-phy`.
- Attach: enable the five clocks; set host mode on and enable every
  `phys` entry; map `ippc` by `reg-names`; IPPC power-up; set the
  endpoint-context hook; `generic_xhci_attach()`. Detach undoes this in
  reverse.
- DMA width and interrupt moderation stay at the generic defaults.
- The hook reads the endpoint type, interval, Max Burst, Mult, Max Packet
  Size and Max ESIT Payload back from the context, as Linux does, and
  writes DW5 and DW6 with what Linux's scheduler picks for an endpoint
  alone in its bandwidth domain:

| Endpoint | DW5 | DW6 |
|---|---|---|
| Control, bulk | 0 | 0 |
| Periodic with Max Packet Size 0 | BPKTS 1 | 0 |
| LS/FS periodic on a root port | BPKTS 1 | 0 |
| LS/FS periodic behind a TT | BPKTS 1; BCSCOUNT = ceil(maxp / 188) + 2, or + 1 if the last complete-split lands in microframe 7, at most 7; isochronous OUT uses ceil(maxp / 188) | 0 |
| High-speed periodic | BPKTS = Max Burst + 1 | 0 |
| SuperSpeed interrupt | BBM, BPKTS = ceil(Max ESIT Payload / maxp), or (Mult + 1) x (Max Burst + 1) if the payload is 0 | 0 |
| SuperSpeed isochronous | BBM, BPKTS spread over the interval as Linux does | BREPEAT 1 if more than one microframe |

Every endpoint starts in the first microframe of its interval (BOFFSET
0) and no bandwidth is accounted. Control and bulk get explicit zeros so
a reused context never carries stale values. "Behind a TT" means the
device's nearest high-speed hub is not the root hub; the xHCI root hub is
SuperSpeed, so LS/FS devices on root ports never qualify.

## Testing

Each commit builds on its own in arm64 `GENERIC` with no compiler
warnings and no style-check findings, both on the base the series was
written on and on current FreeBSD main. Board tests, one BPI-R3 running
FreeBSD 16.0-CURRENT:

| Check | Result |
|---|---|
| Attach | `mtk_tphy0`; `xhci0` "MediaTek USB 3.0 controller", 32-byte contexts, 64-bit DMA; `usbus0` 5.0 Gbps; root hub with 3 ports |
| On-board hub | Terminus FE1.1s (vendor 0x1a40), 4 ports, high speed |
| Mini PCIe | Quectel EC25-E LTE module on hub port 1, high speed (enumeration only; no driver in the test kernel) |
| USB-A, USB 2.0 stick | SanDisk Cruzer Blade: `umass0`/`da0`, high speed |
| Storage | 300 MB raw read at 18 MB/s, 100 MB file read at 17 MB/s, 64 MiB write at 7.6 MB/s; checksum unchanged after remount |
| Root-port hot-plug | PORTSC of root port 3 toggled between 0x2a0 (powered, no device) and 0xe03 (connected, enabled, high speed); every reconnect enumerated |
| HS hub interrupt endpoint | ClearPortFeature(PORT_POWER), then SetPortFeature, on hub port 1: the disconnect was logged and the modem re-attached |
| Full-speed keyboard, root port | See below: no interrupt transfers without the hook, keys and the Caps Lock LED with it |
| Shutdown | `uhub1`, `umass0` and `uhub0` detached cleanly |

The storage figures are those of a USB 2.0 stick, not a controller
benchmark. The hot-plug test came courtesy of a loose USB-A connector,
which is not a test method we recommend but was free. The LTE module was
not seen on the first boot (all hub ports reported power but no
connection) and enumerated on later boots; the cause is not known.

### The keyboard

A full-speed keyboard (Logitech G213) on the USB-A port, root port 3.
Its interrupt IN endpoints are 0x81 (8 bytes) and 0x82 (64 bytes), both
with bInterval 1.

- **Without the hook:** `hkbd0` attached, so control transfers work.
  Then nothing. `usbdump` over 120 seconds of typing and Caps Lock
  presses showed no transfer on either interrupt endpoint, the endpoint
  statistics counted zero successful interrupt transfers, and the
  Caps Lock LED stayed put.
- **With the hook:** 73 interrupt transfers on 0x81 in the same kind of
  test, all 8-byte reports, all without error, and the statistics agree.
  The Caps Lock LED follows the key, which means the host saw the key
  press and sent the LED report back over the control endpoint. The
  Caps Lock LED is the oldest integration test in computing, and it
  passed.

## Pitfalls

- The PCIe T-PHY has the same compatible. The driver attaches to it too
  but rejects its `PHY_TYPE_PCIE` cell, so it cannot be used yet.
- The IPPC must be up before any xHCI register access. Linux and U-Boot
  both order it so; we did not try the opposite.
- In IP_PW_STS1 the `*_RST` bits mean "reset released" when set.
- The reserved endpoint-context fields matter, but not everywhere. With
  DW5 and DW6 zero, the high-speed hub's interrupt endpoint still worked
  (FreeBSD explores a hub only on its status-change interrupt, and the
  port power cycle was seen), while a full-speed keyboard on a root port
  got no interrupt transfers at all. Linux always writes BPKTS >= 1 for
  periodic endpoints, so it never shows the difference. This is how a
  driver can look finished for a week and then meet a keyboard.
- Linux's header comment gives the service interval as `2 << Interval`;
  its code uses `1 << Interval`, capped at 64 microframes. The FreeBSD
  hook follows the code.
- `clk_disable()` and `phy_disable()` underflow when called for a clock
  or PHY that was never enabled. The glue keeps only what it enabled, so
  its error and detach paths stay balanced.
- VBUS on the USB-A port cannot be switched, so xHCI port power control
  does not cut power to the device (inferred from the schematic).

## Open items

- Review of the xHCI hook by the FreeBSD USB maintainers. It changes
  shared code in `sys/dev/usb/controller/`, but it is one optional
  callback, NULL by default.
- LS/FS devices behind a hub (the BCSCOUNT path), for example a keyboard
  on the header behind the FE1.1s, or on a small external USB 2.0 hub.
- No bandwidth accounting: all periodic endpoints start in microframe 0,
  where Linux spreads them. Probably fine for a few HID and hub
  endpoints; isochronous devices are untested.
- SuperSpeed: test a USB 3 device, which also checks the USB3 PHY values
  and the root port numbering.
- HS slew-rate calibration: Linux measures it with the frequency meter
  instead of using the fixed 4. Its defaults assume a 26 MHz reference,
  while the USB2 PHY clocks here are 48 MHz; what Linux computes on this
  board is unknown. The fixed value works on our board.
- eFuse calibration: the hardware auto-load is left alone; MediaTek's SDK
  device tree adds software eFuse cells for the PHY. Not checked.
- Linux quirks not carried over, both unmeasured. Its glue says the
  MediaTek IMOD interval counts 8 times slower than the xHCI
  specification and programs 5000 ns; FreeBSD's default (0x1f4, 125 us by
  the specification) would then be 1 ms. It also ignores a "spurious
  successful event after a short transfer"; FreeBSD has no such quirk and
  the storage tests showed no errors.
- Not implemented: power management (IP sleep, suspend), device and OTG
  mode, PCIe T-PHY ports.

## References

- Linux v6.12: `drivers/usb/host/xhci-mtk.c`, `xhci-mtk.h`,
  `xhci-mtk-sch.c`, `drivers/phy/mediatek/phy-mtk-tphy.c` (GPL; used for
  hardware facts only).
- U-Boot v2026.10: `drivers/usb/host/xhci-mtk.c`,
  `drivers/usb/host/xhci.c`, `drivers/phy/phy-mtk-tphy.c`.
- Device tree: `mt7986a.dtsi` and `mt7986a-bananapi-bpi-r3.dts` in
  `sys/contrib/device-tree/src/arm64/mediatek/`.
- Banana Pi BPI-R3 schematics (V1.1 public and the official set): USB 3.0
  port, USB hub and mini PCIe sheets.
- eXtensible Host Controller Interface for USB, revision 1.2, section
  6.2.3 (Endpoint Context).
- FreeBSD: `sys/dev/usb/controller/generic_xhci.c`,
  `sys/dev/usb/controller/dwc3/dwc3.c`, `sys/dev/phy/phy.c`.

# Ethernet: MT7986 frame engine, MDIO bus and MT7531 switch

The MT7986 frame engine (FE) has two GMACs that share one set of DMA
engines. On the BPI-R3, GMAC0 has a fixed 2.5 Gbit/s link to the CPU port
of an MT7531 switch with five gigabit RJ45 ports, and GMAC1 goes to the
left SFP cage. FreeBSD support is an interrupt-driven FE driver
(`mtketh`), an MDIO bus on top of it, and an etherswitch(4) driver for the
MT7531 (`mt7531sw`). They bring the whole path up from reset without help
from U-Boot and run at gigabit line rate with checksum, TSO and VLAN
offload.

The frame engine is a small network processor that happens to have an
Ethernet driver attached. Most of the work was finding out which of its
many blocks can be left alone, and then leaving them alone on purpose
rather than by accident.

## Status

| Part | State |
|---|---|
| mtketh, GMAC0 | Working: interrupts, checksum offload, TSO, VLAN insert/strip, MIB counters |
| mtketh, GMAC1 | Not enabled: needs in-band link status and SFP handling |
| MDIO bus (`mtkmdio`) | Working; carries the MT7531 |
| mt7531sw | Working: five RJ45 ports, VLAN table, etherswitchcfg(8); hardware reset when a GPIO driver is present |
| Switch port 5, SFP cages | Parked on hardware: cage I2C and GPIOs work, but the test board lost a cage and the test module does not power up properly (see [SFP cages](#sfp-cages)) |
| RSS, PPE (hardware NAT), WED | Not started |

The code is on branch `bpi-r3/ethernet` of
<https://github.com/AlchemillaHQ/freebsd-src>, on top of `bpi-r3/golden`
(the series in review as D61186 to D61191 on FreeBSD Phabricator); it goes
to Phabricator once that series is in. It is five commits, each building
alone (GENERIC arm64) with no compiler warnings: a gate
flavour for the MediaTek clock code (`MTK_GATE_NO_SETCLR`), the ETHSYS and
SGMIISYS clocks and syscons (`sys/dev/clk/mediatek/mt7986_ethsys.c`), the
FE driver (`sys/arm64/mediatek/if_mtketh.c`, `if_mtkethreg.h`), the MDIO
bus (same file), and the switch (`sys/dev/etherswitch/mt7531/`).
`std.mediatek` gains `device mtketh` and `device mt7531sw`. With the
pinctrl/GPIO driver ([pinctrl.md](pinctrl.md)) the switch gets a proper
hardware reset; without it the driver keeps the switch as U-Boot left it
and works all the same.

## Hardware

```
  MT7986A FE (0x15100000)                MT7531 (25 MHz crystal)
    GDM1 GMAC0 SGMIISYS0 == 2500base-x == P6, CPU port
    GDM2 GMAC1 SGMIISYS1 == left SFP      P5, SGMII == right SFP
    MDIO (GPIO 67/68) ...... address 31   P0 wan, P1-P4 lan0-lan3
```

- ETHSYS (0x15000000) has the FE clock gates, the reset register and
  SYSCFG0. The FE (0x15100000, 0x40000 long) has PSE, GDM, CDM, QDMA,
  PDMA, the MACs and the MDIO controller. SGMIISYS0/1 (0x10060000,
  0x10070000) have the SerDes gates and the PCS. FE SRAM is not used.
- The MT7986 reference manual has the memory map but no frame engine
  chapter. The register facts here come from MediaTek's Linux driver, the
  MediaTek SDK and U-Boot, used as hardware references only, and from
  measurements on the board.
- Switch: MDIO address 31, `reset-gpios` on GPIO 5, interrupt on EINT 66.
  Ports 0-4 have internal gigabit PHYs. TOP_SIG_SR (0x780c) bit 1 says
  port 5 is SGMII too ("dual SGMII").
- 2.5G uses the 1000 speed code in the GMAC MCR and the switch PMCR. The
  rate comes from the PCS line rate (3.125 Gbaud).

### Data path

| Path | TX | RX | Used by |
|---|---|---|---|
| A | QDMA, 32-byte TXD, linked list plus free queue | PDMA at 0x4000, 16-byte RXD | mainline Linux, MediaTek SDK |
| B | PDMA v2 at 0x6000, 32-byte TXD | PDMA v2, 32-byte RXD | U-Boot |

FE_GLO_MISC (0x124) bit 4 selects path B. We use path A: it is what
MediaTek ships, and its interrupts and offloads are known from the vendor
driver. Path B worked for an early polled prototype, but its interrupts
and offload bits are undocumented, and "undocumented" is not a feature
you want in a DMA engine. Both GMACs share one TX ring and one RX ring.

| Word | Bits |
|---|---|
| txd1, txd2 | buffer address; next descriptor (set once at ring init) |
| txd3 | 31 OWNER_CPU, 30 LS0, 23:8 length (16 bits) |
| txd4 | 30 SWC, 21:16 QID, 11:8 FPORT (1 = GDM1, 2 = GDM2) |
| txd5, txd6 | 31 TSO, 30:28 checksum insert; 16 insert VLAN, 15:0 TCI |
| rxd1, rxd2 | buffer address; 31 DDONE, 30 LS0, 29:16 length, 15 VLAN stripped |
| rxd3, rxd4 | 15:0 TCI; 21:19 source GDM, 22 special tag, 24 L4 checksum valid |

- TX starts when QTX_CTX_PTR (0x4700) is written with the next free
  descriptor; the owner bit alone does nothing. The driver reclaims up to
  QTX_DRX_PTR (0x4714) and writes back QTX_CRX_PTR (0x4710).
- QDMA needs a free queue for its own use: 2048 descriptors pointing at
  2 KiB pages (0x4720-0x472c). RX re-arm is rxd1/rxd2, then CRX_IDX
  (0x4108).
- Linux also enables a QDMA RX ring that it never services. We leave QDMA
  RX off and have seen no effect, other than a ring that no longer waits
  forever for attention.

### Clocks, resets and PCS

- Gates are single bits at ETHSYS 0x30 and SGMIISYS 0xe4, set while
  running, with no set/clear registers ([clocks.md](clocks.md)). The
  firmware leaves all of them on.
- ETHSYS and SGMIISYS are also syscons, registered by the clock driver
  under the gate lock so `syscon_generic` does not take them. The FE
  driver uses ETHSYS RSTCTRL (0x34: bit 6 FE, 23 GMAC, 30/31 PPE0/1),
  FE_RST_CHK_IDLE_EN (0x28) and SYSCFG0 (0x14: GE_MODE 2 bits at 12 + 2n,
  0 for SGMII; path select bit 9 for GMAC0, bit 8 for GMAC1).
- FE reset (Linux NETSYS v2 order; the node has no `resets`): IDLE_EN = 0,
  set RSTCTRL bits 31, 30, 23 and 6, wait 1 ms, clear, wait 10 ms,
  IDLE_EN = 0x3ffffff.
- PCS (SGMIISYS offsets), 2500base-x without in-band AN: PHYA down (0xe8
  bit 4), soft reset (0x34 bit 0), ANA_RGC3 (0x128) bits 3:2 = 1 (3.125G;
  0 is 1.25G), link timer (0x18), clear SGMII_MODE (0x20) bits 0, 1 and 8,
  clear BMCR AN enable (0x00 bit 12), wait 100 us, write 0 to all of 0xe8.
  The MT7531 has the same PCS for ports 5 and 6, at 0x5000 and 0x6000.

## FreeBSD drivers

### mtketh

- Plain ifnet, not iflib: iflib ties one DMA context to one ifnet, but
  two GMACs share the rings here, like flatmates sharing one fridge. One device owns the FE and creates an
  ifnet per enabled `mediatek,eth-mac` child (`mtketh0` = GMAC0). One
  mutex covers the rings; `if_input()` runs without it.
- Only fixed links in 2500base-x or 1000base-x so far. GMAC1 on the BPI-R3
  (`sfp`, `managed = "in-band-status"`) is skipped. Media is `IFM_2500_X`
  with pause; other FreeBSD 2.5G drivers use `IFM_2500_T`.
- Rings: 1024 TX descriptors, a 2048 x 2 KiB free queue, 1024 RX
  descriptors with 2 KiB clusters, all in DRAM through busdma with 32-bit
  DMA addresses.
- Attach: clocks, FE reset, clear FE_GLO_MISC bit 4, MDC, PSE thresholds
  (vendor table), GDMs to drop, MACs forced down, rings; per MAC SYSCFG0,
  PCS, MCR and GDM MAC address; a PSE reset pulse (RST_GL bit 0); DMA,
  interrupts, ifnets, MDIO bus. Nothing the boot loader left is used.
  Shutdown stops the DMA.
- MAC_MCR(n) (0x10100 + 0x100n) ends as 0x0305f33b: MAX_RX 2048, forced
  mode, 1000 code, full duplex, forced pause, link. GDMA_FWD_CFG(n)
  (0x500 + 0x1000n) sends to PDMA (destination nibbles 0) with FCS strip
  (bit 16) while up, to drop (7) while down.
- Interrupts: fe1 for TX done (QDMA status 0x4618 bit 28), fe2 for RX done
  (PDMA status 0x4220 bit 30), grouped as Linux does; six lines unused.
  DELAY_INT (0x420c, 0x460c) has an RX half (bit 15 enable, 14:8 frames,
  7:0 time in 20 us) and a TX half in 31:16. The driver uses RX 8 frames
  or 20 us, TX 16 frames or 40 us (`dev.mtketh.0.delay_int`).
- A 1 Hz tick reads link (PCS BMSR and MAC MSR), the MIB counters and
  FE_INT_STATUS2 (`dev.mtketh.0.int_status2`).

### MDIO bus

`mtkmdio` attaches to the `mdio-bus` node as a simplebus subclass, so
`switch@31` probes by compatible string. mtketh provides `mdio_readreg`
and `mdio_writereg` (Clause 22, PHY_IAC at 0x10004) under its own lock.
PPSC (0x10000) bits 29:24 divide 25 MHz to the node's `clock-frequency`
(default 2.5 MHz); bit 20 is MDC turbo.

### mt7531sw

- Switch registers are 32 bits, over Clause 22 at address 31: write reg
  0x1f = addr >> 6, then the low half at reg (addr >> 2) & 0xf and the
  high half at reg 0x10. Write the low half first; the high half commits.
  The PHYs sit behind the switch's own PHY_IAC (0x701c, also Clause 45).
- Bring-up: `reset-gpios` low for 5 ms, poll the strap register (0x7800)
  until non-zero, check CREV (0x781c) = 0x7531 (rev 1 here). Force every
  PMCR down, software reset (0x7000), MDC Schmitt trigger (0x7f04 bit 5),
  PHY PLL on, EEE not advertised, CPU port PCS and PMCR6 = 0xf805633b,
  port 5 forced down, PHYs up with downshift and link-down power saving.
  Without a GPIO provider the reset is skipped and the state kept.
- The CPU port is the one whose DT node has an `ethernet` property.
- FreeBSD has no DSA tag layer, so the MediaTek special tag stays off.
  Every port forwards by the VLAN table (PCR VLAN mode 3), floods to all
  ports (MFC) and tags on egress as the table says (PVC EG_TAG 0). VLAN 1
  holds every port untagged and is every PVID: a plain switch.
- etherswitch(4): DOT1Q, 16 VLAN groups with group n = VID n, PVID and
  media per port, register and PHY access. Ports 0-4 have a miibus with
  ukphy, polled once a second; ports 5 and 6 report PMSR. The VLAN table
  code follows mtkswitch(4), the older MMIO-only MT7620/MT7621 driver.
- The switch MIB counters (for example 0x4N68, port N RX unicast) do not
  clear on read. `etherswitchcfg reg` reads them; they are not exported.

Ports are separated with 802.1Q and vlan(4) on the CPU interface, as with
e6000sw and mvneta. To put the wan jack on its own VLAN:

```
etherswitchcfg vlangroup2 vlan 2 members 0,6t
etherswitchcfg vlangroup1 vlan 1 members 1,2,3,4,5,6
etherswitchcfg port0 pvid 2
ifconfig vlan2 create vlan 2 vlandev mtketh0
```

## Offloads

- **Checksum:** TX sets txd5 30:28 on the first descriptor (IPv4 header;
  TCP and UDP over IPv4 and IPv6). On RX, rxd4 bit 24 means the GDM
  checked TCP/UDP, and the driver sets `CSUM_DATA_VALID |
  CSUM_PSEUDO_HDR`. With the GDM checks on (GDMA_FWD_CFG bits 22/21/20),
  frames with a bad checksum are dropped and only counted (verified with
  UDP), so RXCSUM switches those checks too.
- **TSO (IPv4, IPv6):** txd5 bit 31 plus the checksum bits. The MSS goes
  in the TCP checksum field, replacing the pseudo-header sum; the
  hardware fills in each segment's checksums. A 64 KB frame takes up to
  35 descriptors. Turning TXCSUM off turns TSO off.
- **16-byte minimum TX segment:** MediaTek documents that TX DMA on every
  NETSYS version must not get a segment under 16 bytes (SDK patch
  `999-eth-56-mtk_eth_soc-remove-netsys-v1-restriction-for-small-frag-`
  `check`). Such chains go through `m_defrag()`, then 16 bytes move from
  the second-to-last cluster into the short last one. Before this, about
  6.5% of non-TSO TCP frames had such a segment (data straddling two
  socket buffer clusters); no failure was traced to it.
- **VLAN:** insertion is txd6 bit 16 plus the TCI. Stripping is
  CDMP_EG_CTRL (0x404) bit 0, one switch for both GMACs, on while either
  interface has VLAN_HWTAGGING. vlan(4) interfaces keep checksum offload
  and TSO.
- **GDM MIB counters** (0x1c00 + 0x40n): RX bytes (64-bit), frames,
  overflow, FCS, short, long, checksum, pause; TX skip, collisions, bytes
  (64-bit), frames. They clear on read (a register dump loses them), so
  the tick and stop path accumulate them into `dev.mtketh.0.macN.*`.
  `if_get_counter` adds them to IERRORS (FCS, short, long, checksum),
  IQDROPS (overflow), OERRORS (skip) and COLLISIONS. Bytes include FCS.
- **Not available:** MediaTek's driver has hardware LRO only on MT7988.
  RSS exists on MT7986 (see Open items).

Offloads are free performance, paid for in pitfalls; the bill is itemized
below.

## Performance

iperf3 against one host on a gigabit switch port, so about 940 Mbit/s is
TCP line rate, and the switch port, not the board, is the limit. WITNESS and INVARIANTS cost about 3x per packet; these
numbers are from a kernel with `include "std.nodebug"` and direct netisr
dispatch.

| Test | Result | Busiest core |
|---|---|---|
| TCP RX, 1 flow | 942 Mbit/s, 0 retransmits | 75% (RX interrupt) |
| TCP RX, 4 flows | 943 Mbit/s | 76% |
| TCP TX, 1 flow, TSO | 941 Mbit/s, 0 retransmits | 15% |
| UDP 64-byte RX | 293k pps, 0% loss | 100% (RX interrupt) |
| Same, deferred netisr | 318k pps | 81% (sender may be the limit) |

- One RX interrupt thread runs the whole input path, so receive is bound
  to one core. Deferred netisr moves IP and TCP off it (TCP RX core 36%),
  but `net.inet.ip.intr_queue_maxlen` must be raised (2048) or the IP
  queue drops packets.
- On debug kernels, TSO cut sender CPU from 80% to 41% at 946 Mbit/s, and
  turning VLAN tagging off cut vlan(4) TX from 946 to 727 Mbit/s at 96%.
- Without TSO, line-rate TCP TX shows a few dozen retransmits per run.
  In one run 67 retransmits matched 67 if_snd drops (queue of 1023); the
  switch and the host dropped nothing. TSO sends far fewer packets.
- The switch sends pause frames to GMAC0 during TX: the 2.5G CPU link
  feeds a 1G port.

## Testing

- iperf3 (TCP 1 and 4 flows, UDP at fixed rates, both directions) with
  per-core load from `kern.cp_times`. A 200 MB file over IPv4, IPv6 and
  vlan(4) with TSO kept its SHA256; a 60 s bidirectional soak (924 + 643
  Mbit/s) had no errors.
- SGMIISYS0 and SYSCFG0 were set back to unconfigured values at the
  U-Boot prompt, and the link still came up. 20 `ifconfig down/up`
  cycles, three warm reboots, and boots after U-Boot used its network
  (stale DMA) passed.
- 50 UDP datagrams with bad checksums were dropped by the GDM and counted
  as input errors; with `-rxcsum` the stack saw them.
- One cable moved across all five RJ45 ports: link changes showed within
  the 1 s poll, and frames reached the CPU 0.3-1.2 s after link-up.
- WAN/LAN separation with the commands above; untagged `mtketh0` got no
  DHCP offer once port 0 was in VLAN 2.
- Bridging: `mtketh0` in an `if_bridge` with a bhyve guest's `tap`. The
  bridge put `mtketh0` in promiscuous mode, the guest got its own DHCP
  lease from the LAN, and guest to LAN TCP ran at 941 Mbit/s (825 Mbit/s
  the other way) with no `mtketh0` errors. Details in
  [bhyve.md](bhyve.md).

## Pitfalls

- **RX L4-valid is rxd4 bit 24** (MediaTek SDK), not bit 2 (the mainline
  Linux NETSYS v2 define). In one run bit 24 was set on 3,686,134 of
  3,686,240 frames (the rest ARP and other non-TCP/UDP); bit 2 never.
- **QDMA TX-done ignores DELAY_INT.** 16 frames/40 us, 64/80 us and
  127/200 us all gave about 22,000 TX interrupts per second at 946 Mbit/s.
  Taking the TX interrupt only on a full ring was no cheaper.
- **The RX-done status bit does not re-arm,** so the handler loops until
  the ring is empty (256 frames per pass) instead of returning after one
  budget.
- **PCS power:** clear all of 0xe8, not just bit 4. Writing 0x10 from
  U-Boot reads back 0x19; clearing only bit 4 leaves 0x9, which the Linux
  driver says gives link but no traffic. Whether the PCS soft reset clears
  itself is unknown; the driver clears it.
- **SGMIISYS is outside the FE reset,** so U-Boot's PCS state survives.
  U-Boot's stop path disables PDMA and forces switch ports 5 and 6 down
  but leaves the ring bases pointing into its memory: reset the FE.
- **MT7531 PVC EG_TAG must be 0** for VLAN-aware ports. With "consistent"
  (1) egress follows the ingress tag state, so untagged frames reached
  the CPU untagged although the CPU port was a tagged member.
- **MT7531 core PLL:** its setup is for an RGMII port 5. In dual SGMII,
  Linux keeps the reset configuration and so do we; U-Boot programs it.
- **U-Boot leaves the MT7531 PHY page register at 1;** set it back to 0.
  U-Boot also sets PPSC bit 4 where MDC turbo is bit 20.
- **vlan(4) enables TSO on VLAN_HWTSO alone,** without VLAN_HWTAGGING,
  and then sends TSO frames with the tag in the data. Clear VLAN_HWTSO
  when tagging is off, as re(4) does; before that fix `-vlanhwtag` cut
  vlan(4) TX to 2.79 Mbit/s.
- **Two board ports on one LAN make a loop:** all ports share VLAN 1 by
  default and nothing runs STP on the switch. Moving a cable "just to test
  something" also moves the board's only network path, which is how you
  learn to keep a serial console attached.
- **Far-end bridges delay data:** an 802.1D bridge with an 8 s forward
  delay held each new link for about 16 s; the board forwarded from
  link-up. U-Boot's first DHCP after a warm reboot often fails and a
  retry works; that delay is the likely cause, not verified.

## SFP cages

SFP1 (left, "wan") is wired to GMAC1 through SGMIISYS1. SFP2 (right,
"lan") is wired to MT7531 port 5, so SFP2 support belongs in mt7531sw.

| Cage | SDA / SCL | MOD_DEF0 | LOS | TX_FAULT | TX_DISABLE |
|---|---|---|---|---|---|
| SFP1 | GPIO 16 / 17 | 49 | 46 | 7 | 20 |
| SFP2 | GPIO 18 / 19 | 47 | 31 | 48 | 15 |

- The I2C buses are `i2c-gpio` nodes; `gpioiic` attaches to them (not in
  GENERIC) and works at a 5 us bit delay (100 kHz). For a NACK, I2CRDWR
  returns the raw iicbus code (IIC_ENOACK, 2), which i2c(8) prints as
  ENOENT. The i2c(8) `-o` offset is hex.
- Not all cage pins are GPIOs at boot (pin 49 starts as UART2). Switch
  them with `gpioctl -c N IN PU` before trusting a reading.
- SFP2 TX_DISABLE has a 1K pull-down, so it idles low (TX enabled).

Work stopped on hardware. The SFP1 cage, already loose, finished the job
and came off our test board, and the only module, an RJ45 2.5G copper SFP,
answers I2C in SFP2 only while TX_DISABLE is driven high. Released, it goes silent within about 1 ms (no
I2C, no copper link, LOS and TX_FAULT read high); asserted again, it
answers after 38 ms. It behaves as if powered through TX_DISABLE rather
than the cage 3.3 V: a module that only lives while you tell it to be
quiet. Port 5 PCS at 2500base-x with PMCR5 forced up changed nothing, and
no Linux quirk covers "runs on the wrong pin". A known-good module is
needed.

Its A0h EEPROM (SFF-8472) shows identifier 0x03 (SFP), connector 0x07
(LC), nominal 2.5 GBd, vendor "OEM", part "SFP-2.5G-T", revision "1.0",
850 nm and no Ethernet compliance code. LC and 850 nm do not fit an RJ45
module; the EEPROM appears to have been copied from a fibre module and
never looked at again. The A2h diagnostics never change, so they are not measured, and
address 0x56 reads zeros (no PHY). Linux has a quirk for this part
(2500base-x, no autonegotiation, no PHY access) and says the MediaTek PCS
cannot do in-band status at 2500base-x, although the DT asks for in-band
status on GMAC1 and port 5. We have not checked that.

## Open items

- Hardware LAN-to-LAN switching at line rate and routed forwarding: both
  need a second host on the LAN side.
- RSS: deferred until a forwarding test shows one core is the limit; it
  should matter only for small packets above about 300k pps. MediaTek's
  SDK uses ring 0 plus three RSS rings on MT7986, and the DT lists the
  pdma0-3 interrupts. An RSS series under review on the Linux netdev list
  targets MT7988. It needs per-ring locks and TX rework.
- GMAC1 and both cages: in-band link status, module detection, and a
  minimal policy until FreeBSD has an SFP framework. Needs a board with
  both cages attached and a module that uses its power pins. Since the
  surviving cage is SFP2, the first SFP link will be on MT7531 port 5,
  whose PCS already comes up with the same code as the CPU port.
- PPE hardware NAT: needs a flow offload framework in FreeBSD.
- mt7531sw: switch interrupt (EINT 66) instead of polling, MIB counters as
  statistics, VLAN IDs above 15.
- mtketh: MTU above 1500 (the MAC takes 2048-byte frames), detach, FE
  error recovery, fewer TX interrupts, 802.1ad and PCP checks.
- For review: `IFM_2500_X` or `IFM_2500_T`; internal ifnets or one child
  device per GMAC.

## References

- MT7986A Reference Manual for BPI-R3, v1.0 (memory map only for NETSYS).
- Linux v6.12 `drivers/net/ethernet/mediatek/mtk_eth_soc.[ch]`,
  `drivers/net/pcs/pcs-mtk-lynxi.c`, `drivers/net/dsa/mt7530.[ch]`,
  `drivers/clk/mediatek/clk-mt7986-eth.c`, `drivers/net/phy/sfp.c`;
  U-Boot v2025.10 `drivers/net/mtk_eth/`; the MediaTek SDK
  (mtk-openwrt-feeds) `mtk_eth_soc` driver and the 16-byte patch above.
- DT `mt7986a.dtsi` and `mt7986a-bananapi-bpi-r3.dts`; bindings
  `net/mediatek,net.yaml`, `net/pcs/mediatek,sgmiisys.yaml`,
  `clock/mediatek,ethsys.yaml`, `net/dsa/mediatek,mt7530.yaml`.
- SFF-8472, the SFP management interface.
- FreeBSD etherswitch(4), etherswitchcfg(8), vlan(4), gpioiic(4),
  mtkswitch(4), e6000sw and mvneta (the switch plus vlan(4) model),
  `sys/dev/qcom_ess_edma`, `sys/dev/dpaa2/memac_mdio_fdt.c`.

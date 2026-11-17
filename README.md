# FreeBSD on the Banana Pi BPI-R3

> [!NOTE]
> **TL;DR:** want FreeBSD on your BPI-R3? Download an image from
> [Releases](https://github.com/AlchemillaHQ/FreeBSD-BPI-R3/releases) and
> follow [INSTALL.md](INSTALL.md).

We started this for selfish reasons: our bhyve and arm64 `vmm` work
needs real arm64 hardware, not an emulator (QEMU/TCG), and we did not
want to pay an arm (pun fully intended) and a leg for an Ampere system.

The BPI-R3 does the job. Its firmware enters the kernel at EL2, it has a
GICv3, and bhyve runs on it, for a fraction of the price of a
server-class machine.

It deserves more than being our VM host, though: it is full of hardware
worth driving, and anyone should be able to buy one and run FreeBSD on
it.

This work is sponsored by [Alchemilla](https://alchemilla.io). Bring-up
and driver work is what Alchemilla does for its clients: brand-new SoCs,
and older or more obscure ones whose vendors never shipped good driver
support. Those projects end with write-ups like the notes here, so the
client's engineers inherit what we learned instead of rediscovering it.
The BPI-R3 is public hardware, so this time the notes can be public too.
They double as a field guide for new and experienced contributors alike:
what driver development on a real board involves, from register-level
detail to the problems no datasheet mentions, such as finding
documentation that barely exists and deciding which of several
conflicting sources to believe.

## What this repository is

This repo mainly contains our notes on running FreeBSD on the BPI-R3, a
router board built around the MediaTek MT7986A (Filogic 830,
four Cortex-A53 cores), with five gigabit ports, two SFP cages, USB,
an M.2 slot and a row of boot DIP switches. The goal is upstream
FreeBSD support: a stock `GENERIC` kernel and the stock device tree, with
no vendor kernel, no patched tree and no mystery binaries.

The drivers are written from scratch for FreeBSD. Linux, U-Boot and
MediaTek's documentation are used only as references for how the hardware
behaves; no code is copied from them. Where the documentation is silent,
which is often, the board itself was asked, one register read at a time.

LLMs were used to do exploration of much of the scarce documentation especially
those from MediaTek etc. which are not easy to come by. But all the docs,
code in this repository and also [AlchemillaHQ/freebsd-src](https://github.com/AlchemillaHQ/freebsd-src)
were fully written, reviewed and tested extensively by us, so you may find
human slop which we are happy to get reviewed and addressed but not machine slop.

## Try it

Ready-to-flash images are built by the
[Images workflow](.github/workflows/images.yml), in a normal and a
debug flavour: an SD card image, and an installer that puts FreeBSD on
the board's eMMC using nothing but an SD card.
[INSTALL.md](INSTALL.md) explains how to write one to a card, set the
boot switches and log in.

## Status

Nothing is in the FreeBSD tree yet. If you are an ARM64 src committer, **please contact us** at
[hello@alchemilla.io](mailto:hello@alchemilla.io).
The first series (SoC support, clocks, resets, the UART, and three small changes to
FreeBSD's shared 16550 UART code that the UART driver needs) is in review on Phabricator;
everything else is well tested, ready for review and waiting its turn. We want to get the
[golden](https://github.com/AlchemillaHQ/freebsd-src/tree/bpi-r3/golden) SoC stack
merged before we take up any more of upstream reviewers' time, as that would be a solid
sign that the work we've done here is coherent enough to be merged upstream.

| Part                                            | State                                                                                                                                        | Code                                                                                                          |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| SoC support, clocks and resets                  | In review                                                                                                                                    | [D61186](https://reviews.freebsd.org/D61186) to [D61190](https://reviews.freebsd.org/D61190), `bpi-r3/golden` |
| Baud rate generator hooks in the 16550 code     | In review (needed by the UART)                                                                                                               | [D61610](https://reviews.freebsd.org/D61610), [D61620](https://reviews.freebsd.org/D61620), [D61611](https://reviews.freebsd.org/D61611), `bpi-r3/golden` |
| UART                                            | In review                                                                                                                                    | [D61191](https://reviews.freebsd.org/D61191), `bpi-r3/golden`                                                 |
| SD card and eMMC                                | Ready for review (eMMC HS400, about 170 MB/s)                                                                                                | `bpi-r3/mmc`                                                                                                  |
| Ethernet and the MT7531 switch                  | Ready for review (about 940 Mbit/s TCP both ways, checksum offload, TSO, VLAN offload)                                                       | `bpi-r3/ethernet`                                                                                             |
| USB (xHCI and USB PHY)                          | Ready for review: USB 2.0 devices, and full-speed keyboards since a small xHCI hook; USB 3.0 devices and devices behind a hub not tested yet | `bpi-r3/usb`                                                                                                  |
| Pin control, GPIO, external interrupts          | Ready for review                                                                                                                             | `bpi-r3/pinctrl`                                                                                              |
| Watchdog and reset                              | Ready for review                                                                                                                             | `bpi-r3/watchdog`                                                                                             |
| SFP cages                                       | Parked: cage I2C and GPIOs work, but our test board lost a cage and the test module will not power up properly                               |                                                                                                               |
| PCIe (M.2 NVMe), Wi-Fi, SPI flash, hardware NAT | Not started                                                                                                                                  |                                                                                                               |

The board also runs bhyve: arm64 guests such as Alpine Linux boot on it
and reach the LAN through a bridge at gigabit line rate, so a dev board
that runs virtual machines is now a thing you can have.

## Branches

The code lives on `bpi-r3/<feature>` branches of
[AlchemillaHQ/freebsd-src](https://github.com/AlchemillaHQ/freebsd-src):

- `bpi-r3/golden` is the series under review, including the three 16550
  changes, rebased on current FreeBSD `main`. Every other branch sits on
  top of it.
- `bpi-r3/mmc`, `bpi-r3/ethernet`, `bpi-r3/usb`, `bpi-r3/pinctrl` and
  `bpi-r3/watchdog` each add one feature. Every commit builds on its own
  with no compiler warnings.
- `bpi-r3/integration` stacks all of them on `bpi-r3/golden`. It is the
  kernel the board runs and the one our CI builds; it is regenerated
  whenever a feature branch changes, so do not base work on it.
- When the golden series lands in FreeBSD (with new hashes, as reviewed
  commits always get), the feature branches move onto `main` and go to
  review one by one.

Each feature branch builds and works on its own, but a useful board
needs `bpi-r3/mmc` too: without it there is no SD card to put the root
file system on. If you just want a kernel that boots and does
everything, use `bpi-r3/integration`.

## Firmware

The board's boot firmware (TF-A and U-Boot) can be built from FreeBSD
ports instead of taken from OpenWrt. Firmware built this way boots
FreeBSD from both SD and eMMC, and the whole boot chain comes from source
in the ports tree.

| Port                             | State     | Review                                       |
| -------------------------------- | --------- | -------------------------------------------- |
| sysutils/fiptool                 | Accepted  | [D61533](https://reviews.freebsd.org/D61533) |
| sysutils/atf-mt7986              | Accepted  | [D61536](https://reviews.freebsd.org/D61536) |
| sysutils/u-boot-bananapi-r3      | Accepted  | [D61539](https://reviews.freebsd.org/D61539) |
| sysutils/u-boot-bananapi-r3-emmc | Accepted  | [D61540](https://reviews.freebsd.org/D61540) |

## Notes

One write-up per piece of work: the hardware, the driver design, how it
was tested, what went wrong, and what is left.

- [Clocks, resets and SoC support](notes/clocks.md)
- [UART](notes/uart.md)
- [Pin control, GPIO and external interrupts](notes/pinctrl.md)
- [Watchdog and reset](notes/watchdog.md)
- [SD card and eMMC](notes/mmc.md)
- [Ethernet, the MT7531 switch and SFP](notes/ethernet.md)
- [USB](notes/usb.md)
- [bhyve](notes/bhyve.md)
- [Boot firmware ports](notes/firmware.md)
- [Booting and image layout](notes/booting.md)

## Acknowledgements

- [Rainy Mathew](mailto:rainy@alchemilla.io) wrote the first working
  versions of the clock and MMC drivers, which proved early on that the
  port was possible without a huge investment of time. She also worked
  on much of the documentation here, prying the facts out of our
  MediaTek vendor or piecing them together from git repositories
  scattered across the internet.
- [Hayzam Sherif](mailto:hayzam@freebsd.org) reviewed and helped write
  most of the drivers, and served as Rainy's meat proxy: Rainy and the
  board were in different states in India, and running her commands on
  it was easier than getting the board to her.

## License

BSD-2-Clause, see [LICENSE](LICENSE).

Use the drivers and the notes however you like. If you do, we would love
to hear how you use them: [open an issue](https://github.com/AlchemillaHQ/FreeBSD-BPI-R3/issues)
on this repository. That is a request, not a condition of the license, and in
return we may be able to help, (mostly) gratis.

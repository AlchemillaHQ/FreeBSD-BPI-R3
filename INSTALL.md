# Trying FreeBSD on your BPI-R3

This gets FreeBSD running on a Banana Pi BPI-R3 from a microSD card,
and, if you like, from the onboard eMMC
([Installing to the eMMC](#installing-to-the-emmc)). Running from the SD
card does not touch the board's SPI-NAND, SPI-NOR or eMMC, so going back
to whatever the board shipped with is a matter of flipping the DIP
switches back.

## What you need

- A Banana Pi BPI-R3 and its 12 V power supply.
- A microSD card, 8 GB or larger.
- An Ethernet cable to a network with DHCP.
- Optional but strongly recommended: a USB to 3.3 V TTL serial adapter
  for the debug console.

## 1. Pick an image

Images are built by this repository's
[Images workflow](https://github.com/AlchemillaHQ/FreeBSD-BPI-R3/actions/workflows/images.yml)
from the `bpi-r3/integration` branch of
[AlchemillaHQ/freebsd-src](https://github.com/AlchemillaHQ/freebsd-src)
and the newest official FreeBSD 16.0-CURRENT arm64 snapshot. Tagged
builds are on the
[Releases](https://github.com/AlchemillaHQ/FreeBSD-BPI-R3/releases)
page; every workflow run also keeps its images as artifacts for 90 days
(downloading those needs a GitHub login).

Each build has three kinds of image:

| Image                                            | What it is                                                                           |
| ------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `freebsd-16.0-current-bpi-r3-sd-...`             | FreeBSD on an SD card. Start here.                                                   |
| `freebsd-16.0-current-bpi-r3-emmc-installer-...` | An SD card that installs FreeBSD on the eMMC (see [below](#installing-to-the-emmc)). |
| `freebsd-16.0-current-bpi-r3-emmc-...`           | The eMMC image itself, for writing the eMMC some other way.                          |

and each comes in two flavours:

| Flavour              | Kernel                                          | Use it for                                                                                                                                                                       |
| -------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `...-nodebug.img.xz` | `GENERIC-NODEBUG`                               | Normal use. Start here.                                                                                                                                                          |
| `...-debug.img.xz`   | `GENERIC`, with WITNESS, INVARIANTS and friends | Testing and bug reports. Slower (the checks cost about three times the CPU per network packet), but it catches locking and consistency bugs that the other one quietly survives. |

In the commands below, set `IMG` to the file you downloaded, for
example:

```
IMG=freebsd-16.0-current-bpi-r3-sd-20261115-62563fc15c7f-nodebug.img.xz
```

`xz` checks the file as it unpacks it: if the download is damaged or
cut short, it stops with an error, and the card is left incomplete.
Download the file again and rewrite the card.

## 2. Write it to the card

Double-check the device name first; `dd` does not ask.

```
# Linux (the card is /dev/sdX or /dev/mmcblkN)
xz -dc "$IMG" | sudo dd of=/dev/sdX bs=1M conv=fsync status=progress

# FreeBSD (the card is /dev/daN or /dev/mmcsdN)
xz -dc "$IMG" | dd of=/dev/da0 bs=1m status=progress

# macOS (find N with "diskutil list")
diskutil unmountDisk /dev/diskN
xz -dc "$IMG" | sudo dd of=/dev/rdiskN bs=1m
```

On Windows, [balenaEtcher](https://etcher.balena.io/) writes `.img.xz`
files directly.

## 3. Set the boot switches

The four-way DIP switch SW1 selects the boot device. For the SD card,
set all four to on:

| A   | B   | C   | D   |
| --- | --- | --- | --- |
| on  | on  | on  | on  |

D also routes the shared SD/eMMC controller to the SD slot, so it has
to be on as well. The other settings are described in
[notes/booting.md](notes/booting.md).

## 4. Connect the console (optional)

Connect the adapter's GND, RX and TX to the board's 3-pin debug UART
header (TX to RX and RX to TX; leave the adapter's power pin
unconnected). The
[Banana Pi documentation](https://docs.banana-pi.org/en/BPI-R3/BananaPi_BPI-R3)
shows where it is. Use 115200 baud, 8N1:

```
cu -l /dev/cuaU0 -s 115200            # FreeBSD
picocom -b 115200 /dev/ttyUSB0        # Linux
```

## 5. Boot

Insert the card, connect any of the five RJ45 ports to your network, and
power the board on. You should see the boot ROM, TF-A, U-Boot, the
FreeBSD loader and then the kernel. On the first boot the root file
system grows to fill the card, SSH host keys are generated, and the
clock is set by NTP, so it takes a little longer than later boots.

All five RJ45 ports are one switch on one interface, `mtketh0`, which
asks for an address by DHCP. Your router's lease list, or `ifconfig
mtketh0` on the console, tells you which address it got.

FreeBSD does not use a factory-assigned MAC address on this board. On
the very first boot it picks a random one; from the second boot on it
derives a stable one from the host ID created during that first boot.
So expect a new DHCP address after the first reboot, and then the same
one from then on.

## 6. Log in

| User      | Password  |                                     |
| --------- | --------- | ----------------------------------- |
| `freebsd` | `freebsd` | in group `wheel`, can use `su`      |
| `root`    | `root`    | console only; SSH root login is off |

```
ssh freebsd@<address>
```

Change both passwords straight away (`passwd`, then `su` and `passwd`
again). The build details of your image are in `/etc/bpi-r3-image`;
please include them in bug reports.

## What works

See the [status table](README.md#status). In short: the CPUs, clocks,
console, SD card and eMMC controller, Ethernet with the switch,
USB, GPIO, the watchdog and bhyve. Not yet: Wi-Fi, PCIe and the M.2 slot,
the SFP cages, SPI flash and hardware NAT.

Packages come from the official FreeBSD repositories: `pkg install` works
as on any other FreeBSD 16.0-CURRENT arm64 machine.

## Going back

Nothing outside the SD card was changed. Power off, set SW1 back to the
setting your board shipped with (for example 1010 or 1011 to boot from
SPI-NAND), and you are back where you started.

## Installing to the eMMC

The board's 8 GB eMMC is faster than most SD cards and cannot fall out.
Installing there needs nothing but an SD card, but it does need the
serial console: the installer asks you to move a switch halfway through.

The SD card and the eMMC share one controller, and DIP switch D decides
which of the two is connected. So the installer copies everything it
needs into memory first, and only then asks you to flip D over to the
eMMC while the board keeps running.

1. Download the `freebsd-16.0-current-bpi-r3-emmc-installer-...img.xz` of the flavour
   you want and write it to an SD card exactly as in steps 1
   and 2 above.
2. Set all four switches to on (SD boot), connect the console, insert
   the card and power on.
3. The installer checks its payload and shows what it will do. Type
   `install` to go on; anything else stops without writing.
4. When it says so, flip **only switch D to off**. Do not power off; the
   board keeps running from memory. Press Enter.
5. It writes the system to the eMMC and verifies it, writes the boot
   loader into the eMMC's boot partition, enables booting from it, and
   checks all of that. This takes about five minutes.
6. Press Enter when it is done; the board halts. Unplug the power, set
   the switches to boot from the eMMC, and plug it back in:

    | A   | B   | C   | D   |
    | --- | --- | --- | --- |
    | off | on  | on  | off |

The first boot from the eMMC grows the root file system to the whole
eMMC. Logins and everything else are as above.

The installer erases the whole eMMC, including whatever was installed
there before (often OpenWrt). It does not touch the SD card, SPI-NAND or
SPI-NOR. To boot from an SD card again, set all four switches back to
on.

For people who would rather write the eMMC some other way, each build
also has the plain `freebsd-16.0-current-bpi-r3-emmc-...img.xz`. It goes to the
eMMC's main area as is; the eMMC `bl2.img` goes to its boot0 partition,
and boot0 must be enabled for booting (PARTITION_CONFIG 0x48). The
installer does exactly that, so it is the easy way. Releases include the
firmware as `bpi-r3-firmware-...tar.xz`, with a README that says where
each file goes.

## Problems

Please [open an issue](https://github.com/AlchemillaHQ/FreeBSD-BPI-R3/issues)
with the contents of `/etc/bpi-r3-image`, what you did, and the console
output if you have it. A console log is worth a thousand words, most of
them hexadecimal.

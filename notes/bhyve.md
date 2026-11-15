# bhyve

bhyve, FreeBSD's hypervisor, runs on the BPI-R3 without any
board-specific driver. The firmware enters the kernel at EL2, the
interrupt controller is a GICv3, and FreeBSD's arm64 `vmm` works on
both. An Alpine Linux guest boots with two virtual CPUs and 1 GiB of
RAM, gets its own address from the LAN through a bridge, and moves data
at gigabit line rate.

For once there is no driver to describe, only commands to type.

## Status

- Works: `vmm` (built in, or loaded as `vmm.ko`); a firmware-only guest
  reaches the U-Boot prompt; an Alpine Linux 3.24 guest boots, powers
  off cleanly, and networks through `if_bridge` and `virtio-net`.
- Tested on the 4-core Cortex-A53 board with 2 GiB of RAM, running our
  SD card image (FreeBSD 16.0-CURRENT, see [INSTALL.md](../INSTALL.md)).
- Not tested: FreeBSD guests, `e1000` and other network devices, guest
  storage performance.

## Host requirements

- **EL2 entry.** The kernel must be entered at EL2. Both firmware builds
  we use do this: the TF-A and U-Boot on the board's NAND flash, and the
  ones our images build from the FreeBSD ports (see
  [firmware.md](firmware.md)). The signs in `dmesg` are
  `generic_timer0: allocated irq for 'hyp-phys'` and
  `vgic0: <Virtual GIC v3> on gic0`.
- **Kernel.** `device vmm`, or `kldload vmm` with a `GENERIC` kernel; our
  images ship `vmm.ko`. With `vmm` present, `sysctl hw.vmm` shows
  `hw.vmm.maxcpu: 4` and `hw.vmm.maxvmms: 16`.
- **Everything else.** Storage and network for the host come from the
  board drivers (see [mmc.md](mmc.md) and [ethernet.md](ethernet.md));
  bhyve itself needs nothing else from the board.

## Guest firmware

The guest boots U-Boot from the `u-boot-bhyve-arm64` package (version
2024.07 when tested, from the FreeBSD:16:aarch64 repository). Yes, that
means U-Boot runs twice on the same board: once to boot FreeBSD, and
once more as its guest.

```
pkg install u-boot-bhyve-arm64
bhyve -D -c 1 -m 256M \
    -o bootrom=/usr/local/share/u-boot/u-boot-bhyve-arm64/u-boot.bin \
    -o console=stdio -s 0,hostbridge uboottest
bhyvectl --destroy --vm=uboottest
```

This prints the U-Boot 2024.07 banner, `DRAM: 256 MiB` and a prompt on
the terminal. `console=stdio` connects the guest UART to the terminal
that runs bhyve.

## Alpine Linux guest with bridged networking

The Alpine Linux 3.24.4 `alpine-virt` ISO for aarch64, checked against
the SHA256 that Alpine publishes. The host side of the network is a
bridge between the board's Ethernet interface and a `tap` that bhyve
opens:

```
kldload vmm if_bridge nmdm
sysctl net.link.tap.up_on_open=1
ifconfig tap0 create up
ifconfig bridge0 create
ifconfig bridge0 addm mtketh0 addm tap0 up

truncate -s 2G alpine-disk.img
bhyve -c 2 -m 1G \
    -o bootrom=/usr/local/share/u-boot/u-boot-bhyve-arm64/u-boot.bin \
    -o console=/dev/nmdm0A \
    -s 0,hostbridge \
    -s 1,virtio-blk,alpine-virt-3.24.4-aarch64.iso,ro \
    -s 2,virtio-net,tap0 \
    -s 3,virtio-blk,alpine-disk.img \
    alpine
```

The console is on an `nmdm(4)` pair, so bhyve can run in the background;
`cu -l /dev/nmdm0B` attaches to it. With the address left on `mtketh0`,
as here, `if_bridge` warns that addresses on member interfaces are
deprecated; for a lasting setup, move the address to `bridge0`.

What happened:

- U-Boot found the virtio disk, GRUB 2.14 started Linux 6.18.60-0-virt,
  OpenRC came up and root logged in on the console (`ttyAMA0`).
- `ip link set eth0 up; udhcpc -i eth0` got an address from the LAN's
  DHCP server through the bridge. This also shows that `mtketh0` passes
  frames for other MAC addresses once the bridge sets promiscuous mode.
- Pings to the router, the host and the internet answered with no loss;
  `apk` installed packages from Alpine's online repositories (the live
  ISO only lists itself, so add `main` and `community` to
  `/etc/apk/repositories` first).
- `iperf3`, TCP, 8 seconds each:

| Path | Throughput |
|---|---|
| Guest to a PC on the LAN (through the bridge) | 941 Mbit/s |
| PC to guest | 825 Mbit/s |
| Host to guest | 850 Mbit/s |
| Guest to host | 569 Mbit/s |

The first is gigabit line rate. bhyve used about 60% of one core; the
host was otherwise idle.

An earlier run without networking passed a small FAT image as a second
disk; it showed up as `/dev/vdb` and mounted with `mount -t vfat`.
`fastfetch` reported `CPU: bhyve (2)` and 968 MiB of memory, and
`poweroff` in the guest ended bhyve cleanly (with `-D`).

## Pitfalls

- Without EL2 entry there is no `vmm`. Check for the `hyp-phys` timer
  interrupt in `dmesg` first.
- The GIC has no ITS on this board ("Failed to attach ITS to this GIC").
  `vmm` and the guests above did not need it.
- The device tree has no `hyp-virt` timer interrupt (`could not allocate
  irq for optional interrupt 'hyp-virt'`). We saw no effect.
- `-D` destroys the VM when the guest powers off. After an interrupted
  run, `bhyvectl --destroy --vm=NAME` cleans up, and `stty sane` restores
  the terminal if it was left in raw mode.
- **Scripting an `nmdm` console.** `stty -f /dev/nmdm0B raw -echo` does
  not stick: the settings reset when `stty` closes the device. A reader
  that opens it afterwards has echo on, which sends the guest's output
  straight back to the guest as input; ours produced a flood of login
  attempts before we noticed. Set the mode on the reader's own
  file instead: `( stty raw -echo; cat ) < /dev/nmdm0B`.
- Adding a bridge member turns off its transmit checksum offload and TSO
  to match the `tap`, so host traffic on `mtketh0` loses those offloads
  while it is bridged.
- FreeBSD bug 300471 reports FreeBSD's own `vtnet` guest driver stopping
  after a few hours on arm64. It concerns FreeBSD guests; the Alpine
  guest above uses Linux's driver and bhyve's host side.

## Open items

- FreeBSD guests (and whether bug 300471 shows up under bhyve here).
- Guest storage and CPU performance; `e1000` and other network devices.
- A bridged setup that survives reboots: `rc.conf` entries for the
  bridge and the modules, and an installed guest instead of the live
  ISO.

## References

- bhyve(8), bhyvectl(8), if_bridge(4), nmdm(4).
- The `u-boot-bhyve-arm64` package in the FreeBSD ports tree.
- Alpine Linux downloads, "Virtual" image for aarch64.
- FreeBSD bug 300471, "arm64 virtio-net (vtnet) breaks after a few
  hours".

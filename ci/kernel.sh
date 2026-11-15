#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Build an arm64 kernel and its modules, and install it with a METALOG.
# On FreeBSD this is a plain cross build with the base system's clang; on
# Linux it goes through tools/build/make.py, the way FreeBSD's own CI does.
# Also builds the board DTB and the SD and eMMC overlays from the tree's
# device-tree sources.
#
#	kernel.sh SRCDIR OUTDIR [KERNCONF]
#
# OUTDIR receives kernel.txz (boot/kernel, owned by root), dtb/ and
# kernel-info.
set -eu

src=$(cd "$1" && pwd)
out=$2
kernconf=${3:-GENERIC}
jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
bsdtar=$(command -v bsdtar || echo tar)

mkdir -p "$out"
out=$(cd "$out" && pwd)
export MAKEOBJDIRPREFIX=${MAKEOBJDIRPREFIX:-$out/obj}
mkdir -p "$MAKEOBJDIRPREFIX"	# make.py insists that it exists

# Compile through ccache when CCACHE_DIR is set and ccache is installed:
# the tree's own WITH_CCACHE_BUILD support, which the kernel and module
# builds honour.  The CI keeps CCACHE_DIR between runs.
ccache_args=
if [ -n "${CCACHE_DIR:-}" ] && command -v ccache >/dev/null; then
	ccache_args="WITH_CCACHE_BUILD=yes CCACHE_BIN=$(command -v ccache)"
	mkdir -p "$CCACHE_DIR"
	ccache -z >/dev/null
fi

# Give the build every tool by full path.  Otherwise it builds its own
# compiler, or at least compiles all of LLVM for its own llvm-ar and
# llvm-objcopy (Makefile.inc1, LLVM_BINUTILS_BOOTSTRAP).
case $(uname -s) in
FreeBSD)
	b=${TOOLCHAIN_BINDIR:-/usr/bin}
	mk() {
		make -C "$src" TARGET=arm64 TARGET_ARCH=aarch64 \
		    XCC="$b/cc" XCXX="$b/c++" XCPP="$b/cpp" XLD="$b/ld.lld" \
		    XAR="$b/ar" XNM="$b/nm" XOBJCOPY="$b/objcopy" \
		    XSIZE="$b/size" XSTRINGS="$b/strings" XSTRIPBIN="$b/strip" "$@"
	}
	;;
*)
	llvm=${LLVM_BINDIR:-/usr/lib/llvm-18/bin}
	mk() {
		"$src/tools/build/make.py" --cross-bindir="$llvm" \
		    TARGET=arm64 TARGET_ARCH=aarch64 \
		    XAR="$llvm/llvm-ar" XNM="$llvm/llvm-nm" \
		    XOBJCOPY="$llvm/llvm-objcopy" XSIZE="$llvm/llvm-size" \
		    XSTRINGS="$llvm/llvm-strings" XSTRIPBIN="$llvm/llvm-strip" "$@"
	}
	# Bootstrap bmake first, without -j, as FreeBSD's CI does.
	(cd "$src" && mk -n)
	;;
esac

cd "$src"
mk -j"$jobs" -s $ccache_args kernel-toolchain
mk -j"$jobs" -s $ccache_args buildkernel KERNCONF="$kernconf"
[ -z "$ccache_args" ] || ccache -s
rm -rf "$out/root"
mkdir -p "$out/root" "$out/dtb"
mk -s installkernel KERNCONF="$kernconf" DESTDIR="$out/root" -DNO_ROOT
# NO_ROOT keeps the build user's ownership; the image wants root:wheel.
"$bsdtar" -C "$out/root" --uid 0 --gid 0 --uname root --gname wheel \
    -cJf "$out/kernel.txz" boot

# DTB with symbols (-@) so the loader can apply an overlay, and the
# overlays that enable MSDC0 for the SD card or the eMMC.
dts=$src/sys/contrib/device-tree
dtc_one() {	# source output
	cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
	    -I "$dts/include" -I "$dts/src/arm64/mediatek" \
	    -I "$dts/src/arm64" "$1" > "$out/dtb/tmp.dts"
	dtc -@ -I dts -O dtb -b 0 -o "$2" "$out/dtb/tmp.dts"
	rm "$out/dtb/tmp.dts"
}
m=$dts/src/arm64/mediatek/mt7986a-bananapi-bpi-r3
dtc_one "$m.dts" "$out/dtb/mt7986a-bananapi-bpi-r3.dtb"
for medium in sd emmc; do
	dtc_one "$m-$medium.dtso" "$out/dtb/mt7986a-bananapi-bpi-r3-$medium.dtbo"
done

# kernel-info: KERNCONF, source commit, FreeBSD version (e.g. 16.0-CURRENT).
version=$(sed -n 's/^REVISION="\(.*\)"/\1/p' "$src/sys/conf/newvers.sh")-$(sed -n 's/^BRANCH="\(.*\)"/\1/p' "$src/sys/conf/newvers.sh")
echo "$kernconf $(git -C "$src" rev-parse --short=12 HEAD 2>/dev/null || echo unknown) $version" \
    > "$out/kernel-info"
ls -la "$out/kernel.txz" "$out/dtb"

#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Print the release notes (Markdown) for a set of release files.
#
#	release-notes.sh FILES_DIR BUILD_INFO_DIR SRC_REPO SRC_REF \
#	    BUILDER_REPO BUILDER_SHA
#
# BUILD_INFO_DIR holds kernel-info (KERNCONF, commit, version), snapshot
# and firmware-info, as written by kernel.sh, base.sh and firmware.sh.
# GitHub lists the files themselves, with their sizes, under the notes.
set -eu

files=$1
info=$2
src_repo=$3
src_ref=$4
repo=$5
sha=$6

read -r _kernconf commit version < "$info/kernel-info"
snapshot=$(cat "$info/snapshot")
snapshot=${snapshot#*-aarch64-}		# date-commit-number
. "$info/firmware-info"			# tfa, uboot
gh=https://github.com
# The file to start with, for the example command.
sd=$(cd "$files" && ls -- *-sd-*-nodebug.img.xz 2>/dev/null | head -1)
[ -n "$sd" ] || sd=freebsd-...-bpi-r3-sd-...-nodebug.img.xz

cat <<EOF
FreeBSD $version for the Banana Pi BPI-R3. [INSTALL.md]($gh/$repo/blob/main/INSTALL.md)
explains how to use these files, and the [status table]($gh/$repo#status)
shows what works.

- \`sd\`: SD card image. Start here.
- \`emmc-installer\`: SD card that installs FreeBSD on the eMMC.
- \`emmc\`: the eMMC image itself.
- \`bpi-r3-firmware\`: TF-A and U-Boot, with a README.

Each image comes as \`nodebug\` (\`GENERIC-NODEBUG\`) and \`debug\`
(\`GENERIC\`, with WITNESS and INVARIANTS).

\`\`\`
xz -dc $sd | sudo dd of=/dev/sdX bs=1M conv=fsync
\`\`\`

Set all four DIP switches on, boot, and log in as \`freebsd\`/\`freebsd\`.
To switch off, use \`shutdown -h now\` and unplug: \`shutdown -p\` resets
the board.

Built from [$src_repo]($gh/$src_repo) \`$src_ref\` at
[\`$commit\`]($gh/$src_repo/commit/$commit), snapshot \`$snapshot\`, TF-A
[\`$tfa\`]($gh/mtk-openwrt/arm-trusted-firmware/tree/$tfa) and U-Boot
$uboot with [these changes]($gh/$repo/tree/$sha/ci/u-boot) (its GPL
source).
EOF

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# configure.sh — configura Buildroot per egare, al posto di `make ftvogue_f1c200s_defconfig`.
#
#   external/board/egare/configure.sh        dalla radice del fork; poi `make`
#
# .config = ftvogue_f1c200s_defconfig (della base) + configs/egare.fragment, uniti con
# merge_config.sh di Buildroot, poi `make olddefconfig` attraverso il Makefile della base.
# Uno script qui e non un target nel Makefile: il Makefile è della base e sarebbe il primo
# punto di conflitto a ogni fusione da upstream.
set -eu

TOP=$(cd "$(dirname "$0")/../../.." && pwd)
O=${O:-$TOP/output}
EXT=$TOP/external

mkdir -p "$O"
cd "$TOP/buildroot"
CONFIG_=BR2_ ./support/kconfig/merge_config.sh -m -O "$O" \
	"$EXT/configs/ftvogue_f1c200s_defconfig" "$EXT/configs/egare.fragment"
cd "$TOP"
make O="$O" olddefconfig

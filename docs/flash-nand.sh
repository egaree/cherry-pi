#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# flash-nand.sh — scrive bootloader e rootfs nella SPI NAND via FEL.
#
#   ./docs/flash-nand.sh [output/images]
#
# La board deve essere in FEL e collegata via USB-C. Con la NAND vuota o
# senza un boot0 valido, e senza SD, la BROM ci va da sola. Con un
# bootloader valido in NAND: dal prompt di U-Boot `mtd erase boot`, poi
# reset. Layout e ragioni in docs/BOARD-FACTS.md.
#
# Ogni controllo avviene PRIMA dell'erase: se lo script si ferma, la flash
# e' intatta.
#
set -euo pipefail

IMAGES="${1:-output/images}"
UBOOT="$IMAGES/u-boot-sunxi-with-spl.bin"
ROOTFS="$IMAGES/rootfs.ubi"

NAND_SIZE=0x8000000     # 128 MiB, GD5F1GQ4xA
UBOOT_AT=0x40000        # splwrite: SPL nei blocchi 0-1, .bin lineare qui
UBI_AT=0x100000         # partizione MTD "ubi" (mtdparts 1M(boot),-(ubi))

die() { echo "flash-nand: $*" >&2; exit 1; }

command -v xfel >/dev/null 2>&1 || die "xfel non trovato nel PATH"
for f in "$UBOOT" "$ROOTFS"; do
	[ -f "$f" ] || die "manca $f (hai gia' lanciato 'make'?)"
done

size="$(stat -c %s "$UBOOT")"
[ $((UBOOT_AT + size)) -le $((UBI_AT)) ] \
	|| die "$UBOOT ($size B) sfora nella partizione UBI"
size="$(stat -c %s "$ROOTFS")"
[ "$size" -le $((NAND_SIZE - UBI_AT)) ] \
	|| die "$ROOTFS ($size B) non sta nella partizione UBI"

info="$(xfel spinand 2>&1)" || die "nessuna board in FEL: $info"
echo "$info"
case "$info" in
	*"with 134217728 bytes"*) ;;
	*) die "flash inattesa (attesa SPI NAND da 128 MiB): $info" ;;
esac

# xfel esce con 0 anche quando erase/write falliscono: stampa soltanto
# "Can't ...". Quindi si guarda l'output, non l'exit code. Il tee verso
# stderr mostra la barra di avanzamento mentre il comando gira: senza,
# la scrittura del rootfs (minuti) sembra un blocco.
x() {
	local out
	out="$(xfel "$@" 2>&1 | tee /dev/stderr)" || die "xfel $* fallito"
	case "$out" in
		*"Can't"*|*ERROR*) die "xfel $* fallito" ;;
	esac
	return 0
}

# Rilegge e confronta. xfel non salta i bad block: un blocco guasto nella
# zona scritta corrompe l'immagine senza errori, e solo la rilettura lo
# mostra.
verify() {
	local at="$1" file="$2" back
	back="$(mktemp)"
	x spinand read "$at" "$(stat -c %s "$file")" "$back"
	if ! cmp -s "$file" "$back"; then
		rm -f "$back"
		die "rilettura diversa da $file a $at: probabile bad block, vedi docs/BOARD-FACTS.md"
	fi
	rm -f "$back"
	echo "flash-nand: $file verificato a $at"
}

# Erase completo: UBI vuole che i PEB non coperti dall'immagine siano
# cancellati, altrimenti i residui del firmware di fabbrica fanno fallire
# l'attach.
x spinand erase 0 "$NAND_SIZE"
x spinand splwrite 1024 "$UBOOT_AT" "$UBOOT"
x spinand write "$UBI_AT" "$ROOTFS"

# splwrite scrive l'intero .bin lineare a UBOOT_AT: si rilegge da li'.
# L'SPL nei blocchi 0-1 e' in formato split e non si confronta byte a byte.
verify "$UBOOT_AT" "$UBOOT"
verify "$UBI_AT" "$ROOTFS"

echo
echo "flash-nand: fatto. Togli la SD, spegni e riaccendi la board."

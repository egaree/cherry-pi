#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# check-image.sh — verifica gli artefatti di una build, senza avere la board.
#
#   ./docs/check-image.sh [output/images]
#   make check
#
# Ognuno di questi controlli corrisponde a un errore realmente commesso
# durante il bring-up: header di boot assente, console su UART sbagliata,
# mappa DRAM da 32 MB, kernel compilato ARMv7, DTB della board sbagliata,
# bootcmd che punta a una SPI NOR inesistente. Vedi docs/BOARD-FACTS.md.
#
set -uo pipefail

IMAGES="${1:-output/images}"
BUILD="$(cd "$IMAGES/../build" 2>/dev/null && pwd)" || BUILD=""
HOSTBIN="$(cd "$IMAGES/../host/bin" 2>/dev/null && pwd)" || HOSTBIN=""

rc=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
fail() { printf '  \033[31mKO\033[0m    %s\n' "$*"; rc=1; }
skip() { printf '  \033[33m--\033[0m    %s\n' "$*"; }

echo
echo "check-image — $IMAGES"
echo

[ -d "$IMAGES" ] || { fail "directory non trovata: $IMAGES (hai gia' lanciato 'make'?)"; exit 1; }

# --- 1. header che cerca la BROM --------------------------------------------
# La BROM dell'F1C200s cerca "eGON.BT0" a offset 8 KiB + 4 byte (i primi 4
# sono l'istruzione di salto). Se manca, la board ignora la SD in silenzio.
if [ -f "$IMAGES/sdcard.img" ]; then
	magic="$(dd if="$IMAGES/sdcard.img" bs=1 skip=8196 count=8 2>/dev/null)"
	[ "$magic" = "eGON.BT0" ] \
		&& pass "eGON.BT0 a offset 8 KiB" \
		|| fail "a offset 8 KiB c'e' '$magic' invece di eGON.BT0"
else
	fail "sdcard.img assente"
fi

# --- 2. layout partizioni ----------------------------------------------------
if [ -f "$IMAGES/sdcard.img" ] && command -v /sbin/fdisk >/dev/null 2>&1; then
	parts="$(/sbin/fdisk -l "$IMAGES/sdcard.img" 2>/dev/null | grep -c '^.*img[12] ')"
	[ "$parts" = 2 ] \
		&& pass "2 partizioni nella tabella MBR" \
		|| fail "trovate $parts partizioni invece di 2"
	# la p1 non deve invadere lo spazio di SPL+U-Boot (8 KiB .. 2 MiB)
	start="$(/sbin/fdisk -l "$IMAGES/sdcard.img" 2>/dev/null | awk '/img1/{print $3}')"
	[ -n "$start" ] && [ "$start" -ge 4096 ] \
		&& pass "p1 parte a settore $start (>= 2 MiB, non calpesta U-Boot)" \
		|| fail "p1 parte a settore ${start:-?}: sovrascrive SPL/U-Boot"
else
	skip "fdisk non disponibile: layout partizioni non verificato"
fi

# --- 3. contenuto della FAT --------------------------------------------------
if [ -f "$IMAGES/boot.vfat" ] && [ -x "$HOSTBIN/mdir" ]; then
	listing="$(MTOOLS_SKIP_CHECK=1 "$HOSTBIN/mdir" -i "$IMAGES/boot.vfat" :: 2>/dev/null)"
	echo "$listing" | grep -qi zImage \
		&& pass "zImage presente nella FAT" || fail "zImage assente dalla FAT"
	echo "$listing" | grep -qi 'suniv-f1c200s-lctech-pi.dtb' \
		&& pass "DTB presente nella FAT" || fail "DTB assente dalla FAT"
else
	skip "mtools non disponibile: contenuto della FAT non verificato"
fi

# --- 4. configurazione U-Boot ------------------------------------------------
ucfg="$(ls -d "$BUILD"/uboot-*/.config 2>/dev/null | head -1)"
if [ -n "$ucfg" ] && [ -f "$ucfg" ]; then
	chk() { grep -q "^$1\$" "$ucfg" && pass "u-boot: $1" || fail "u-boot: atteso $1"; }
	chk 'CONFIG_CONS_INDEX=2'
	chk 'CONFIG_SUNXI_MINIMUM_DRAM_MB=64'
	chk 'CONFIG_DEFAULT_DEVICE_TREE="allwinner/suniv-f1c200s-lctech-pi"'
	chk 'CONFIG_SPL_SPI_SUNXI=y'
	chk 'CONFIG_SPL_SPI_SUNXI_NAND=y'
	chk 'CONFIG_SPL_SPI_SUNXI_NAND_ASSUMED_PAGESIZE=0x800'
	chk 'CONFIG_SYS_SPI_U_BOOT_OFFS=0x48000'
	chk 'CONFIG_MTD_SPI_NAND=y'
	chk 'CONFIG_CMD_UBI=y'
	chk 'CONFIG_CMD_UBIFS=y'
	chk 'CONFIG_ENV_IS_NOWHERE=y'
	# ENV_IS_IN_FAT e' il default di sunxi: un uboot.env sulla FAT (basta un
	# saveenv) sostituirebbe in silenzio il bootcmd compilato.
	chk '# CONFIG_ENV_IS_IN_FAT is not set'
	chk 'CONFIG_MTDPARTS_DEFAULT="mtdparts=spi0.0:1M(boot),-(ubi)"'
	grep -q '^CONFIG_BOOTCOMMAND=.*ubi part ubi' "$ucfg" \
		&& pass "u-boot: bootcmd ha il ramo NAND (ubi part ubi)" \
		|| fail "u-boot: il bootcmd non ha il ramo NAND"
	grep -q '^CONFIG_BOOTCOMMAND=.*load mmc 0:1' "$ucfg" \
		&& pass "u-boot: bootcmd carica da mmc 0:1" \
		|| fail "u-boot: il bootcmd non carica da mmc 0:1"
	grep -q '^CONFIG_BOOTCOMMAND=.*sf read' "$ucfg" \
		&& fail "u-boot: il bootcmd usa 'sf read' — la flash di questa board e' NAND, non NOR" \
		|| pass "u-boot: nessun 'sf read' nel bootcmd"
else
	skip "config di U-Boot non trovata: build fatta altrove?"
fi

# --- 5. configurazione kernel ------------------------------------------------
kcfg="$(ls -d "$BUILD"/linux-*/.config 2>/dev/null | head -1)"
if [ -n "$kcfg" ] && [ -f "$kcfg" ]; then
	chk() { grep -q "^$1\$" "$kcfg" && pass "kernel: $1" || fail "kernel: atteso $1"; }
	chk 'CONFIG_ARCH_MULTI_V5=y'
	chk 'CONFIG_MACH_SUNIV=y'
	chk 'CONFIG_CPU_ARM926T=y'
	chk 'CONFIG_MMC_SUNXI=y'
	chk 'CONFIG_EXT4_FS=y'
	chk 'CONFIG_SPI_SUN6I=y'
	chk 'CONFIG_MTD_SPI_NAND=y'
	chk 'CONFIG_MTD_CMDLINE_PARTS=y'
	chk 'CONFIG_MTD_UBI=y'
	chk 'CONFIG_UBIFS_FS=y'
	grep -q '^CONFIG_ARCH_MULTI_V7=y' "$kcfg" \
		&& fail "kernel: ARCH_MULTI_V7 attivo — il binario non gira su ARM926EJ-S" \
		|| pass "kernel: ARCH_MULTI_V7 disattivo"
else
	skip "config del kernel non trovata: build fatta altrove?"
fi

# --- 6. bootcmd realmente compilato nel binario ------------------------------
if [ -f "$IMAGES/u-boot.bin" ]; then
	# NB: 'grep -c' e non 'grep -q'. Con -q grep esce al primo match e manda
	# SIGPIPE a strings; sotto 'set -o pipefail' lo stato della pipeline
	# diventa 141 e il controllo fallisce anche quando la stringa c'e'.
	# E niente '^': in strings, bootcmd= e' attaccato alla stringa che lo
	# precede nel binario.
	n="$(strings "$IMAGES/u-boot.bin" | grep -c 'bootcmd=if test -e mmc 0:1 zImage')"
	[ "${n:-0}" -ge 1 ] \
		&& pass "bootcmd SD/NAND presente nell'ambiente compilato in u-boot.bin" \
		|| fail "bootcmd non trovato in u-boot.bin: il fragment non e' stato applicato"
else
	skip "u-boot.bin assente"
fi

# --- 7. il DTB e' quello della board -----------------------------------------
dtb="$IMAGES/suniv-f1c200s-lctech-pi.dtb"
if [ -f "$dtb" ] && [ -x "$HOSTBIN/dtc" ]; then
	model="$("$HOSTBIN/dtc" -I dtb -O dts "$dtb" 2>/dev/null | sed -n 's/.*model = "\(.*\)".*/\1/p' | head -1)"
	[ "$model" = "Lctech Pi F1C200s" ] \
		&& pass "DTB: model = \"$model\"" \
		|| fail "DTB: model = \"${model:-?}\" invece di \"Lctech Pi F1C200s\""
elif [ -f "$dtb" ]; then
	skip "dtc non disponibile: model del DTB non verificato"
else
	fail "DTB assente da $IMAGES"
fi

# --- 8. l'SPL contiene davvero il lettore SPI NAND ---------------------------
# Le patch stanno in external/.../patches/uboot/. Se un bump di U-Boot le
# rendesse inapplicabili la build fallirebbe; se invece venissero saltate
# (per esempio spostate in una sottodirectory di versione) l'SPL uscirebbe
# senza lettore NAND, e lo si scoprirebbe solo con la board muta.
smap="$(ls -d "$BUILD"/uboot-*/spl/u-boot-spl.map 2>/dev/null | head -1)"
if [ -n "$smap" ] && [ -f "$smap" ]; then
	n="$(grep -c 'spi_load_read_nand' "$smap")"
	[ "${n:-0}" -ge 1 ] \
		&& pass "SPL: lettore SPI NAND presente (spi_load_read_nand)" \
		|| fail "SPL: manca spi_load_read_nand — patch non applicate?"
else
	skip "map dell'SPL non trovata: build fatta altrove?"
fi

# --- 9. U-Boot sta nella zona boot della NAND --------------------------------
# flash-nand.sh scrive u-boot-sunxi-with-spl.bin lineare a 0x40000; la
# partizione UBI parte a 0x100000. Se U-Boot cresce oltre, il primo PEB di
# UBI viene sovrascritto e nessuno se ne accorge fino all'attach.
# L'SPL cerca u-boot.img a 0x48000, cioe' a +0x8000 nel file: se un bump
# sposta quell'offset, li' c'e' il vuoto.
ubin="$IMAGES/u-boot-sunxi-with-spl.bin"
if [ -f "$ubin" ]; then
	size="$(stat -c %s "$ubin")"
	[ $((0x40000 + size)) -le $((0x100000)) ] \
		&& pass "NAND: u-boot-sunxi-with-spl.bin ($size B) finisce prima di 0x100000" \
		|| fail "NAND: u-boot-sunxi-with-spl.bin ($size B) sfora in UBI"
	magic="$(od -An -tx1 -j $((0x8000)) -N4 "$ubin" | tr -d ' ')"
	[ "$magic" = 27051956 ] \
		&& pass "NAND: u-boot.img a +0x8000 nel file (flash 0x48000)" \
		|| fail "NAND: a +0x8000 c'e' '$magic' invece dell'header uImage"
else
	fail "u-boot-sunxi-with-spl.bin assente"
fi

# --- 10. rootfs.ubi ha la geometria della NAND -------------------------------
# GD5F1GQ4xA: pagina 2048, niente sub-page. Con -m 2048 -s 2048 l'header EC
# dice VID header a 2048 e dati a 4096. Una geometria sbagliata produce
# un'immagine che ubinize accetta e che il kernel rifiuta all'attach.
ubi="$IMAGES/rootfs.ubi"
if [ -f "$ubi" ]; then
	m="$(dd if="$ubi" bs=1 count=4 2>/dev/null)"
	[ "$m" = 'UBI#' ] && pass "rootfs.ubi: magic UBI#" || fail "rootfs.ubi: magic '$m'"
	offs="$(od -An -tx1 -j16 -N8 "$ubi" | tr -d ' \n')"
	[ "$offs" = 0000080000001000 ] \
		&& pass "rootfs.ubi: VID header a 2048, dati a 4096" \
		|| fail "rootfs.ubi: offset VID/dati = $offs (attesi 0x800 / 0x1000)"
	size="$(stat -c %s "$ubi")"
	[ "$size" -le $((0x8000000 - 0x100000)) ] \
		&& pass "rootfs.ubi ($size B) sta nella partizione ubi" \
		|| fail "rootfs.ubi ($size B) non sta nei 127 MiB della partizione ubi"
else
	fail "rootfs.ubi assente"
fi

# --- 11. kernel e DTB nel rootfs, dove li cerca il ramo NAND del bootcmd ----
tgt="$IMAGES/../target/boot"
for f in zImage suniv-f1c200s-lctech-pi.dtb; do
	[ -f "$tgt/$f" ] && pass "rootfs: /boot/$f" || fail "rootfs: manca /boot/$f"
done

echo
[ "$rc" = 0 ] && echo "  tutto a posto." || echo "  ci sono controlli falliti."
echo
exit $rc

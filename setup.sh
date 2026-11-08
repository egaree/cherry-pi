#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# setup.sh — prepara un clone pulito per la build.
#
# Fa due cose, entrambe idempotenti:
#   1. inizializza il submodule buildroot al tag LTS pinnato;
#   2. controlla che l'host abbia le dipendenze di build.
#
# Non c'e' nessun submodule vendor e nessun container: questa board e'
# interamente mainline, non servono blob ne' tool proprietari.
#
# Dopo:  make ftvogue_f1c200s_defconfig && make
#
set -euo pipefail

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
info() { printf '  \033[36m..\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mattenzione\033[0m %s\n' "$*" >&2; }
die()  { printf '  \033[31merrore\033[0m %s\n' "$*" >&2; exit 1; }

echo
echo "setup — f1c200s-framework (FTVOGUE F1C200S / Lctech Pi F1C200s)"
echo

# --- 1. submodule Buildroot --------------------------------------------------
cd "$TOPDIR"
if [ ! -f buildroot/Makefile ]; then
	info "inizializzo il submodule buildroot (puo' richiedere qualche minuto)"
	git submodule update --init --depth 1 buildroot
fi
BR_VER="$(sed -n 's/^export BR2_VERSION := //p' buildroot/Makefile | head -1)"
[ -n "$BR_VER" ] || die "buildroot/ non sembra un checkout valido"
ok "buildroot $BR_VER"

case "$BR_VER" in
	*.02|*.02.*) : ;;  # le LTS Buildroot sono le release YYYY.02.x
	*) warn "buildroot $BR_VER non e' una LTS (le LTS sono le YYYY.02.x)" ;;
esac

# --- 2. dipendenze host ------------------------------------------------------
# Senza container, la build gira direttamente qui: conviene scoprire subito
# cosa manca invece che dopo venti minuti di toolchain.
MISSING=0
need() {
	command -v "$1" >/dev/null 2>&1 || { warn "manca il comando '$1'${2:+  (pacchetto: $2)}"; MISSING=1; }
}

need gcc      build-essential
need g++      build-essential
need make     build-essential
need git      git
need bc       bc
need bison    bison
need flex     flex
need python3  python3
need rsync    rsync
need cpio     cpio
need unzip    unzip
need wget     wget
need file     file
need perl     perl
need patch    patch

# Header che i pacchetti host cercano e che non hanno un comando da testare.
#   openssl/ssl.h  -> kernel (CONFIG_MODULE_SIG / certs) e U-Boot
#   ncurses.h      -> menuconfig
#   swig           -> host-python-libfdt, richiesto da BR2_TARGET_UBOOT_NEEDS_PYLIBFDT
for probe in "openssl/ssl.h:libssl-dev" "ncurses.h:libncurses-dev"; do
	hdr="${probe%%:*}"; pkg="${probe##*:}"
	echo "#include <$hdr>" | gcc -fsyntax-only -x c - 2>/dev/null \
		|| { warn "manca l'header <$hdr>  (pacchetto: $pkg)"; MISSING=1; }
done
need swig swig

if [ "$MISSING" = 0 ]; then
	ok "dipendenze host presenti"
else
	echo
	warn "su Debian/Ubuntu:"
	warn "  sudo apt install build-essential git bc bison flex libssl-dev \\"
	warn "       libncurses-dev python3 rsync cpio unzip wget file swig"
	echo
	die "dipendenze host incomplete"
fi

cat <<EOF

Pronto. Prossimi passi:

    make ftvogue_f1c200s_defconfig
    make
    make check                     # verifica gli artefatti prodotti

Gli artefatti finiscono in output/images/, l'immagine da scrivere sulla SD
e' sdcard.img.

Console seriale: UART1 (pin PA2/PA3) -> ttyS0, 115200 8N1.

EOF

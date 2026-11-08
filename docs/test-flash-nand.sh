#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# test-flash-nand.sh — prova flash-nand.sh senza board, con un xfel finto.
#
#   ./docs/test-flash-nand.sh
#
# Il motivo: xfel esce con 0 anche quando erase/write falliscono (stampa solo
# "Can't ..."), e non salta i bad block. flash-nand.sh deve accorgersene da
# solo. Questi casi non si possono provare sulla board a comando.
#
# Il finto xfel simula la NAND con un file per indirizzo di scrittura.
# FAKE_FAIL=<comando> fa stampare "Can't ..." a quel comando;
# FAKE_CORRUPT=1 altera un byte in rilettura (bad block non saltato).
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/images" "$T/nand"
head -c 602048 /dev/urandom > "$T/images/u-boot-sunxi-with-spl.bin"
head -c 300000 /dev/urandom > "$T/images/rootfs.ubi"

cat > "$T/bin/xfel" <<'EOF'
#!/usr/bin/env bash
# xfel finto: stessi messaggi e stessi exit code del vero (main.c di xfel).
nand="$FAKE_NAND"
[ "$1" = spinand ] || exit 1
shift
case "${1:-}" in
	"")       echo "Found spi nand flash 'GD5F1GQ4xAYIG' with 134217728 bytes" ;;
	erase)    [ "${FAKE_FAIL:-}" = erase ] && { echo "Can't erase spi nand flash"; exit 0; }
	          rm -f "$nand"/* ;;
	write)    [ "${FAKE_FAIL:-}" = write ] && { echo "Can't write spi nand flash"; exit 0; }
	          cp "$3" "$nand/$(( $2 ))" ;;
	splwrite) [ "${FAKE_FAIL:-}" = splwrite ] && { echo "Can't write spi nand flash with split support"; exit 0; }
	          cp "$4" "$nand/$(( $3 ))" ;;
	read)     src="$nand/$(( $2 ))"
	          [ -f "$src" ] || { echo "Can't read spi nand flash"; exit 0; }
	          head -c "$(( $3 ))" "$src" > "$4"
	          if [ "${FAKE_CORRUPT:-}" = 1 ]; then
	          	printf '\xff' | dd of="$4" bs=1 seek=100 conv=notrunc 2>/dev/null
	          fi ;;
esac
exit 0
EOF
chmod +x "$T/bin/xfel"

rc=0
# caso <nome> <exit atteso> <testo atteso nell'output> [VAR=valore ...]
caso() {
	local name="$1" want_rc="$2" want_txt="$3"; shift 3
	rm -f "$T/nand"/*
	local out got
	out="$(env PATH="$T/bin:$PATH" FAKE_NAND="$T/nand" "$@" \
		"$HERE/flash-nand.sh" "$T/images" 2>&1)"
	got=$?
	if [ "$got" = "$want_rc" ] && [[ "$out" == *"$want_txt"* ]]; then
		printf '  ok    %s\n' "$name"
	else
		printf '  KO    %s (rc=%s, atteso %s; output:)\n%s\n' "$name" "$got" "$want_rc" "$out"
		rc=1
	fi
}

echo
echo "test-flash-nand"
echo
caso "tutto riesce"                    0 "flash-nand: fatto."
caso "erase fallisce"                  1 "Can't erase"                FAKE_FAIL=erase
caso "splwrite fallisce"               1 "Can't write"                FAKE_FAIL=splwrite
caso "write del rootfs fallisce"       1 "Can't write"                FAKE_FAIL=write
caso "rilettura diversa (bad block)"   1 "rilettura diversa"          FAKE_CORRUPT=1
echo
exit $rc

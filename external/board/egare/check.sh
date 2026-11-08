#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# check.sh — controlli della parte di egare, senza la scheda.
#
#   external/board/egare/check.sh config    output/.config dopo configure.sh
#   external/board/egare/check.sh target    output/target dopo make
#   external/board/egare/check.sh image     output/images/rootfs.ext4 dopo make
#
# Si lancia dalla radice del fork (o con O=<cartella di output>). Esce con 0 solo se tutti i
# controlli della sezione passano. Design: egare, docs/design/2026-11-08-f1c200s-scheda-di-prova.md.
#
set -uo pipefail

O="${O:-output}"
rc=0
pass() { printf '  ok        %s\n' "$*"; }
fail() { printf '  FALLITO:  %s\n' "$*"; rc=1; }

# ha <file> <riga>: la riga c'è, intera, nel file
ha() { grep -qxF -- "$2" "$1" 2>/dev/null; }
# vale <file> <regex estesa>: almeno una riga corrisponde
vale() { grep -qE -- "$2" "$1" 2>/dev/null; }

check_config() {
	local c="$O/.config"
	[ -f "$c" ] || { fail "$c non c'è: lanciare external/board/egare/configure.sh"; return; }

	# opzioni di egare
	local riga
	for riga in \
		'BR2_PACKAGE_DROPBEAR=y' \
		'# BR2_PACKAGE_DROPBEAR_CLIENT is not set' \
		'BR2_PACKAGE_DROPBEAR_DISABLE_REVERSEDNS=y' \
		'BR2_TARGET_GENERIC_HOSTNAME="egare-f1c200s"'; do
		ha "$c" "$riga" && pass "$riga" || fail "manca: $riga"
	done
	local opz
	for opz in BR2_ROOTFS_OVERLAY BR2_ROOTFS_POST_BUILD_SCRIPT BR2_ROOTFS_USERS_TABLES \
		BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES; do
		vale "$c" "^$opz=\".*board/egare/" && pass "$opz in board/egare/" \
			|| fail "$opz non punta in board/egare/"
	done
	vale "$c" '^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=".*ftvogue-f1c200s/linux\.fragment.*board/egare/linux\.fragment' \
		&& pass "fragment del kernel della base e di egare" \
		|| fail "BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES senza quello della base o board/egare/linux.fragment"
	vale "$c" '^BR2_ROOTFS_DEVICE_TABLE=".*system/device_table\.txt.*board/egare/permissions\.txt' \
		&& pass "BR2_ROOTFS_DEVICE_TABLE con quella della base e permissions.txt" \
		|| fail "BR2_ROOTFS_DEVICE_TABLE senza system/device_table.txt o permissions.txt"

	vale "$c" '^BR2_GLOBAL_PATCH_DIR=".*board/ftvogue-f1c200s/patches .*board/egare/patches"' \
		&& pass "BR2_GLOBAL_PATCH_DIR con le patch della base e di egare" \
		|| fail "BR2_GLOBAL_PATCH_DIR senza board/ftvogue-f1c200s/patches o board/egare/patches"

	# il defconfig della base c'è ancora
	for riga in \
		'BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="6.12.111"' \
		'BR2_PACKAGE_OPENSSL=y' \
		'BR2_PACKAGE_CA_CERTIFICATES=y' \
		'BR2_TARGET_GENERIC_GETTY_PORT="ttyS0"'; do
		ha "$c" "$riga" && pass "base: $riga" || fail "base, manca: $riga"
	done
}

check_target() {
	local t="$O/target"
	[ -d "$t/etc" ] || { fail "$t non c'è: lanciare make"; return; }

	local bb
	bb=$(ls -d "$O"/build/busybox-*/ 2>/dev/null | head -1)
	ha "${bb}.config" 'CONFIG_NTPD=y' && pass "BusyBox con ntpd" || fail "BusyBox senza CONFIG_NTPD=y"
	ls "$t"/lib/modules/*/kernel/drivers/usb/gadget/legacy/g_ether.ko >/dev/null 2>&1 \
		&& pass "modulo g_ether" || fail "manca g_ether.ko (CONFIG_USB_ETH=m)"
	[ -x "$t/usr/sbin/dropbear" ] && pass "dropbear" || fail "manca usr/sbin/dropbear"

	local it="$t/etc/inittab" r s k
	ha "$it" '::respawn:/usr/sbin/egare-agent-run' && pass "inittab: respawn di egare-agent-run" \
		|| fail "inittab senza ::respawn:/usr/sbin/egare-agent-run"
	s=$(grep -nxF '::shutdown:/usr/sbin/egare-agent-stop' "$it" | cut -d: -f1)
	k=$(grep -nxF '::shutdown:/etc/init.d/rcK' "$it" | cut -d: -f1)
	[ -n "$s" ] && [ -n "$k" ] && [ "$s" -lt "$k" ] && pass "inittab: egare-agent-stop prima di rcK" \
		|| fail "inittab: egare-agent-stop assente o dopo rcK"

	[ -s "$t/root/.ssh/authorized_keys" ] && pass "authorized_keys" || fail "root/.ssh/authorized_keys assente o vuoto"
	[ -f "$t/etc/resolv.conf" ] && [ ! -L "$t/etc/resolv.conf" ] && pass "resolv.conf è un file" \
		|| fail "etc/resolv.conf assente o ancora un link"

	for r in etc/modules-load.d/g_ether.conf etc/network/interfaces etc/default/syslogd \
		etc/default/dropbear etc/default/egare-agent; do
		[ -f "$t/$r" ] && pass "$r" || fail "manca $r"
	done
	for r in etc/init.d/S48ntpd etc/init.d/S12gpio usr/sbin/egare-agent-run usr/sbin/egare-agent-stop; do
		[ -x "$t/$r" ] && pass "$r eseguibile" || fail "$r assente o non eseguibile"
	done
	vale "$t/etc/network/interfaces" '^iface usb0 inet static' && pass "usb0 statica" || fail "interfaces senza usb0"
	[ "$(awk '{ print NF }' "$t/etc/egare-image" 2>/dev/null)" = 3 ] && pass "egare-image: $(cat "$t/etc/egare-image")" \
		|| fail "etc/egare-image assente o senza tre campi"
}

# modo_di <percorso>: "<modo ottale> <uid>:<gid>" del file in rootfs.ext4 (debugfs)
modo_di() {
	debugfs -R "stat $1" "$O/images/rootfs.ext4" 2>/dev/null | awk '
		/Mode:/ { for (i = 1; i <= NF; i++) if ($i == "Mode:") m = $(i + 1) }
		/User:/ { for (i = 1; i <= NF; i++) { if ($i == "User:") u = $(i + 1); if ($i == "Group:") g = $(i + 1) } }
		/Type:/ { for (i = 1; i <= NF; i++) if ($i == "Type:") t = $(i + 1) }
		END { if (m != "") printf "%s %s:%s %s\n", substr(m, length(m) - 3), u, g, t }'
}

check_image() {
	local img="$O/images/rootfs.ext4"
	[ -f "$img" ] || { fail "$img non c'è: lanciare make"; return; }
	command -v debugfs >/dev/null || { fail "manca debugfs (e2fsprogs)"; return; }
	local voce percorso atteso trovato
	for voce in \
		'/etc/egare|0700 0:0 directory' \
		'/var/lib/egare|0700 0:0 directory' \
		'/var/lib/flowrt|0750 1001:1001 directory' \
		'/root/.ssh|0700 0:0 directory' \
		'/root/.ssh/authorized_keys|0600 0:0 regular' \
		'/etc/resolv.conf|0644 0:0 regular' \
		'/usr/sbin/egare-agent-run|0755 0:0 regular'; do
		percorso=${voce%%|*}
		atteso=${voce#*|}
		trovato=$(modo_di "$percorso")
		[ "$trovato" = "$atteso" ] && pass "$percorso $atteso" || fail "$percorso: '$trovato' invece di '$atteso'"
	done
	# nomi delle linee GPIO nel DTB: 131 voci vuote (131 byte nulli) e poi PE3, PE4, PE5, quindi
	# PE0 e PE1 senza nome. Non si cerca "PE0\0" in tutto il DTB: compare anche in uart0-pe-pins.
	python3 -I -c '
import sys
d = open(sys.argv[1], "rb").read()
sys.exit(0 if b"\0" * 131 + b"PE3\0PE4\0PE5\0" in d else 1)' \
		"$O/images/suniv-f1c200s-lctech-pi.dtb" 2>/dev/null \
		&& pass "DTB con le linee PE3, PE4, PE5 per nome" || fail "DTB senza 131 voci vuote seguite da PE3, PE4, PE5"
	# la tabella degli utenti Buildroot la applica solo al filesystem, non a output/target
	debugfs -R "cat /etc/passwd" "$img" 2>/dev/null | grep -q '^flowrt:x:1001:1001:' \
		&& pass "utente flowrt 1001" || fail "manca flowrt:x:1001:1001 in /etc/passwd"
	debugfs -R "cat /etc/group" "$img" 2>/dev/null | grep -q '^flowrt:x:1001:' \
		&& pass "gruppo flowrt 1001" || fail "manca flowrt:x:1001 in /etc/group"
}

case "${1:-}" in
config) check_config ;;
target) check_target ;;
image) check_image ;;
*) echo "uso: $0 config|target|image" >&2; exit 2 ;;
esac
exit $rc

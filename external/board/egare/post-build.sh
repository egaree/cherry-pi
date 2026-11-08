#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# post-build.sh — ritocchi di egare al rootfs (BR2_ROOTFS_POST_BUILD_SCRIPT).
#
#   post-build.sh <TARGET_DIR> [argomenti di BR2_ROOTFS_POST_SCRIPT_ARGS, ignorati]
#
# - /root/.ssh/authorized_keys dal file in EGARE_AUTHORIZED_KEYS (fuori dal repo);
# - righe dell'inittab per egare-agent-run (respawn) ed egare-agent-stop (shutdown, prima di rcK);
# - /etc/egare-image: "cherry-pi <git describe> <data della build>";
# - /etc/fstab: debugfs su /sys/kernel/debug, per leggere lo stato delle linee GPIO
#   (/sys/kernel/debug/gpio: nome, chi le usa, direzione, livello).
# Si può lanciare più volte sullo stesso TARGET_DIR. Design: egare,
# docs/design/2026-11-08-f1c200s-scheda-di-prova.md §5.3–5.5.
set -eu

TARGET=${1:?uso: $0 <TARGET_DIR>}
HERE=$(cd "$(dirname "$0")" && pwd)

# chiave ssh: senza, dropbear sulla scheda sarebbe inutilizzabile e lo si scoprirebbe tardi
KEYS=${EGARE_AUTHORIZED_KEYS:-}
if [ -z "$KEYS" ] || [ ! -s "$KEYS" ]; then
	cat >&2 <<-MSG
	post-build.sh: EGARE_AUTHORIZED_KEYS non indica un file di chiavi pubbliche non vuoto
	(valore: '${KEYS}'). Impostarla in local.mk, con export:
	    export EGARE_AUTHORIZED_KEYS = \$(HOME)/.ssh/id_ed25519.pub
	oppure sulla riga di comando: make EGARE_AUTHORIZED_KEYS=<file>
	MSG
	exit 1
fi
# solo chiavi pubbliche: una chiave privata (EGARE_AUTHORIZED_KEYS senza .pub) finirebbe sulla SD
if grep -q 'PRIVATE KEY' "$KEYS" || grep -v -E '^[[:space:]]*(#|$)' "$KEYS" | grep -q -v -E '^(ssh-|ecdsa-|sk-)'; then
	echo "post-build.sh: $KEYS non è un file di chiavi pubbliche (righe ssh-…, ecdsa-…, sk-…)" >&2
	exit 1
fi
install -d -m 0700 "$TARGET/root/.ssh"
install -m 0600 "$KEYS" "$TARGET/root/.ssh/authorized_keys"

# inittab: lo scrive Buildroot (con la getty del defconfig), qui si aggiungono solo le righe
INITTAB=$TARGET/etc/inittab
RESPAWN='::respawn:/usr/sbin/egare-agent-run'
STOP='::shutdown:/usr/sbin/egare-agent-stop'
grep -qxF "$RESPAWN" "$INITTAB" || printf '\n# egare: agent sotto init (egare-agent-run)\n%s\n' "$RESPAWN" >> "$INITTAB"
if ! grep -qxF "$STOP" "$INITTAB"; then
	grep -qxF '::shutdown:/etc/init.d/rcK' "$INITTAB" || {
		echo "post-build.sh: nell'inittab manca ::shutdown:/etc/init.d/rcK" >&2
		exit 1
	}
	# prima di rcK: rcK toglie la rete, e init manda SIGTERM a tutti solo dopo le righe di shutdown
	sed -i "s|^::shutdown:/etc/init.d/rcK\$|$STOP\n::shutdown:/etc/init.d/rcK|" "$INITTAB"
fi

# fstab: lo scrive Buildroot; mount -a dell'avvio monta debugfs dopo /sys (riga in fondo)
FSTAB=$TARGET/etc/fstab
grep -qE '^debugfs[[:space:]]' "$FSTAB" || printf 'debugfs\t\t/sys/kernel/debug\tdebugfs\tdefaults\t0\t0\n' >> "$FSTAB"

versione=$(git -C "$HERE" describe --always --dirty 2>/dev/null || echo sconosciuta)
echo "cherry-pi $versione $(date -u +%Y-%m-%d)" > "$TARGET/etc/egare-image"

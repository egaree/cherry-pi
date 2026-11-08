#!/bin/sh
# SC2016: script finti scritti con printf; SC2329: funzioni usate da "controlla"
# shellcheck disable=SC2016,SC2329
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# test-agent.sh — prove sull'host di egare-agent-run ed egare-agent-stop (rootfs-overlay/usr/sbin),
# con un agent finto e un sleep che registra le attese invece di dormire.
#
#   external/board/egare/test-agent.sh
#
# Esce con 0 se tutti i casi passano.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
RUN_SCRIPT=$HERE/rootfs-overlay/usr/sbin/egare-agent-run
STOP_SCRIPT=$HERE/rootfs-overlay/usr/sbin/egare-agent-stop
rc=0
T=

ok() { printf '  ok        %s\n' "$1"; }
ko() { printf '  FALLITO:  %s\n' "$1"; rc=1; }
# controlla <nome> <comando…>: ok se il comando riesce
controlla() { _n=$1; shift; if "$@"; then ok "$_n"; else ko "$_n"; fi; }

# prepara: cartella nuova con etc, run, immagine, agent finto, sleep e logger finti
prepara() {
	[ -n "$T" ] && rm -rf "$T"
	T=$(mktemp -d)
	mkdir -p "$T/etc" "$T/run"
	echo '{}' > "$T/etc/bootstrap.json"
	echo 'cherry-pi v0-test 2026-11-08' > "$T/egare-image"
	cat > "$T/agent" <<-'EOF'
	#!/bin/sh
	# agent finto: registra argomenti, ambiente e pid, poi esce con FAKE_EXIT
	echo "$*" > "$FAKE_DIR/agent.args"
	env > "$FAKE_DIR/agent.env"
	if [ "$(cat "$EGARE_RUN_TEST/egare-agent.pid" 2>/dev/null)" = "$$" ]; then
		echo uguale > "$FAKE_DIR/agent.pid"
	else
		echo diverso > "$FAKE_DIR/agent.pid"
	fi
	echo "riga dell'agent"
	exit "${FAKE_EXIT:-0}"
	EOF
	printf '#!/bin/sh\necho "$1" >> "%s/sleeps"\n' "$T" > "$T/sleep"
	printf '#!/bin/sh\ncat >> "%s/log"\n' "$T" > "$T/logger"
	# pidof finto: nessun flowrt, salvo FAKE_FLOWRT=1; killall finto: registra gli argomenti
	printf '#!/bin/sh\n[ "${FAKE_FLOWRT:-}" = 1 ] && echo 456\n' > "$T/pidof"
	printf '#!/bin/sh\necho "$*" >> "%s/killall.log"\n' "$T" > "$T/killall"
	chmod +x "$T/agent" "$T/sleep" "$T/logger" "$T/pidof" "$T/killall"
	: > "$T/sleeps"
	export FAKE_DIR="$T" EGARE_RUN_TEST="$T/run"
	export EGARE_AGENT_BIN="$T/agent" EGARE_ETC="$T/etc" EGARE_RUN="$T/run" \
		EGARE_DEFAULTS="$T/defaults" EGARE_IMAGE="$T/egare-image" \
		EGARE_LOGGER="$T/logger" EGARE_SLEEP="$T/sleep" EGARE_PIDOF="$T/pidof" EGARE_KILLALL="$T/killall" \
		EGARE_HOLD_WAIT=30 EGARE_TIME_WAIT=60 EGARE_FAIL_WAIT=10 EGARE_STOP_WAIT=15
	unset FAKE_EXIT FAKE_FLOWRT
}

esegui() { sh "$RUN_SCRIPT" >/dev/null 2>&1; }
dorme() { [ "$(cat "$T/sleeps")" = "$1" ]; }
partito() { [ -f "$T/agent.args" ]; }

echo "test-agent: egare-agent-run"

prepara
touch "$T/run/egare-agent.hold"
esegui; e=$?
controlla "fermo: l'agent non parte" sh -c "! test -f '$T/agent.args'"
controlla "fermo: attesa 30" dorme 30
controlla "fermo: uscita 0" test "$e" -eq 0

prepara
rm "$T/etc/bootstrap.json"
esegui; esegui
controlla "manca-bootstrap: l'agent non parte" sh -c "! test -f '$T/agent.args'"
controlla "manca-bootstrap: attese 30 e 30" dorme "$(printf '30\n30')"
controlla "manca-bootstrap: messaggio una volta sola" test "$(grep -c . "$T/log")" -eq 1

prepara
rm "$T/agent"
esegui
controlla "manca-agent: attesa 30, nessun avvio" dorme 30

prepara
printf 'EGARE_AGENT_ARGS="--hold-trial"\nGOMEMLIMIT=20MiB\n' > "$T/defaults"
esegui
controlla "opzioni-e-ambiente: --hold-trial come argomento" test "$(cat "$T/agent.args")" = "--hold-trial"
controlla "opzioni-e-ambiente: GOMEMLIMIT nell'ambiente" grep -qx 'GOMEMLIMIT=20MiB' "$T/agent.env"
controlla "opzioni-e-ambiente: EGARE_AGENT_ARGS non passa" sh -c "! grep -q '^EGARE_AGENT_ARGS=' '$T/agent.env'"
controlla "opzioni-e-ambiente: output dell'agent nel logger" grep -qx "riga dell'agent" "$T/log"

prepara
esegui
controlla "run-egare: cartella creata" test -d "$T/run/egare"
controlla "run-egare: permessi 755" test "$(stat -c %a "$T/run/egare")" = 755

prepara
FAKE_EXIT=1 esegui; e=$?
controlla "uscita-con-errore: l'agent è partito" partito
controlla "uscita-con-errore: attesa 10" dorme 10
controlla "uscita-con-errore: uscita diversa da 0" test "$e" -ne 0

prepara
esegui; e=$?
controlla "uscita-pulita: nessuna attesa" dorme ""
controlla "uscita-pulita: uscita 0" test "$e" -eq 0

prepara
echo 'cherry-pi v0-test 2999-01-01' > "$T/egare-image"
EGARE_TIME_WAIT=2 esegui
controlla "ora-scaduta: due attese da 1 s" dorme "$(printf '1\n1')"
controlla "ora-scaduta: l'agent parte lo stesso" partito

prepara
esegui
controlla "pid: il file contiene il pid dell'agent" test "$(cat "$T/agent.pid")" = uguale
controlla "pid: tolto all'uscita" sh -c "! test -f '$T/run/egare-agent.pid'"

prepara
rm "$T/etc/bootstrap.json"
esegui
echo '{}' > "$T/etc/bootstrap.json"
esegui
controlla "attesa finita: segnaposto tolto quando l'agent parte" sh -c "! test -f '$T/run/egare-agent.waiting'"

prepara
FAKE_EXIT=137 FAKE_FLOWRT=1 esegui
controlla "flowrt-orfano: SIGTERM ai flowrt rimasti" grep -qx -- '-q -TERM flowrt' "$T/killall.log"
controlla "flowrt-orfano: poi SIGKILL" grep -qx -- '-q -KILL flowrt' "$T/killall.log"
orfano_log() { grep -q 'flowrt rimasto' "$T/log"; }
controlla "flowrt-orfano: lo scrive nel syslog" orfano_log

prepara
esegui
nessun_killall() { [ ! -f "$T/killall.log" ]; }
controlla "nessun-orfano: nessun killall" nessun_killall

prepara
echo 'cherry-pi v0-test 2999-01-01' > "$T/egare-image"
# un sleep che, alla prima attesa dell'ora, crea il file di fermo (egare-agent-stop allo spegnimento)
printf '#!/bin/sh\necho "$1" >> "%s/sleeps"\n: > "%s/run/egare-agent.hold"\n' "$T" "$T" > "$T/sleep"
EGARE_TIME_WAIT=2 esegui; e=$?
controlla "fermo-durante-attesa-ora: l'agent non parte" sh -c "! test -f '$T/agent.args'"
controlla "fermo-durante-attesa-ora: uscita 0" test "$e" -eq 0

echo "test-agent: egare-agent-stop"

# agent finto che dorme: con "termina" scrive term ed esce a SIGTERM, con "ignora" lo ignora
lungo() {
	cat > "$T/lungo" <<-EOF
	#!/bin/sh
	if [ "\$1" = ignora ]; then trap '' TERM; else trap 'echo term > "$T/term"; exit 0' TERM; fi
	while :; do sleep 0.1; done
	EOF
	chmod +x "$T/lungo"
	"$T/lungo" "$1" </dev/null >/dev/null 2>&1 &
	echo $! > "$T/run/egare-agent.pid"
	sleep 0.3
}

prepara
lungo termina
p=$(cat "$T/run/egare-agent.pid")
EGARE_SLEEP="sleep" EGARE_STOP_WAIT=5 sh "$STOP_SCRIPT" >/dev/null 2>&1; e=$?
controlla "stop: file di fermo creato" test -f "$T/run/egare-agent.hold"
controlla "stop: l'agent ha ricevuto SIGTERM" test -f "$T/term"
controlla "stop: uscita 0" test "$e" -eq 0
controlla "stop: processo finito" sh -c "! kill -0 $p 2>/dev/null"
kill -9 "$p" 2>/dev/null

prepara
lungo ignora
p=$(cat "$T/run/egare-agent.pid")
inizio=$(date +%s)
out=$(EGARE_SLEEP="sleep" EGARE_STOP_WAIT=1 sh "$STOP_SCRIPT" 2>&1); e=$?
durata=$(( $(date +%s) - inizio ))
kill -9 "$p" 2>/dev/null
controlla "stop-ignorato: esce entro 3 s" test "$durata" -le 3
controlla "stop-ignorato: uscita diversa da 0" test "$e" -ne 0
controlla "stop-ignorato: file di fermo creato" test -f "$T/run/egare-agent.hold"
nomina() { printf '%s\n' "$out" | grep -q 'non è uscito'; }
controlla "stop-ignorato: messaggio \"non è uscito\"" nomina

prepara
EGARE_SLEEP="sleep" sh "$STOP_SCRIPT" >/dev/null 2>&1; e=$?
controlla "stop-senza-agent: uscita 0" test "$e" -eq 0
controlla "stop-senza-agent: file di fermo creato" test -f "$T/run/egare-agent.hold"

echo "test-agent: post-build.sh"

POST_BUILD=$HERE/post-build.sh
# prepara_target: un TARGET_DIR finto con l'inittab di Buildroot (righe che contano)
prepara_target() {
	[ -n "$T" ] && rm -rf "$T"
	T=$(mktemp -d)
	mkdir -p "$T/target/etc" "$T/target/root"
	cat > "$T/target/etc/inittab" <<-'EOF2'
	::sysinit:/etc/init.d/rcS
	ttyS0::respawn:/sbin/getty -L  ttyS0 115200 vt100 # GENERIC_SERIAL
	::shutdown:/etc/init.d/rcK
	::shutdown:/sbin/swapoff -a
	::shutdown:/bin/umount -a -r
	EOF2
	printf 'proc\t\t/proc\t\tproc\tdefaults\t0\t0\nsysfs\t\t/sys\t\tsysfs\tdefaults\t0\t0\n' > "$T/target/etc/fstab"
	echo 'ssh-ed25519 AAAAtest prova@pc' > "$T/key.pub"
}
riga_n() { grep -nxF "$1" "$T/target/etc/inittab" | cut -d: -f1; }
conta() { grep -cxF "$1" "$T/target/etc/inittab"; }

prepara_target
out=$(env -u EGARE_AUTHORIZED_KEYS sh "$POST_BUILD" "$T/target" -c genimage.cfg 2>&1); e=$?
controlla "senza-chiave: uscita diversa da 0" test "$e" -ne 0
spiega() { printf '%s\n' "$out" | grep -q EGARE_AUTHORIZED_KEYS; }
controlla "senza-chiave: il messaggio nomina EGARE_AUTHORIZED_KEYS" spiega

prepara_target
: > "$T/vuota.pub"
EGARE_AUTHORIZED_KEYS="$T/vuota.pub" sh "$POST_BUILD" "$T/target" >/dev/null 2>&1; e=$?
controlla "chiave-vuota: uscita diversa da 0" test "$e" -ne 0

prepara_target
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n-----END OPENSSH PRIVATE KEY-----\n' > "$T/privata"
EGARE_AUTHORIZED_KEYS="$T/privata" sh "$POST_BUILD" "$T/target" >/dev/null 2>&1; e=$?
controlla "chiave-privata: uscita diversa da 0" test "$e" -ne 0
privata_assente() { [ ! -e "$T/target/root/.ssh/authorized_keys" ]; }
controlla "chiave-privata: niente authorized_keys" privata_assente

prepara_target
EGARE_AUTHORIZED_KEYS="$T/key.pub" sh "$POST_BUILD" "$T/target" -c genimage.cfg >/dev/null 2>&1; e=$?
EGARE_AUTHORIZED_KEYS="$T/key.pub" sh "$POST_BUILD" "$T/target" -c genimage.cfg >/dev/null 2>&1
controlla "chiave: uscita 0" test "$e" -eq 0
controlla "chiave: authorized_keys uguale alla chiave" cmp -s "$T/key.pub" "$T/target/root/.ssh/authorized_keys"
controlla "chiave: authorized_keys 600" test "$(stat -c %a "$T/target/root/.ssh/authorized_keys")" = 600
controlla "chiave: .ssh 700" test "$(stat -c %a "$T/target/root/.ssh")" = 700
controlla "inittab: respawn una volta sola" test "$(conta '::respawn:/usr/sbin/egare-agent-run')" -eq 1
controlla "inittab: shutdown dell'agent una volta sola" test "$(conta '::shutdown:/usr/sbin/egare-agent-stop')" -eq 1
prima() { [ "$(riga_n '::shutdown:/usr/sbin/egare-agent-stop')" -lt "$(riga_n '::shutdown:/etc/init.d/rcK')" ]; }
controlla "inittab: shutdown dell'agent prima di rcK" prima
controlla "inittab: la getty resta" test "$(grep -c GENERIC_SERIAL "$T/target/etc/inittab")" -eq 1
campi() { [ "$(awk '{ print NF }' "$T/target/etc/egare-image")" -eq 3 ] && grep -qE '^cherry-pi [^ ]+ [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$T/target/etc/egare-image"; }
controlla "egare-image: cherry-pi <versione> <data>" campi
debugfs_righe() { grep -cE '^debugfs[[:space:]]+/sys/kernel/debug[[:space:]]+debugfs[[:space:]]' "$T/target/etc/fstab"; }
controlla "fstab: debugfs una volta sola" test "$(debugfs_righe)" -eq 1
dopo_sys() { [ "$(grep -n '^debugfs' "$T/target/etc/fstab" | cut -d: -f1)" -gt "$(grep -n '^sysfs' "$T/target/etc/fstab" | cut -d: -f1)" ]; }
controlla "fstab: debugfs dopo sysfs" dopo_sys

rm -rf "$T"
exit $rc

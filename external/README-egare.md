# cherry-pi: l'immagine della F1C200S per egare

Questo repo è generato da [`f1c200s-framework`](https://github.com/wdalmut/f1c200s-framework), la
base generica della board, e aggiunge il sistema per usare la scheda come **banco di prova di
egare**. All'avvio, senza toccare la seriale, la scheda:
- va in rete via USB;
- prende l'ora;
- accetta ssh;
- avvia `egare-agent` se è installato.

Agent e flowrt non sono nell'immagine: li consegna `devices/f1c200s/` di egare via ssh, quindi la
SD si riscrive solo quando cambia il sistema base.

Il perché delle scelte è nel design di egare `docs/design/2026-11-08-f1c200s-scheda-di-prova.md`.
La parte PC della rete USB (profilo NetworkManager `cherrypi`) è in
`docs/runbooks/f1c200s-rete-usb.md` di egare.

## Cosa aggiunge alla base

Solo file nuovi sotto `external/`. Il `Makefile`, il defconfig della base e `buildroot/` non
cambiano, così la fusione da `upstream` resta semplice.

| file | |
| --- | --- |
| `configs/egare.fragment` | opzioni sopra `ftvogue_f1c200s_defconfig`: dropbear, overlay, utenti, permessi, fragment del kernel, hostname `egare-f1c200s` |
| `board/egare/configure.sh` | `.config` = defconfig della base + fragment (al posto di `make ftvogue_f1c200s_defconfig`) |
| `board/egare/linux.fragment` | gadget Ethernet `g_ether` come modulo (RNDIS ed ECM): il fragment della base non lo abilita |
| `board/egare/busybox.fragment` | `ntpd` in BusyBox |
| `board/egare/users.txt` | utente `flowrt` uid e gid 1001, senza shell |
| `board/egare/permissions.txt` | `/etc/egare` e `/var/lib/egare` 0700 root, `/var/lib/flowrt` 0750 `flowrt` |
| `board/egare/post-build.sh` | `authorized_keys`, righe dell'`inittab`, `/etc/egare-image` |
| `board/egare/rootfs-overlay/` | gadget USB, `usb0`, DNS, syslog, `ntpd`, dropbear, `egare-agent-run`/`-stop` |
| `board/egare/check.sh` | controlli senza scheda: `config`, `target`, `image` |
| `board/egare/test-agent.sh` | prove sull'host di `egare-agent-run`, `egare-agent-stop` e `post-build.sh` |

## Build

Una volta: la chiave pubblica che entra in `/root/.ssh/authorized_keys`. Va in `local.mk` (già in
`.gitignore`) **con `export`**, perché il Makefile della base passa a Buildroot solo `MIRROR` e
`DL_DIR`. Senza la chiave la build si ferma.

```make
# local.mk
export EGARE_AUTHORIZED_KEYS = $(HOME)/.ssh/id_ed25519.pub
DL_DIR = $(HOME)/.cache/buildroot-dl        # facoltativo: sorgenti condivisi
```

```bash
git submodule update --init
external/board/egare/configure.sh     # invece di make ftvogue_f1c200s_defconfig
make
make check                            # controlli della base
external/board/egare/check.sh config && external/board/egare/check.sh target && external/board/egare/check.sh image
external/board/egare/test-agent.sh    # prove degli script, anche senza build
```

L'immagine è `output/images/sdcard.img`; si scrive sulla SD come nella base. La toolchain in
`output/host/` serve anche a egare per compilare flowrt armv5 (`devices/f1c200s/build.sh`).

## La scheda

| | |
| --- | --- |
| rete | `g_ether` con MAC fissi, `usb0` = `192.168.7.2/24`, gateway e DNS `192.168.7.1` (il PC) |
| ora | `ntpd` verso `pool.ntp.org` attraverso il NAT del PC (`S48ntpd`) |
| ssh | `ssh root@192.168.7.2`, solo chiave. Le chiavi host le crea dropbear alla prima connessione e restano sulla SD |
| log | `syslogd` in RAM, `/var/log/messages`, 3 × 256 KB |
| agent | `::respawn:/usr/sbin/egare-agent-run` nell'`inittab`; aspetta finché mancano `/usr/bin/egare-agent` o `/etc/egare/bootstrap.json` |
| versione | `/etc/egare-image`: `cherry-pi <git describe> <data della build>` |

Root non ha password, come nella base: è un banco di prova (design di egare, §3).

### Agent

```sh
killall egare-agent                                # riavvio: init rilancia egare-agent-run
/usr/sbin/egare-agent-stop                         # fermo: file di fermo, SIGTERM, attesa fino a 15 s
rm /run/egare-agent.hold                           # ripresa (o un riavvio)
vi /etc/default/egare-agent                        # EGARE_AGENT_ARGS (per esempio --hold-trial), GOMEMLIMIT
grep egare-agent /var/log/messages
```

Allo spegnimento `egare-agent-stop` ferma l'agent **prima** di `rcK`, finché c'è ancora la rete.

### Dopo una nuova SD

Le chiavi host cambiano: sul PC `ssh-keygen -R 192.168.7.2`.

## Fusione dalla base

```bash
git remote add upstream git@github.com:wdalmut/f1c200s-framework.git   # una volta
git fetch upstream
git merge upstream/master                  # la prima volta: --allow-unrelated-histories
```

Il repo è nato da un template con un solo commit, senza storia in comune con la base: la prima
fusione si risolve a mano, le successive sono normali.

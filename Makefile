# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
# Wrapper attorno a Buildroot upstream.
#
# Non contiene logica di build: serve solo a non far ripetere ogni volta
# `-C buildroot O=... BR2_EXTERNAL=...`.
#
#   make ftvogue_f1c200s_defconfig    configura per la board (boot da SD)
#   make                              costruisce
#   make savedefconfig                riscrive il defconfig dal .config
#   make check                        verifica gli artefatti prodotti
#   make defconfigs                   elenca i defconfig disponibili
#
#   make MIRROR=<url> ...             prende i tarball da <url> prima che dai
#                                     siti upstream (BR2_PRIMARY_SITE)
#   make DL_DIR=<path> ...            cache dei sorgenti condivisa (BR2_DL_DIR)
#
# Qualunque altro target viene inoltrato a Buildroot cosi' com'e':
# `make menuconfig`, `make linux-menuconfig`, `make linux-diff-config`,
# `make uboot-reconfigure`, `make printvars VARS=...`.
#
# A differenza di rk3506-framework qui NON c'e' un container di build: quello
# serve quando il BSP vendor pinna le dipendenze host (gcc < 14, python2).
# Questa board e' interamente mainline e compila su qualunque distro recente.

TOPDIR       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
O            ?= $(TOPDIR)/output
BR2_EXTERNAL := $(TOPDIR)/external
BUILDROOT    := $(TOPDIR)/buildroot

# Mirror opzionale dei tarball (BR2_PRIMARY_SITE): provato PRIMA del sito
# upstream di ogni package, con fallback su quest'ultimo. Vuoto per default,
# nessun URL e' cablato in questo albero.
MIRROR       ?=

# Cache dei sorgenti. Se vuota Buildroot usa buildroot/dl (dentro il
# submodule, gia' ignorato dal suo .gitignore). Impostarla conviene quando
# si hanno piu' alberi sulla stessa macchina: si scarica una volta sola.
DL_DIR       ?=

# MIRROR e DL_DIR possono stare in un file locale invece che sulla riga di
# comando. local.mk e' in .gitignore: e' il posto giusto per la
# configurazione della singola macchina, che non deve entrare nell'albero.
#
#     echo 'DL_DIR = $(HOME)/.cache/buildroot-dl' > local.mk
#
# Il `-` davanti a include fa si' che l'assenza del file non sia un errore.
LOCAL_MK     := $(TOPDIR)/local.mk
-include $(LOCAL_MK)

# MIRROR e DL_DIR vanno passati sulla RIGA DI COMANDO di make, non
# nell'ambiente: il .config di Buildroot li assegna come variabili del
# makefile, e l'ambiente non sovrascrive un'assegnazione del makefile.
BRMAKE = $(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(BR2_EXTERNAL) \
	$(if $(MIRROR),BR2_PRIMARY_SITE=$(MIRROR),) \
	$(if $(DL_DIR),BR2_DL_DIR=$(DL_DIR),)

.PHONY: all check defconfigs help

all:
	@$(BRMAKE)

%:
	@$(BRMAKE) $@

# Evita che la regola catch-all provi a "ricostruire" i file che questo
# Makefile include. Senza queste due righe `%:` intercetta il nome del file
# mancante e lo inoltra a Buildroot, che risponde "No rule to make target".
# Vale per il Makefile stesso e per local.mk, che di norma NON esiste.
Makefile: ;
$(LOCAL_MK): ;

# ------------------------------------------------------ non passano da Buildroot
check:
	@$(TOPDIR)/docs/check-image.sh $(O)/images

defconfigs:
	@echo "defconfig disponibili:"
	@ls -1 $(BR2_EXTERNAL)/configs | sed 's/^/  /'

help:
	@awk '/SPDX-License-Identifier|^# Copyright/{next} /^#$$/{next} \
	      /^#/{sub(/^# ?/,""); print; next} {exit}' $(firstword $(MAKEFILE_LIST))

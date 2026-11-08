# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
################################################################################
#
# FTVOGUE F1C200S (Allwinner F1C200s, suniv) — external tree
#
# Questo albero non ha (ancora) package propri. Il wildcard sotto li raccoglie
# automaticamente appena ne compare uno in package/<nome>/<nome>.mk, senza
# dover toccare questo file.
#
# Non c'e' nemmeno un post-image.sh: l'immagine SD la produce genimage con
# board/ftvogue-f1c200s/genimage.cfg, perche' questa board non ha nessuna
# catena di packaging vendor. E' tutto mainline: SPL+U-Boot a 8 KiB, una FAT
# e una ext4. Vedi docs/BOARD-FACTS.md.
#
################################################################################

include $(sort $(wildcard $(BR2_EXTERNAL_F1C200S_PATH)/package/*/*.mk))

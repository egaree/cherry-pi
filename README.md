# f1c200s-framework — FTVOGUE F1C200S su Buildroot upstream

Immagine SD bootabile per la dev board **FTVOGUE F1C200S**, costruita con
Buildroot upstream tenuto come submodule e un *external tree* che contiene solo
i file di questa board.

L'hardware è la **Lctech Pi F1C200s** (Allwinner F1C200s, famiglia `suniv`),
supportata interamente in mainline: niente blob, niente SDK vendor, niente
container di build.

* SoC Allwinner F1C200s, ARM926EJ-S (**ARMv5TE**)
* 64 MB DDR1 co-packaged
* 1 Gbit SPI NAND (**non usata**: si boota da SD, vedi [Limiti noti](#limiti-noti))
* Console su **UART1**, pin **PA2 / PA3**, 115200 8N1
* Linux 6.12 LTS + U-Boot 2026.07, entrambi mainline

## Documentazione

* [docs/BOARD-FACTS.md](docs/BOARD-FACTS.md) — fatti verificati sull'hardware e
  sui sorgenti, con la fonte di ciascuno. **Leggilo prima di seguire qualunque
  guida trovata in rete**: quasi tutte sono scritte per la LicheePi Nano, che è
  una board diversa, e applicarle a questa produce guasti silenziosi.
* [docs/SCELTE-DI-PROGETTO.md](docs/SCELTE-DI-PROGETTO.md) — perché l'albero è
  fatto così, e cosa si rompe cambiando idea.
* [CLAUDE.md](CLAUDE.md) — riferimento operativo su Buildroot, U-Boot e kernel
  per questa board.

## Struttura

```
.
├── buildroot/                    submodule, Buildroot LTS 2026.02.3
├── external/                     BR2_EXTERNAL: tutto il codice di questa board
│   ├── external.desc             name: F1C200S
│   ├── external.mk
│   ├── Config.in
│   ├── configs/
│   │   └── ftvogue_f1c200s_defconfig
│   └── board/ftvogue-f1c200s/
│       ├── linux.fragment        opzioni kernel sopra sunxi_defconfig
│       ├── uboot.fragment        opzioni U-Boot sopra lctech_pi_f1c200s_defconfig
│       ├── genimage.cfg          layout dell'immagine SD
│       └── readme.txt
├── docs/
│   ├── BOARD-FACTS.md
│   ├── SCELTE-DI-PROGETTO.md
│   └── check-image.sh            verifica gli artefatti senza avere la board
├── Makefile                      wrapper su Buildroot
└── setup.sh                      submodule + dipendenze host
```

Buildroot non viene mai modificato: tutto si esprime nel defconfig e nei
fragment. Per aggiungere package propri basta crearli in
`external/package/<nome>/`, il wildcard in `external.mk` li raccoglie da solo.

## Prerequisiti

Una distro Linux recente. Su Debian/Ubuntu:

```bash
sudo apt install build-essential git bc bison flex libssl-dev \
     libncurses-dev python3 rsync cpio unzip wget file swig
```

`setup.sh` verifica che ci siano tutte e dice cosa manca.

Non serve né Docker né una toolchain preinstallata: Buildroot costruisce la
propria (`arm-buildroot-linux-gnueabi-`, EABI soft float).

## Build

```bash
git clone --recurse-submodules <url> f1c200s-framework
cd f1c200s-framework
./setup.sh

make ftvogue_f1c200s_defconfig
make
```

La prima build costruisce anche la toolchain: mettila in conto. Le successive
sono incrementali.

Opzioni utili del wrapper:

```bash
make DL_DIR=$HOME/.cache/buildroot-dl     # cache dei sorgenti condivisa
make MIRROR=https://.../dl                # mirror dei tarball (BR2_PRIMARY_SITE)
make defconfigs                           # elenca i defconfig
make help
```

Entrambe possono stare in `local.mk` (in `.gitignore`) invece che sulla riga di
comando.

Qualunque altro target è inoltrato a Buildroot così com'è: `make menuconfig`,
`make linux-menuconfig`, `make linux-diff-config`, `make uboot-reconfigure`,
`make printvars VARS=...`.

> **Dopo aver modificato un fragment Buildroot non se ne accorge da solo:**
> serve `make linux-reconfigure` o `make uboot-reconfigure` prima di `make`.

## Verifica

```bash
make check
```

Controlla gli artefatti senza bisogno della board: header `eGON.BT0` a 8 KiB,
layout delle partizioni, contenuto della FAT, `CONS_INDEX=2`, mappa DRAM a
64 MB, kernel davvero ARMv5/`suniv`, `bootcmd` compilato nel binario, `model`
del DTB. Ogni controllo corrisponde a un errore realmente commesso durante il
bring-up.

## Flash su SD

```bash
lsblk -o NAME,SIZE,RM,MODEL           # la SD ha RM=1
sudo dd if=output/images/sdcard.img of=/dev/sdX bs=1M conv=fsync status=progress
```

`/dev/sdX` è il **device**, non una partizione (`/dev/sdb`, non `/dev/sdb1`).

La BROM prova prima la SD e poi la SPI: con la SD inserita parte questa
immagine, togliendola riparte il sistema di fabbrica nella NAND.

## Console seriale

```bash
picocom -b 115200 /dev/ttyUSB0        # oppure: screen /dev/ttyUSB0 115200
```

Cablaggio USB-TTL ↔ board: **GND ↔ GND**, **RX ↔ PA2** (TX della board),
**TX ↔ PA3** (RX della board). Se la board è già alimentata dalla USB-C, **non**
collegare il 5V/3V3 dell'adattatore.

Login: `root`, senza password.

> Se non esce **nessun** carattere, il primo sospetto non è la board: è la UART.
> Questa board parla su UART1 (PA2/PA3), non su UART0. Vedi
> [BOARD-FACTS §3](docs/BOARD-FACTS.md).

## Recovery via FEL

FEL passa dalla USB-C e non dipende dalla seriale: è il modo per sapere se il
SoC è vivo quando la console tace.

```bash
# togli la SD, tieni premuto FEL/BOOT mentre colleghi la USB-C
lsusb | grep 1f3a:efe8                # Allwinner sunxi SoC in FEL mode
./output/host/bin/sunxi-fel version
```

Caricare ed eseguire U-Boot in RAM senza toccare SD né NAND:

```bash
./output/host/bin/sunxi-fel -p spl   output/images/u-boot-sunxi-with-spl.bin
./output/host/bin/sunxi-fel -p write 0x81700000 output/images/u-boot.bin
./output/host/bin/sunxi-fel exe      0x81700000
```

Se **qui** esce output su UART1 la build è corretta e il problema è la SD; se
non esce nulla nemmeno così, il problema è il cablaggio seriale.

## Limiti noti

* **Non si boota dalla SPI NAND.** L'SPL di U-Boot mainline non sa leggerla
  (verificato su v2025.10, v2026.04, v2026.07). Servirebbe un bootloader fuori
  mainline — awboot o U-Boot patchato — **non provato**. Vedi
  [BOARD-FACTS §2](docs/BOARD-FACTS.md).
* **La NAND non è usata affatto**, nemmeno come storage. Usarla come rootfs UBI
  con U-Boot che parte da SD non richiede niente fuori mainline, ma non è
  ancora implementato.
* **LCD, CSI e audio non sono configurati.**

## Licenza

GPL-2.0-or-later. Vedi [LICENSE](LICENSE).

# Boot autonomo da SPI NAND — design

Data: 2026-09-28 · Stato: da rivedere

## Obiettivo

La board deve partire e girare **interamente dalla SPI NAND**, senza SD:
SPL, U-Boot, kernel, DTB e rootfs in flash. L'immagine SD continua a esistere
ed è prodotta dallo **stesso defconfig**: serve per sviluppo e recovery.

Vincolo hardware, non di design: la BROM prova prima la SD. Una SD avviabile
inserita ha sempre la precedenza sulla NAND.

### Criteri di successo

1. Senza SD, dopo `docs/flash-nand.sh`: seriale mostra `U-Boot SPL`,
   poi `boot: NAND`, poi login; `mount` riporta `ubi0:rootfs` su `/`.
2. Con SD inserita: `boot: SD`, rootfs su `/dev/mmcblk0p2`.
3. Un file scritto nel rootfs NAND sopravvive a un riavvio a freddo.
4. `make check` passa e copre i guasti silenziosi elencati sotto.

### Fuori scopo

- Aggiornamenti atomici / schema A/B, rootfs read-only.
- Gestione dei bad block nella zona bootloader (blocchi 0–7).
- Environment U-Boot persistente.

## Fatti di partenza

- Chip: **GigaDevice GD5F1GQ4xAYIG** (`xfel spinand`), 128 MiB, pagina
  2048 B + 64 B OOB, blocco 64 pagine = 128 KiB, 1024 blocchi, max 20 bad
  block, ECC on-die. Supportato da U-Boot 2026.07 e Linux 6.12
  (`drivers/mtd/nand/spi/gigadevice.c`, voce `GD5F1GQ4xA`).
- L'SPL mainline non legge la SPI NAND; su suniv
  `suniv_get_boot_source()` restituisce `SUNXI_INVALID_BOOT_SOURCE` per
  `SUNIV_BOOTED_FROM_NAND` (`arch/arm/mach-sunxi/board.c`).
- Su suniv U-Boot proper **non conosce la sorgente di boot**: restituisce
  sempre MMC0 come segnaposto (header SPL in SRAM sovrascritto dai vettori).
- Lato U-Boot proper e kernel tutto è mainline: `spi-sunxi` / `spi-sun6i`
  via il fallback `allwinner,sun8i-h3-spi`, core `mtd/nand/spi`, UBI, UBIFS.
- Patch SPL esistenti: serie di Icenowy Zheng, 2022-10-14, "SUNIV SPI NAND
  support in SPL" (patchwork series 322733, stato *deferred*, mai
  integrata). Nessun fork basato su 2026.x.
- `xfel spinand splwrite <split> <addr> <file>`: scrive i primi `splsz`
  byte (dall'header eGON) in formato *split* per pagina, arrotondati a un
  blocco; se `addr` supera quella zona ripete la zona SPL fino ad `addr` e
  scrive **l'intero file lineare** a `addr`. Con `addr = 0` il resto del
  file viene scartato. Nessuna gestione bad block.

## Scelta dell'approccio

Porting minimo su U-Boot 2026.07 delle sole patch di codice della serie di
Icenowy (non le tre *DO NOT MERGE*). Scartati: il fork `jookia_main`
(regressione a v2025.04, 142 commit non controllati, testato solo su T113)
e awboot (si perde U-Boot come ambiente di recovery/debug).

## Layout NAND

```
offset      blocchi  contenuto
0x000000    0        SPL, formato split 1 KiB/pagina
0x020000    1        SPL, seconda copia (effetto di splwrite, non garanzia)
0x040000    2-7      u-boot-sunxi-with-spl.bin lineare
                     └─ u-boot.img a 0x048000   = CONFIG_SYS_SPI_U_BOOT_OFFS
0x100000    8-1023   MTD "ubi" (127 MiB)
                     └─ volume UBI "rootfs", UBIFS, autoresize
                        └─ /boot/zImage, /boot/suniv-f1c200s-lctech-pi.dtb
```

Partizioni MTD, identiche in U-Boot e kernel: `1M(boot),-(ubi)`.

Nella zona `boot` nessuno salta i bad block (né SPL né xfel): rischio
residuo accettato. Da `0x100000` UBI gestisce bad block e wear leveling
**a regime**; la riserva di default (20 PEB su 1024) coincide col massimo
del chip. La prima scrittura via xfel invece non salta i bad block nemmeno
lì: `flash-nand.sh` rilegge e confronta per accorgersene (correzione dopo
la review finale).

## Flashing

`docs/flash-nand.sh`, versionato, verifica che gli artefatti esistano ed
esegue:

```bash
xfel spinand erase 0 0x8000000
xfel spinand splwrite 1024 0x40000 output/images/u-boot-sunxi-with-spl.bin
xfel spinand write 0x100000 output/images/rootfs.ubi
```

L'erase dell'intera flash è voluto: UBI richiede che i PEB non scritti
dall'immagine siano cancellati, altrimenti l'attach fallisce.

## U-Boot

### Patch

`external/board/ftvogue-f1c200s/patches/uboot/NNNN-*.patch`, formato
`git format-patch`, autore originale conservato, nota di porting nel
messaggio. Collegate con
`BR2_GLOBAL_PATCH_DIR="$(BR2_EXTERNAL_F1C200S_PATH)/board/ftvogue-f1c200s/patches"`.

Directory **senza** sottodirectory di versione, di proposito: con
`uboot/2026.07/` un bump di versione farebbe saltare le patch in silenzio,
producendo un SPL che non legge la NAND. Senza versione, un bump che le
rompe fa fallire la build al passo di patch.

### Frammento

Lato SPL (nomi esatti dei simboli da confermare sulle patch portate):

```
CONFIG_SPL_SPI_SUNXI=y
CONFIG_SPL_SPI_SUNXI_NAND=y
CONFIG_SPL_SPI_SUNXI_NAND_ASSUMED_PAGESIZE=0x800
CONFIG_SYS_SPI_U_BOOT_OFFS=0x48000
```

Lato U-Boot proper: `MTD_SPI_NAND`, `DM_MTD`, `CMD_MTD`, `CMD_UBI`,
`CMD_UBIFS`; `MTDIDS_DEFAULT` / `MTDPARTS_DEFAULT` con `1M(boot),-(ubi)`.

Environment: `# CONFIG_ENV_IS_IN_SPI_FLASH is not set`,
`CONFIG_ENV_IS_NOWHERE=y`.

`CONFIG_BOOTARGS` rimosso: lo imposta ciascun ramo del `bootcmd`.

### Selezione SD / NAND

Poiché U-Boot proper non conosce la sorgente di boot, si usa la garanzia
della BROM: se gira dalla NAND, una SD avviabile con la nostra FAT non c'è.

```
if test -e mmc 0:1 zImage; then
    echo "boot: SD"
    setenv bootargs "console=ttyS0,115200 earlyprintk root=/dev/mmcblk0p2 rootwait rw"
    load mmc 0:1 0x80008000 zImage &&
    load mmc 0:1 0x81800000 suniv-f1c200s-lctech-pi.dtb
else
    echo "boot: NAND"
    setenv bootargs "console=ttyS0,115200 earlyprintk mtdparts=spi0.0:1M(boot),-(ubi) ubi.mtd=ubi root=ubi0:rootfs rootfstype=ubifs rw"
    ubi part ubi && ubifsmount ubi0:rootfs &&
    ubifsload 0x80008000 /boot/zImage &&
    ubifsload 0x81800000 /boot/suniv-f1c200s-lctech-pi.dtb
fi && bootz 0x80008000 - 0x81800000
```

È una selezione, non un fallback: se il ramo scelto fallisce il boot si
ferma. Caso limite noto: SD non avviabile ma con la nostra FAT → U-Boot da
NAND, kernel da SD; la riga `boot:` lo rende visibile.

### Vincolo di dimensione

`0x48000 + size(u-boot.img) ≤ 0x100000` (736 KiB). Oltre, U-Boot
corromperebbe il primo PEB di UBI senza errori visibili.

## Kernel

`linux.fragment`, tutto built-in (niente initramfs):

```
CONFIG_SPI_SUN6I=y
CONFIG_MTD=y
CONFIG_MTD_SPI_NAND=y
CONFIG_MTD_CMDLINE_PARTS=y
CONFIG_MTD_UBI=y
CONFIG_UBIFS_FS=y
```

Partizioni passate da cmdline: il DTS upstream non ne dichiara, e un DTS
proprio solo per questo non vale il costo di mantenerlo.

## Rootfs

Resta `rootfs.ext4` per la SD; si aggiunge `rootfs.ubi`:

| Opzione | Valore |
|---|---|
| `BR2_TARGET_ROOTFS_UBI` / `UBIFS` | `y` |
| `BR2_TARGET_ROOTFS_UBI_PEBSIZE` | `0x20000` |
| `BR2_TARGET_ROOTFS_UBI_SUBSIZE` | `2048` |
| `BR2_TARGET_ROOTFS_UBIFS_LEBSIZE` | `0x1f000` |
| `BR2_TARGET_ROOTFS_UBIFS_MINIOSIZE` | `0x800` |
| `BR2_TARGET_ROOTFS_UBIFS_MAXLEBCNT` | `1016` (i PEB della partizione `ubi`: tetto, non dimensione) |
| compressione | LZO (letta da U-Boot) |

Si usa il `ubinize.cfg` di default di Buildroot (volume `rootfs`,
`autoresize`). `BR2_LINUX_KERNEL_INSTALL_TARGET=y` installa `zImage` e DTB
in `/boot`; sulla SD sono un duplicato inutilizzato di ~4 MB, accettato per
avere un solo rootfs.

## Verifiche automatiche (`make check`)

| Guasto silenzioso | Controllo |
|---|---|
| Patch saltate | `CONFIG_SPL_SPI_SUNXI_NAND=y` nel `.config` di U-Boot; stringa del loader NAND in `sunxi-spl.bin` |
| U-Boot che sfora in UBI | `0x48000 + size(u-boot.img) ≤ 0x100000` |
| Geometria UBI errata | header EC di `rootfs.ubi` via `od`: magic `UBI#`, VID header a 2048, dati a 4096 |
| Kernel senza NAND | `MTD_SPI_NAND`, `MTD_UBI`, `UBIFS_FS`, `SPI_SUN6I` `=y` |
| `bootcmd` monco | `ubi part` e `test -e mmc` in `u-boot.bin` |
| Kernel non installato | `/boot/zImage` e DTB in `output/target` |

## Documentazione da aggiornare

- `docs/BOARD-FACTS.md`: identità del chip fuori dagli "Aperti"; layout NAND.
- `docs/SCELTE-DI-PROGETTO.md`: patch vs fork, selezione via `test -e`,
  directory patch senza versione, env nowhere.
- `CLAUDE.md`: trappola 2 riformulata; righe in "Dove si cambia cosa" e in
  "Sintomi → causa"; `flash-nand.sh` nei comandi.
- `external/board/ftvogue-f1c200s/readme.txt`: procedura di flashing e
  verifica manuale sulla board.

## Da confermare sull'hardware

Non verificabili prima di provare; restano "non verificato" nei docs finché
non lo sono:

1. Il porting delle patch su 2026.07 funziona sul silicio.
2. Il nome MTD del kernel è `spi0.0`.
3. La BROM usa la seconda copia SPL nel blocco 1 se il blocco 0 è illeggibile.

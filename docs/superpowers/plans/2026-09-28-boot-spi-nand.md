# Boot autonomo da SPI NAND — piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** la FTVOGUE F1C200S parte e gira interamente dalla SPI NAND
(SPL, U-Boot, kernel, DTB, rootfs UBIFS), mentre lo stesso defconfig continua
a produrre `sdcard.img`.

**Architecture:** cinque patch SPL (serie di Icenowy Zheng, 2022, portata a
U-Boot 2026.07) applicate via `BR2_GLOBAL_PATCH_DIR`; U-Boot proper usa
mainline (`MTD_SPI_NAND`, UBI, UBIFS) e un `bootcmd` che sceglie SD o NAND con
`test -e mmc 0:1 zImage`; il rootfs diventa anche `rootfs.ubi`, con kernel e DTB
in `/boot`; `docs/flash-nand.sh` scrive tutto con `xfel`.

**Tech Stack:** Buildroot 2026.02.3 (submodule), U-Boot 2026.07, Linux
6.12.111, xfel, bash.

**Spec:** [docs/superpowers/specs/2026-09-28-boot-spi-nand-design.md](../specs/2026-09-28-boot-spi-nand-design.md)

## Global Constraints

- `buildroot/` non si modifica mai: tutto passa da `external/` e dal defconfig.
- Percorsi nel defconfig sempre con `$(BR2_EXTERNAL_F1C200S_PATH)`, mai relativi.
- Defconfig canonico: dopo ogni modifica `make savedefconfig` non deve generare diff (lo verifica la CI).
- Non usare `-jN` sul make di primo livello.
- Layout NAND: SPL `0x0` (split 1 KiB/pagina), `u-boot-sunxi-with-spl.bin` lineare a `0x40000`, `u-boot.img` a `0x48000`, MTD `ubi` da `0x100000` a fine flash; partizioni `1M(boot),-(ubi)`.
- Geometria: pagina 2048, PEB `0x20000`, LEB `0x1f000`, min I/O `0x800`, sub-page `2048`, max LEB `1016`.
- Patch in `external/board/ftvogue-f1c200s/patches/uboot/` **senza** sottodirectory di versione.
- `0x40000 + size(u-boot-sunxi-with-spl.bin) ≤ 0x100000`.
- Script: `bash -n` e `shellcheck -S warning` puliti, file eseguibili (lo verifica la CI).
- Commenti e documenti in italiano, stile dei file esistenti; commit che terminano con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Bump di U-Boot che invalida le patch** — atteso: la build fallisce al passo di patch, non un SPL senza NAND. Coperto dal controllo `spi_load_read_nand` nella map SPL (Task 1).
2. **U-Boot proper che cresce oltre `0x100000`** — atteso: `make check` KO prima di flashare, e `flash-nand.sh` si rifiuta. Coperto nei Task 2 e 5.
3. **Offset di `u-boot.img` dentro il `.bin` diverso da `0x8000`** (SPL più grande dopo un bump) — atteso: `make check` KO, perché l'SPL cercherebbe a `0x48000` il vuoto. Coperto dal controllo del magic `27 05 19 56` (Task 2).
4. **NAND con residui del firmware di fabbrica nella zona UBI** — atteso: attach UBI pulito. Coperto dall'erase completo in `flash-nand.sh` (Task 5).
5. **`flash-nand.sh` lanciato senza board in FEL, con flash diversa o con artefatti mancanti** — atteso: esce con errore **prima** di qualunque erase. Coperto dai controlli iniziali dello script, provati a vuoto nel Task 5.

---

## Mappa dei file

| File | Azione | Responsabilità |
|---|---|---|
| `external/board/ftvogue-f1c200s/patches/uboot/000{1..5}-*.patch` | crea | lettore SPI NAND nell'SPL |
| `external/configs/ftvogue_f1c200s_defconfig` | modifica | patch dir, rootfs UBI, kernel in `/boot` |
| `external/board/ftvogue-f1c200s/uboot.fragment` | modifica | SPL NAND, MTD/UBI, env, `bootcmd` |
| `external/board/ftvogue-f1c200s/linux.fragment` | modifica | MTD SPI NAND, UBI, UBIFS |
| `docs/check-image.sh` | modifica | nuovi controlli dei guasti silenziosi |
| `docs/flash-nand.sh` | crea | flashing via xfel |
| `docs/BOARD-FACTS.md`, `docs/SCELTE-DI-PROGETTO.md`, `CLAUDE.md`, `external/board/ftvogue-f1c200s/readme.txt` | modifica | documentazione |

---

### Task 1: patch SPL SPI NAND

**Files:**
- Create: `external/board/ftvogue-f1c200s/patches/uboot/0001-sunxi-SPL-SPI-extract-code-for-doing-SPI-transfer.patch` … `0005-sunxi-enable-support-for-SPI-NAND-booting-on-SUNIV.patch`
- Modify: `external/configs/ftvogue_f1c200s_defconfig`
- Modify: `external/board/ftvogue-f1c200s/uboot.fragment`
- Test: `docs/check-image.sh` (sezione 4 e nuova sezione 8)

**Interfaces:**
- Produces: simboli Kconfig `CONFIG_SPL_SPI_SUNXI_NAND`, `CONFIG_SPL_SPI_SUNXI_NAND_ASSUMED_PAGESIZE`; funzione SPL `spi_load_read_nand` (usata come sonda da `check-image.sh`).

- [ ] **Step 1: aggiungere i controlli che devono fallire**

In `docs/check-image.sh`, sezione 4, dopo `chk 'CONFIG_DEFAULT_DEVICE_TREE=...'`:

```bash
	chk 'CONFIG_SPL_SPI_SUNXI=y'
	chk 'CONFIG_SPL_SPI_SUNXI_NAND=y'
	chk 'CONFIG_SPL_SPI_SUNXI_NAND_ASSUMED_PAGESIZE=0x800'
	chk 'CONFIG_SYS_SPI_U_BOOT_OFFS=0x48000'
```

Nuova sezione, dopo la 7 e prima del riepilogo finale:

```bash
# --- 8. l'SPL contiene davvero il lettore SPI NAND ---------------------------
# Le patch stanno in external/.../patches/uboot/. Se un bump di U-Boot le
# rendesse inapplicabili la build fallirebbe; se invece venissero saltate
# (per esempio spostate in una sottodirectory di versione) l'SPL uscirebbe
# senza lettore NAND, e lo si scoprirebbe solo con la board muta.
smap="$(ls -d "$BUILD"/uboot-*/spl/u-boot-spl.map 2>/dev/null | head -1)"
if [ -n "$smap" ] && [ -f "$smap" ]; then
	n="$(grep -c 'spi_load_read_nand' "$smap")"
	[ "${n:-0}" -ge 1 ] \
		&& pass "SPL: lettore SPI NAND presente (spi_load_read_nand)" \
		|| fail "SPL: manca spi_load_read_nand — patch non applicate?"
else
	skip "map dell'SPL non trovata: build fatta altrove?"
fi
```

- [ ] **Step 2: verificare che falliscano**

Run: `make check`
Expected: `KO u-boot: atteso CONFIG_SPL_SPI_SUNXI=y` (e le altre tre), `KO SPL: manca spi_load_read_nand`.

- [ ] **Step 3: produrre le patch**

In una directory di lavoro temporanea, fuori dal repo:

```bash
REPO=/home/walter/git/f1c200s-framework
W="$(mktemp -d)"
cd "$REPO" && make uboot-dirclean && make uboot-extract
cp -a output/build/uboot-2026.07 "$W/ub"
cd "$W/ub" && git init -q && git add -A && git commit -qm base
curl -sSL -o "$W/series.mbox" https://patchwork.ozlabs.org/series/322733/mbox/
python3 - "$W" <<'EOF'
import mailbox, sys
w = sys.argv[1]
for i, m in enumerate(mailbox.mbox(f'{w}/series.mbox')):
    if i < 5:
        open(f'{w}/p{i+1}.patch', 'wb').write(m.as_bytes())
EOF
git am ../p1.patch ../p2.patch        # si applicano pulite
```

La 3/8 non si applica: dal 2022 `CONFIG_SYS_TEXT_BASE` è diventato
`CONFIG_TEXT_BASE` e `struct spl_load_info` si inizializza con
`spl_load_init()`. Va portata a mano. In `arch/arm/mach-sunxi/spl_spi_sunxi.c`
si sostituisce tutto da `static ulong spi_load_read(struct spl_load_info *load, ulong sector,`
fino alla riga prima di `/* Use priorty 0 to override` con:

```c
static ulong spi_load_read_nor(struct spl_load_info *load, ulong sector,
			       ulong count, void *buf)
{
	spi0_read_data(buf, sector, count, 3);

	return count;
}

/*****************************************************************************/

static int spl_spi_try_load(struct spl_image_info *spl_image,
			    struct spl_boot_device *bootdev,
			    struct spl_load_info *load, u32 offset,
			    bool allow_raw)
{
	int ret = 0;
	struct legacy_img_hdr *header;
	header = (struct legacy_img_hdr *)CONFIG_TEXT_BASE;

	if (load->read(load, offset, 0x40, (void *)header) == 0)
		return -EINVAL;

        if (IS_ENABLED(CONFIG_SPL_LOAD_FIT) &&
		image_get_magic(header) == FDT_MAGIC) {

		debug("Found FIT image\n");
		ret = spl_load_simple_fit(spl_image, load,
					  offset, header);
	} else {
		if (!allow_raw && image_get_magic(header) != IH_MAGIC)
			return -EINVAL;

		ret = spl_parse_image_header(spl_image, bootdev, header);
		if (ret)
			return ret;

		if (load->read(load, offset, spl_image->size,
			       (void *)spl_image->load_addr) == 0)
			ret = -EINVAL;
	}

	return ret;
}

static int spl_spi_load_image(struct spl_image_info *spl_image,
			      struct spl_boot_device *bootdev)
{
	int ret = 0;
	uint32_t load_offset = sunxi_get_spl_size();
	struct spl_load_info load;

	load_offset = max_t(uint32_t, load_offset, CONFIG_SYS_SPI_U_BOOT_OFFS);

	spl_load_init(&load, spi_load_read_nor, NULL, 1);

	spi0_init();

	load.read = spi_load_read_nor;
	ret = spl_spi_try_load(spl_image, bootdev, &load, load_offset, true);

	spi0_deinit();

	return ret;
}
```

(L'indentazione con spazi davanti a `if (IS_ENABLED(CONFIG_SPL_LOAD_FIT)` è
quella di upstream: non va "sistemata", altrimenti la 4/8 non si applica.)

Commit con l'autore e il messaggio originali più la nota di porting:

```bash
git commit -a --author="Icenowy Zheng <uwu@icenowy.me>" --date="Fri, 14 Oct 2022 11:05:15 +0800" -F - <<'EOF'
sunxi: SPL SPI: allow multiple boot attempt

As we're going to add support for SPI NAND to this code, add code that
allows multiple boot attempts with different load offsets and functions.

To keep compatibility with loading raw binary on SPI NOR, a bool
parameter is used to allow booting without valid magic number when
booting with SPI NOR.

Signed-off-by: Icenowy Zheng <uwu@icenowy.me>
Reviewed-by: Samuel Holland <samuel@sholland.org>
Tested-by: Samuel Holland <samuel@sholland.org> # Orange Pi Zero Plus

[walter: porting a v2026.07 - CONFIG_SYS_TEXT_BASE diventato
 CONFIG_TEXT_BASE; struct spl_load_info inizializzata con spl_load_init()]
Signed-off-by: Walter Dal Mut <walter.dalmut@corley.it>
EOF
```

Applicare la 4/8. A seconda del contesto l'ultimo hunk (quello su
`spl_spi_load_image()`) può essere rifiutato; in entrambi i casi la funzione
va poi portata al testo esatto qui sotto:

```bash
git apply --reject ../p4.patch || true
rm -f arch/arm/mach-sunxi/*.rej
```

`spl_spi_load_image()` deve risultare **esattamente** così (rispetto alla 4/8
originale cambia solo `out: __maybe_unused;`, che toglie il warning
dell'etichetta inutilizzata quando la NAND è disabilitata):

```c
static int spl_spi_load_image(struct spl_image_info *spl_image,
			      struct spl_boot_device *bootdev)
{
	int ret = 0;
	uint32_t load_offset = sunxi_get_spl_size();
	struct spl_load_info load;

	load_offset = max_t(uint32_t, load_offset, CONFIG_SYS_SPI_U_BOOT_OFFS);

	spl_load_init(&load, spi_load_read_nor, NULL, 1);

	spi0_init();

#if defined(CONFIG_SPL_SPI_SUNXI_NAND)
	spi0_nand_reset();
	load.read = spi_load_read_nand;
	ret = spl_spi_try_load(spl_image, bootdev, &load, load_offset, false);
	if (!ret)
		goto out;
#endif

	load.read = spi_load_read_nor;
	ret = spl_spi_try_load(spl_image, bootdev, &load, load_offset, true);

out: __maybe_unused;
	spi0_deinit();

	return ret;
}
```

Controllo: `git diff` sulla funzione non deve mostrare altro; e compilando
con `CONFIG_SPL_SPI_SUNXI_NAND=y` (Step 4) non deve uscire nessun warning da
`spl_spi_sunxi.c`.

```bash
git add -A && git commit --author="Icenowy Zheng <uwu@icenowy.me>" --date="Fri, 14 Oct 2022 11:05:16 +0800" -F - <<'EOF'
sunxi: SPL SPI: add initial support for booting from SPI NAND

This commit adds support for booting from SPI NAND to SPL SPI code by
mimicing the behavior of boot ROM (use fixed page size and sequentially
try SPI NOR and NAND).

Signed-off-by: Icenowy Zheng <uwu@icenowy.me>
Tested-by: Samuel Holland <samuel@sholland.org> # Orange Pi Zero Plus

[walter: porting a v2026.07 - hunk su spl_spi_load_image() rifatto sopra
 il porting della 3/8; etichetta out: marcata __maybe_unused (warning
 segnalato in review da Samuel Holland)]
Signed-off-by: Walter Dal Mut <walter.dalmut@corley.it>
EOF
git am ../p5.patch                    # si applica pulita
mkdir -p "$REPO"/external/board/ftvogue-f1c200s/patches/uboot
git format-patch -5 -o "$REPO"/external/board/ftvogue-f1c200s/patches/uboot
```

Expected: cinque file `0001-…` … `0005-…`; nessun `*.rej` rimasto.

- [ ] **Step 4: collegare le patch e abilitare l'SPL NAND**

Nel defconfig, riga da aggiungere (poi rinormalizzata da savedefconfig):

```
BR2_GLOBAL_PATCH_DIR="$(BR2_EXTERNAL_F1C200S_PATH)/board/ftvogue-f1c200s/patches"
```

In `uboot.fragment`, in coda:

```
# Boot da SPI NAND. L'SPL mainline non sa leggerla: servono le patch in
# patches/uboot/ (serie di Icenowy Zheng, 2022, portata a 2026.07). La
# pagina assunta e' quella reale del chip (2 KiB): solo l'SPL sta nel
# formato "1 KiB per pagina" della BROM, U-Boot proper e' lineare.
# 0x48000 = 0x40000 (dove flash-nand.sh scrive il .bin) + 0x8000 (offset
# di u-boot.img dentro u-boot-sunxi-with-spl.bin).
CONFIG_SPL_SPI_SUNXI=y
CONFIG_SPL_SPI_SUNXI_NAND=y
CONFIG_SPL_SPI_SUNXI_NAND_ASSUMED_PAGESIZE=0x800
CONFIG_SYS_SPI_U_BOOT_OFFS=0x48000
```

```bash
make ftvogue_f1c200s_defconfig
make savedefconfig
git diff external/configs/        # deve mostrare solo la riga BR2_GLOBAL_PATCH_DIR
make uboot-dirclean
make
```

Expected: nel log di build `Applying 0001-…` … `0005-…` per uboot; build ok.

- [ ] **Step 5: verificare**

Run: `make check`
Expected: `ok` per le quattro righe `u-boot: CONFIG_SPL_…` / `SYS_SPI_U_BOOT_OFFS` e per `SPL: lettore SPI NAND presente`; nessun KO nuovo sulle sezioni 1–7.

- [ ] **Step 6: commit**

```bash
git add external/board/ftvogue-f1c200s/patches external/configs/ftvogue_f1c200s_defconfig \
        external/board/ftvogue-f1c200s/uboot.fragment docs/check-image.sh
git commit -m "u-boot: SPL capace di leggere la SPI NAND

Porting a 2026.07 delle patch 1-5 della serie di Icenowy Zheng
(patchwork 322733), applicate via BR2_GLOBAL_PATCH_DIR.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: U-Boot proper — MTD/UBI, environment, `bootcmd` SD/NAND

**Files:**
- Modify: `external/board/ftvogue-f1c200s/uboot.fragment`
- Test: `docs/check-image.sh` (sezioni 4, 6 e nuova 9)

**Interfaces:**
- Consumes: SPL del Task 1 (legge `u-boot.img` a `0x48000`).
- Produces: partizioni MTD `boot` e `ubi` (nomi usati anche dal kernel, Task 3); `bootcmd` che carica `/boot/zImage` e `/boot/suniv-f1c200s-lctech-pi.dtb` dal volume `ubi0:rootfs` (prodotti dal Task 4).

- [ ] **Step 1: aggiungere e correggere i controlli**

Sezione 4, dopo i `chk` del Task 1:

```bash
	chk 'CONFIG_MTD_SPI_NAND=y'
	chk 'CONFIG_CMD_UBI=y'
	chk 'CONFIG_CMD_UBIFS=y'
	chk 'CONFIG_ENV_IS_NOWHERE=y'
	chk 'CONFIG_MTDPARTS_DEFAULT="mtdparts=spi0.0:1M(boot),-(ubi)"'
	grep -q '^CONFIG_BOOTCOMMAND=.*ubi part ubi' "$ucfg" \
		&& pass "u-boot: bootcmd ha il ramo NAND (ubi part ubi)" \
		|| fail "u-boot: il bootcmd non ha il ramo NAND"
```

Sezione 6: `bootcmd=` in `strings` **non** è a inizio riga (è attaccato alla
stringa precedente), quindi niente `^`. Sostituire il blocco con:

```bash
	n="$(strings "$IMAGES/u-boot.bin" | grep -c 'bootcmd=if test -e mmc 0:1 zImage')"
	[ "${n:-0}" -ge 1 ] \
		&& pass "bootcmd SD/NAND presente nell'ambiente compilato in u-boot.bin" \
		|| fail "bootcmd non trovato in u-boot.bin: il fragment non e' stato applicato"
```

Nuova sezione dopo la 8:

```bash
# --- 9. U-Boot sta nella zona boot della NAND --------------------------------
# flash-nand.sh scrive u-boot-sunxi-with-spl.bin lineare a 0x40000; la
# partizione UBI parte a 0x100000. Se U-Boot cresce oltre, il primo PEB di
# UBI viene sovrascritto e nessuno se ne accorge fino all'attach.
# L'SPL cerca u-boot.img a 0x48000, cioe' a +0x8000 nel file: se un bump
# sposta quell'offset, li' c'e' il vuoto.
ubin="$IMAGES/u-boot-sunxi-with-spl.bin"
if [ -f "$ubin" ]; then
	size="$(stat -c %s "$ubin")"
	[ $((0x40000 + size)) -le $((0x100000)) ] \
		&& pass "NAND: u-boot-sunxi-with-spl.bin ($size B) finisce prima di 0x100000" \
		|| fail "NAND: u-boot-sunxi-with-spl.bin ($size B) sfora in UBI"
	magic="$(od -An -tx1 -j $((0x8000)) -N4 "$ubin" | tr -d ' ')"
	[ "$magic" = 27051956 ] \
		&& pass "NAND: u-boot.img a +0x8000 nel file (flash 0x48000)" \
		|| fail "NAND: a +0x8000 c'e' '$magic' invece dell'header uImage"
else
	fail "u-boot-sunxi-with-spl.bin assente"
fi
```

- [ ] **Step 2: verificare che falliscano**

Run: `make check`
Expected: KO sulle cinque `chk` nuove, sul ramo NAND e sulla sezione 6. La sezione 9 può già passare: il suo compito è intercettare regressioni future.

- [ ] **Step 3: configurare U-Boot proper**

In `uboot.fragment` rimuovere le due righe

```
CONFIG_USE_BOOTARGS=y
CONFIG_BOOTARGS="console=ttyS0,115200 earlyprintk root=/dev/mmcblk0p2 rootwait rw"
```

e sostituire la riga `CONFIG_BOOTCOMMAND=` con il blocco seguente, aggiornando
il commento che la precede:

```
# Boot esplicito, niente bootstd/distro-boot e niente boot.scr: meno pezzi
# mobili, e nessun fallback che maschera un errore. Attenzione: definire
# CONFIG_BOOTCOMMAND disattiva di fatto extlinux.conf e boot.scr.
#
# Un solo U-Boot per SD e NAND. Su suniv U-Boot proper non sa da dove e'
# partito (sunxi_get_boot_source() restituisce sempre MMC0), quindi si usa
# la garanzia della BROM: se una SD avviabile e' inserita parte da li'. Se
# la FAT della SD c'e', si usa la SD; altrimenti la NAND. E' una selezione,
# non un fallback: se il ramo scelto fallisce, il boot si ferma.
# I bootargs stanno fra virgolette perche' hush tratta '(' come subshell.
# CONFIG_BOOTARGS non si usa: lo imposta ciascun ramo.
# CONFIG_USE_BOOTARGS is not set
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="if test -e mmc 0:1 zImage; then echo boot: SD; setenv bootargs \"console=ttyS0,115200 earlyprintk root=/dev/mmcblk0p2 rootwait rw\"; load mmc 0:1 0x80008000 zImage && load mmc 0:1 0x81800000 suniv-f1c200s-lctech-pi.dtb; else echo boot: NAND; setenv bootargs \"console=ttyS0,115200 earlyprintk mtdparts=spi0.0:1M(boot),-(ubi) ubi.mtd=ubi root=ubi0:rootfs rootfstype=ubifs rw\"; ubi part ubi && ubifsmount ubi0:rootfs && ubifsload 0x80008000 /boot/zImage && ubifsload 0x81800000 /boot/suniv-f1c200s-lctech-pi.dtb; fi && bootz 0x80008000 - 0x81800000"
```

In coda al fragment:

```
# SPI NAND in U-Boot proper: tutto mainline. Il controller spi0 si aggancia
# via il compatible di fallback allwinner,sun8i-h3-spi.
CONFIG_DM_MTD=y
CONFIG_MTD_SPI_NAND=y
CONFIG_CMD_MTD=y
CONFIG_CMD_MTDPARTS=y
CONFIG_MTDIDS_DEFAULT="spi-nand0=spi0.0"
CONFIG_MTDPARTS_DEFAULT="mtdparts=spi0.0:1M(boot),-(ubi)"
CONFIG_CMD_UBI=y
CONFIG_CMD_UBIFS=y

# L'environment nel defconfig upstream sta su SPI NOR, che qui non esiste.
# Nessun environment persistente: vale quello compilato, coerente con il
# bootcmd esplicito.
# CONFIG_ENV_IS_IN_SPI_FLASH is not set
CONFIG_ENV_IS_NOWHERE=y
```

```bash
make uboot-reconfigure
make
```

- [ ] **Step 4: verificare**

Run: `make check`
Expected: tutti `ok` nelle sezioni 4, 6, 8, 9. Con la build di prova fatta in
fase di design, `u-boot-sunxi-with-spl.bin` era di circa 600 KB (limite
786432 B).

Run: `grep -rn 'sf read\|sf probe\|spiflash-write' external/board/*/uboot.fragment`
Expected: nessun risultato (è il controllo della CI).

- [ ] **Step 5: commit**

```bash
git add external/board/ftvogue-f1c200s/uboot.fragment docs/check-image.sh
git commit -m "u-boot: MTD/UBI e bootcmd che sceglie fra SD e NAND

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: kernel — SPI NAND, UBI, UBIFS

**Files:**
- Modify: `external/board/ftvogue-f1c200s/linux.fragment`
- Test: `docs/check-image.sh` (sezione 5)

**Interfaces:**
- Consumes: `mtdparts=spi0.0:1M(boot),-(ubi)` e `ubi.mtd=ubi` dai bootargs del Task 2.
- Produces: kernel che monta `ubi0:rootfs`.

- [ ] **Step 1: controlli**

Sezione 5, dopo `chk 'CONFIG_EXT4_FS=y'`:

```bash
	chk 'CONFIG_SPI_SUN6I=y'
	chk 'CONFIG_MTD_SPI_NAND=y'
	chk 'CONFIG_MTD_CMDLINE_PARTS=y'
	chk 'CONFIG_MTD_UBI=y'
	chk 'CONFIG_UBIFS_FS=y'
```

- [ ] **Step 2: verificare che falliscano**

Run: `make check`
Expected: KO su `MTD_SPI_NAND`, `MTD_CMDLINE_PARTS`, `MTD_UBI`, `UBIFS_FS`. `SPI_SUN6I` passa già perché è in `sunxi_defconfig`: resta come guardia.

- [ ] **Step 3: fragment**

In `linux.fragment`, dopo il blocco "Boot da SD":

```
# Boot da SPI NAND: rootfs UBIFS sul volume ubi0:rootfs. Tutto built-in,
# niente initramfs. Le partizioni arrivano da cmdline (mtdparts=) perche'
# il DTS upstream non ne dichiara. SPI_SUN6I copre spi0 via il compatible
# di fallback allwinner,sun8i-h3-spi; e' gia' in sunxi_defconfig, ripetuto
# perche' senza di lui la NAND sparisce in silenzio.
CONFIG_SPI_SUN6I=y
CONFIG_MTD=y
CONFIG_MTD_SPI_NAND=y
CONFIG_MTD_CMDLINE_PARTS=y
CONFIG_MTD_UBI=y
CONFIG_UBIFS_FS=y
```

```bash
make linux-reconfigure
make
```

- [ ] **Step 4: verificare**

Run: `make check`
Expected: tutti `ok` nella sezione 5.

- [ ] **Step 5: commit**

```bash
git add external/board/ftvogue-f1c200s/linux.fragment docs/check-image.sh
git commit -m "kernel: SPI NAND, UBI e UBIFS built-in

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: rootfs UBI con kernel e DTB in `/boot`

**Files:**
- Modify: `external/configs/ftvogue_f1c200s_defconfig`
- Test: `docs/check-image.sh` (nuove sezioni 10 e 11)

**Interfaces:**
- Consumes: geometria dei Global Constraints; nomi dei file letti dal `bootcmd` del Task 2.
- Produces: `output/images/rootfs.ubi` (usato dal Task 5).

- [ ] **Step 1: controlli**

Dopo la sezione 9:

```bash
# --- 10. rootfs.ubi ha la geometria della NAND -------------------------------
# GD5F1GQ4xA: pagina 2048, niente sub-page. Con -m 2048 -s 2048 l'header EC
# dice VID header a 2048 e dati a 4096. Una geometria sbagliata produce
# un'immagine che ubinize accetta e che il kernel rifiuta all'attach.
ubi="$IMAGES/rootfs.ubi"
if [ -f "$ubi" ]; then
	m="$(dd if="$ubi" bs=1 count=4 2>/dev/null)"
	[ "$m" = 'UBI#' ] && pass "rootfs.ubi: magic UBI#" || fail "rootfs.ubi: magic '$m'"
	offs="$(od -An -tx1 -j16 -N8 "$ubi" | tr -d ' \n')"
	[ "$offs" = 0000080000001000 ] \
		&& pass "rootfs.ubi: VID header a 2048, dati a 4096" \
		|| fail "rootfs.ubi: offset VID/dati = $offs (attesi 0x800 / 0x1000)"
	size="$(stat -c %s "$ubi")"
	[ "$size" -le $((0x8000000 - 0x100000)) ] \
		&& pass "rootfs.ubi ($size B) sta nella partizione ubi" \
		|| fail "rootfs.ubi ($size B) non sta nei 127 MiB della partizione ubi"
else
	fail "rootfs.ubi assente"
fi

# --- 11. kernel e DTB nel rootfs, dove li cerca il ramo NAND del bootcmd ----
tgt="$IMAGES/../target/boot"
for f in zImage suniv-f1c200s-lctech-pi.dtb; do
	[ -f "$tgt/$f" ] && pass "rootfs: /boot/$f" || fail "rootfs: manca /boot/$f"
done
```

- [ ] **Step 2: verificare che falliscano**

Run: `make check`
Expected: `KO rootfs.ubi assente`, `KO rootfs: manca /boot/zImage`, `KO … dtb`.

- [ ] **Step 3: defconfig**

Aggiungere al defconfig:

```
BR2_LINUX_KERNEL_INSTALL_TARGET=y
BR2_TARGET_ROOTFS_UBI=y
BR2_TARGET_ROOTFS_UBI_SUBSIZE=2048
BR2_TARGET_ROOTFS_UBIFS_LEBSIZE=0x1f000
BR2_TARGET_ROOTFS_UBIFS_MAXLEBCNT=1016
```

(PEB `0x20000`, min I/O `0x800` e compressione LZO sono i default di
Buildroot; `BR2_TARGET_ROOTFS_UBI` seleziona `BR2_TARGET_ROOTFS_UBIFS`;
savedefconfig li toglie.)

```bash
make ftvogue_f1c200s_defconfig
make savedefconfig
git diff external/configs/        # le cinque righe, in ordine canonico
make
```

- [ ] **Step 4: verificare**

Run: `make check`
Expected: tutto `ok`, riepilogo `tutto a posto.`

- [ ] **Step 5: commit**

```bash
git add external/configs/ftvogue_f1c200s_defconfig docs/check-image.sh
git commit -m "rootfs: immagine UBI per la NAND, kernel e DTB in /boot

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `docs/flash-nand.sh`

**Files:**
- Create: `docs/flash-nand.sh` (eseguibile)

**Interfaces:**
- Consumes: `output/images/u-boot-sunxi-with-spl.bin` e `output/images/rootfs.ubi`.

- [ ] **Step 1: prova a vuoto che deve fallire**

Run: `./docs/flash-nand.sh /nonexistent`
Expected: `No such file or directory`, perché lo script non esiste ancora.

- [ ] **Step 2: scrivere lo script**

```bash
#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Corley S.r.l.
#
# flash-nand.sh — scrive bootloader e rootfs nella SPI NAND via FEL.
#
#   ./docs/flash-nand.sh [output/images]
#
# La board deve essere in FEL e collegata via USB-C. Con la NAND vuota o
# senza un boot0 valido, e senza SD, la BROM ci va da sola. Con un
# bootloader valido in NAND: dal prompt di U-Boot `mtd erase boot`, poi
# reset. Layout e ragioni in docs/BOARD-FACTS.md.
#
# Ogni controllo avviene PRIMA dell'erase: se lo script si ferma, la flash
# e' intatta.
#
set -euo pipefail

IMAGES="${1:-output/images}"
UBOOT="$IMAGES/u-boot-sunxi-with-spl.bin"
ROOTFS="$IMAGES/rootfs.ubi"

NAND_SIZE=0x8000000     # 128 MiB, GD5F1GQ4xA
UBOOT_AT=0x40000        # splwrite: SPL nei blocchi 0-1, .bin lineare qui
UBI_AT=0x100000         # partizione MTD "ubi" (mtdparts 1M(boot),-(ubi))

die() { echo "flash-nand: $*" >&2; exit 1; }

command -v xfel >/dev/null 2>&1 || die "xfel non trovato nel PATH"
for f in "$UBOOT" "$ROOTFS"; do
	[ -f "$f" ] || die "manca $f (hai gia' lanciato 'make'?)"
done

size="$(stat -c %s "$UBOOT")"
[ $((UBOOT_AT + size)) -le $((UBI_AT)) ] \
	|| die "$UBOOT ($size B) sfora nella partizione UBI"
size="$(stat -c %s "$ROOTFS")"
[ "$size" -le $((NAND_SIZE - UBI_AT)) ] \
	|| die "$ROOTFS ($size B) non sta nella partizione UBI"

info="$(xfel spinand 2>&1)" || die "nessuna board in FEL: $info"
echo "$info"
case "$info" in
	*"with 134217728 bytes"*) ;;
	*) die "flash inattesa (attesa SPI NAND da 128 MiB): $info" ;;
esac

# Erase completo: UBI vuole che i PEB non coperti dall'immagine siano
# cancellati, altrimenti i residui del firmware di fabbrica fanno fallire
# l'attach.
xfel spinand erase 0 "$NAND_SIZE"
xfel spinand splwrite 1024 "$UBOOT_AT" "$UBOOT"
xfel spinand write "$UBI_AT" "$ROOTFS"

echo
echo "flash-nand: fatto. Togli la SD, spegni e riaccendi la board."
```

```bash
chmod +x docs/flash-nand.sh
```

- [ ] **Step 3: verificare i controlli senza board**

Run: `./docs/flash-nand.sh /nonexistent; echo rc=$?`
Expected: `flash-nand: xfel non trovato nel PATH` se xfel manca, altrimenti `flash-nand: manca /nonexistent/u-boot-sunxi-with-spl.bin …`; `rc=1`; nessun comando `xfel spinand erase` eseguito.

Run, con la board **scollegata**: `./docs/flash-nand.sh; echo rc=$?`
Expected: `flash-nand: nessuna board in FEL: …` oppure `flash inattesa: …`; `rc=1`.

Run: `bash -n docs/flash-nand.sh && shellcheck -S warning docs/flash-nand.sh`
Expected: nessun output.

- [ ] **Step 4: commit**

```bash
git add docs/flash-nand.sh
git commit -m "docs: flash-nand.sh per scrivere la SPI NAND via xfel

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: documentazione

**Files:**
- Modify: `docs/BOARD-FACTS.md`, `docs/SCELTE-DI-PROGETTO.md`, `CLAUDE.md`, `external/board/ftvogue-f1c200s/readme.txt`

- [ ] **Step 1: `docs/BOARD-FACTS.md`**

- Tabella "Identità", riga Flash:
  `| Flash | **1 Gbit SPI NAND** su \`spi0\`: GigaDevice **GD5F1GQ4xAYIG** (letto con \`xfel spinand\`), pagina 2048 B, blocco 128 KiB |`
- Trappola 2, sostituire il paragrafo "Conseguenza" con:
  "**Conseguenza: con U-Boot mainline questa board boota solo da SD.** Questo repo porta le patch SPL della serie di Icenowy Zheng (2022, mai integrata) in `external/board/ftvogue-f1c200s/patches/uboot/`. Anche su suniv `suniv_get_boot_source()` va patchata, perché per la NAND restituisce `SUNXI_INVALID_BOOT_SOURCE`. L'SPL patchato legge U-Boot a offset fisso **senza saltare i bad block**."
- Nuova sezione `## Layout SPI NAND`, prima di "Aperti", con il blocco di layout della spec e la frase: "Su suniv U-Boot proper non conosce la sorgente di boot (header SPL in SRAM sovrascritto dai vettori): la scelta SD/NAND nel `bootcmd` si basa su `test -e mmc 0:1 zImage`."
- "Catena di boot": aggiungere sotto la BROM il ramo "oppure SPI NAND: SPL in formato 1 KiB/pagina nel blocco 0", e sostituire `CONFIG_BOOTCOMMAND:` / `CONFIG_BOOTARGS` con i due rami del nuovo `bootcmd`.
- "Aperti": rimuovere "Rootfs in NAND con U-Boot da SD" e "Identità esatta del chip NAND". Sostituire "Boot da SPI NAND" con:
  "**Boot da SPI NAND: non ancora verificato su hardware.** Da confermare: (1) il porting delle patch funziona sul silicio; (2) il nome MTD nel kernel è `spi0.0`; (3) la BROM usa la seconda copia SPL nel blocco 1 se il blocco 0 è illeggibile."

- [ ] **Step 2: `docs/SCELTE-DI-PROGETTO.md`**

Nuova sezione in coda, `## Boot da SPI NAND con patch SPL invece di un fork`, con tre paragrafi:
1. Patch contro fork: `jookia_main` è su v2025.04, conta 142 commit e l'hanno testato solo su T113. Cinque patch che conosciamo riga per riga costano meno di un fork che non controlliamo. awboot è scartato perché si perde U-Boot come ambiente di recovery.
2. Directory patch senza versione: con `uboot/2026.07/`, un bump farebbe saltare le patch in silenzio. Senza versione, la build fallisce al passo di patch. `make check` controlla `spi_load_read_nand` nella map dell'SPL.
3. Selezione con `test -e` ed environment `nowhere`: U-Boot proper su suniv non conosce la sorgente di boot, quindi ci si appoggia alla priorità della BROM. È una selezione, non un fallback, coerente con la sezione "`bootcmd` esplicito".

- [ ] **Step 3: `CLAUDE.md`**

- Struttura: aggiungere `patches/uboot/  patch SPL SPI NAND (serie Icenowy, portata)` sotto `board/ftvogue-f1c200s/`, e `flash-nand.sh  scrive la SPI NAND via xfel` sotto `docs/`.
- Comandi: `./docs/flash-nand.sh                # board in FEL: scrive SPL, U-Boot e rootfs.ubi in NAND`.
- Trappola 2: "**L'SPL mainline non legge la SPI NAND.** Lo fanno le nostre patch in `patches/uboot/`: se un bump di U-Boot le rompe, va rifatto il porting, non tolte le patch."
- "Dove si cambia cosa", righe nuove:
  - `| Cambiare il layout NAND | \`CONFIG_SYS_SPI_U_BOOT_OFFS\` e \`CONFIG_MTDPARTS_DEFAULT\` (uboot.fragment), \`mtdparts=\` nel bootcmd, \`docs/flash-nand.sh\`, sezione 9 di \`check-image.sh\` | \`make uboot-reconfigure && make\` |`
  - `| Toccare le patch SPL | \`board/ftvogue-f1c200s/patches/uboot/\` | \`make uboot-dirclean && make\` |`
- "Sintomi → causa", righe nuove:
  - `| Senza SD: \`U-Boot SPL\` poi \`Trying to boot from FEL\` | patch 0005 non applicata (boot source NAND non mappata) |`
  - `| Senza SD: SPL parte ma non trova U-Boot | \`.bin\` non scritto a 0x40000 (\`splwrite\` con indirizzo 0 scarta tutto tranne l'SPL) |`
  - `| \`ubi part ubi\` fallisce / attach UBI fallisce | flash non cancellata per intero, o geometria UBI errata (sezione 10 di check) |`
  - `| \`boot: SD\` senza SD avviabile | SD non avviabile ma con la nostra FAT inserita |`
- Riga "Kernel e kernel-headers": invariata.

- [ ] **Step 4: `readme.txt`**

- Titolo: `FTVOGUE F1C200S (Lctech Pi F1C200s) — boot da SD card o da SPI NAND`.
- Aggiungere `patches/uboot/     patch SPL per leggere la SPI NAND` all'elenco.
- Dopo il `dd`, nuova sezione:

```
Boot da SPI NAND (la SD non serve piu'; se inserita e avviabile vince lei):

  ./docs/flash-nand.sh

La board deve essere in FEL (NAND vuota e nessuna SD, oppure `mtd erase
boot` dal prompt di U-Boot e reset). Verifica sulla seriale, senza SD:
"U-Boot SPL" -> "boot: NAND" -> login; `mount` deve mostrare ubi0:rootfs
su /.
```

- [ ] **Step 5: verificare i link e i controlli**

Run: il ciclo di link della CI:

```bash
rc=0; for f in README.md CLAUDE.md docs/*.md; do dir="$(dirname "$f")"; for l in $(grep -ohE '\]\([^)#]+(#[^)]*)?\)' "$f" | sed 's/^](//; s/)$//; s/#.*//'); do case "$l" in http*|"") continue;; ../../*) continue;; esac; [ -e "$dir/$l" ] || { echo "morto: $f -> $l"; rc=1; }; done; done; echo rc=$rc
```

Expected: `rc=0`.

- [ ] **Step 6: commit**

```bash
git add docs/BOARD-FACTS.md docs/SCELTE-DI-PROGETTO.md CLAUDE.md external/board/ftvogue-f1c200s/readme.txt
git commit -m "docs: boot da SPI NAND

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: verifica sulla board (manuale, la fa Walter)

Senza hardware non si può automatizzare: sono i criteri di successo della spec.

- [ ] **Step 1: flashing.** Board in FEL, `./docs/flash-nand.sh`. Expected: `Found spi nand flash 'GD5F1GQ4xAYIG' with 134217728 bytes`, tre comandi senza errori, `flash-nand: fatto.`
- [ ] **Step 2: boot da NAND.** Senza SD, seriale UART1 115200, accensione. Expected: `U-Boot SPL …`, poi `U-Boot 2026.07`, `boot: NAND`, `ubi0: attached mtd1`, kernel, login. `mount` → `ubi0:rootfs on / type ubifs`. `cat /proc/mtd` → mostra `spi0.0` come nome del device (conferma del punto aperto 2).
- [ ] **Step 3: persistenza.** `echo ok > /root/persist && sync`, poi spegnimento, riaccensione e `cat /root/persist` → `ok`.
- [ ] **Step 4: boot da SD.** Con `sdcard.img` su SD inserita: `boot: SD`, e `mount` → `/dev/mmcblk0p2 on /`.
- [ ] **Step 5: registrare l'esito.** In `docs/BOARD-FACTS.md`, "Aperti": i punti confermati si tolgono e diventano fatti, con la fonte "prova su board, data". Se `/proc/mtd` mostra un nome diverso da `spi0.0`, correggere `mtdparts=` nel `bootcmd` (Task 2) e ripetere dal Task 2 Step 3. Commit `docs: boot da SPI NAND verificato su board`.

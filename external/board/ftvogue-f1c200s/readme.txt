FTVOGUE F1C200S (Lctech Pi F1C200s) — boot da SD card o da SPI NAND
====================================================================

Questa directory contiene i file di board per Buildroot: frammenti di
configurazione per kernel e U-Boot, e il layout dell'immagine SD.

  linux.fragment   opzioni kernel applicate sopra sunxi_defconfig
  uboot.fragment   opzioni U-Boot applicate sopra lctech_pi_f1c200s_defconfig
  genimage.cfg     layout dell'immagine SD
  patches/uboot/   patch SPL per leggere la SPI NAND

Non si usa direttamente: si passa dal wrapper nella radice del repository.

  ./setup.sh
  make ftvogue_f1c200s_defconfig
  make
  make check

L'immagine da scrivere sulla SD e' output/images/sdcard.img.

  sudo dd if=output/images/sdcard.img of=/dev/sdX bs=1M conv=fsync status=progress

Boot da SPI NAND (la SD non serve piu'; se inserita e avviabile vince lei):

  ./docs/flash-nand.sh

La board deve essere in FEL (NAND vuota e nessuna SD, oppure `mtd erase
boot` dal prompt di U-Boot e reset). Verifica sulla seriale, senza SD:
"U-Boot SPL" -> "boot: NAND" -> login; `mount` deve mostrare ubi0:rootfs
su /.

Console seriale: UART1, pin PA2 (TX) / PA3 (RX), 115200 8N1 -> ttyS0.
Login: root, senza password.

I fatti sull'hardware e le trappole di questa board (la flash e' SPI NAND non
NOR; la console e' UART1 non UART0; il kernel va forzato su ARMv5) stanno in
docs/BOARD-FACTS.md nella radice del repository.

#!/bin/bash
# flash-workflow.sh - dump, extract, patch and reflash a Geeni/Merkury camera
# Run on Linux with: flashrom, binwalk, mtdram/mtdblock modules
#
# ⚠️ The ch341a MUST be 3.3V-safe. The stock black ch341a drives 5V and can
#    damage your flash chip. Verify before connecting.

set -e
IMG="${1:-flash.bin}"

echo "=== 1. READ FLASH ==="
flashrom -p ch341a_spi -r "$IMG"
echo "Backup saved as $IMG - KEEP THIS, it is your recovery image."

echo
echo "=== 2. ANALYSE LAYOUT ==="
binwalk -e -M "$IMG"
echo
echo "Look for the JFFS2 filesystem (the app partition)."
echo "Expected layout on this hardware family:"
echo "  192k(bld) 64k(env) 64k(enc) 64k(sysflg) <sys>(sys) <app>(app) <cfg>(cfg)"
echo "The offset differs per model - DERIVE IT FROM BINWALK, do not copy others."

echo
echo "=== 3. MOUNT & PATCH (edit ME) ==="
cat <<'EOF'
  sudo modprobe mtdram total_size=8192 erase_size=256
  sudo modprobe mtdblock
  sudo dd if=<extracted>.jffs2 of=/dev/mtdblock2
  sudo mount -t jffs2 /dev/mtdblock2 /mnt/app
  sudo cp S70custom /mnt/app/etc/init.d/S70custom
  sudo chmod +x /mnt/app/etc/init.d/S70custom
  sudo umount /mnt/app
  sudo dd if=/dev/mtdblock2 of=<extracted>.jffs2 bs=1 count=<size>
EOF

echo
echo "=== 4. REBUILD IMAGE ==="
cat <<'EOF'
  cp flash.bin flash-custom.bin
  dd conv=notrunc if=<extracted>.jffs2 of=flash-custom.bin bs=1 seek=$((0x<OFFSET>))
EOF

echo
echo "=== 5. WRITE BACK ==="
cat <<'EOF'
  flashrom -p ch341a_spi -w flash-custom.bin
  # then reinstall the chip and boot with the SD card containing mmc/ files
EOF
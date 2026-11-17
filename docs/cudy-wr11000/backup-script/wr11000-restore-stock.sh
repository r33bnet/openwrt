#!/bin/sh
# Put the stock Cudy firmware back on a WR11000 from the backup made with
# wr11000-backup.sh. Run next to the "wr11000-backup" folder, with the
# router RAM-booted (TFTP initramfs) - NOT booted from NAND.
#
# Only "rootfs" is written (the only partition sysupgrade changed). The
# image is streamed into "mtd write -", so nothing is stored in the
# router's RAM, then read back and compared by md5.
set -eu
R=root@192.168.1.1
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
IMG=wr11000-backup/rootfs.bin

[ -f "$IMG" ] || { echo "$IMG not found"; exit 1; }
want=$(md5sum "$IMG" | cut -d' ' -f1)
size=$(wc -c < "$IMG")
echo "Backup image: $IMG ($size bytes, md5 $want)"

if ssh -n $O $R cat /proc/mounts | grep -qE ' (squashfs|ubifs) '; then
	echo "Router seems to be running from NAND. TFTP-boot the initramfs first."; exit 1
fi

line=$(ssh -n $O $R cat /proc/mtd | grep '"rootfs"$')
dev=${line%%:*}
psize=$((0x$(echo "$line" | awk '{print $2}')))
[ "$psize" -eq "$size" ] || { echo "Size mismatch: $dev is $psize, backup is $size"; exit 1; }
echo "Target: /dev/$dev ($psize bytes)"

ssh -n $O $R "ubidetach -p /dev/$dev" >/dev/null 2>&1 || true
echo "Writing - this takes a few minutes..."
ssh $O $R "mtd write - rootfs" < "$IMG"

have=$(ssh -n $O $R "md5sum /dev/$dev" | cut -d' ' -f1)
if [ "$have" = "$want" ]; then
	echo "VERIFIED: /dev/$dev matches the backup. Power-cycle the router to boot stock."
else
	echo "MISMATCH: router $have, backup $want. Do NOT reboot - run this script again."
fi

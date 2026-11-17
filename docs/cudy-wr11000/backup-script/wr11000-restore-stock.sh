#!/bin/sh
# Put the stock Cudy firmware back on a WR11000 from the backup made with
# wr11000-backup.sh. Run next to the "wr11000-backup" folder, with the
# router RAM-booted (TFTP initramfs) - NOT booted from NAND.
#
# Only "rootfs" is written (the only partition sysupgrade changed). The
# image is streamed into ubiformat, so nothing is stored in the router's
# RAM, then UBI is attached once to prove it reads back cleanly.
#
# Not "mtd write": that programs the empty (0xFF) pages of the dump too.
# They then look erased but carry ECC, and the next time UBI writes into
# one the page is programmed twice and fails ECC. That is how a restore
# once corrupted both UBI volume tables and left the slot unbootable for
# stock U-Boot, stock firmware and OpenWrt alike. ubiformat erases every
# block and skips the empty pages at the end of each one.
set -eu
R=root@192.168.1.1
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
IMG=wr11000-backup/rootfs.bin
UBINUM=9

[ -f "$IMG" ] || { echo "$IMG not found"; exit 1; }
[ "$(head -c 4 "$IMG")" = "UBI#" ] || { echo "$IMG does not start with a UBI header"; exit 1; }
size=$(wc -c < "$IMG")
echo "Backup image: $IMG ($size bytes)"

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
ssh $O $R "ubiformat /dev/$dev -y -S $size -f -" < "$IMG"

# ubiformat rewrites every EC header (erase counters, image sequence), so
# the raw bytes no longer equal the backup and an md5 of /dev/$dev cannot
# match. Check instead that UBI attaches without a single ECC error and
# that the stock volumes are there.
ssh -n $O $R "dmesg -c" >/dev/null
if ! ssh -n $O $R "ubiattach -p /dev/$dev -d $UBINUM" >/dev/null; then
	echo "FAILED: UBI on /dev/$dev does not attach. Do NOT reboot - run this script again."; exit 1
fi
vols=$(ssh -n $O $R "ubinfo -d $UBINUM -a" | sed -n 's/^Name: *//p' | tr '\n' ' ')
ecc=$(ssh -n $O $R "dmesg | grep -c 'ECC error'" || true)
ssh -n $O $R "ubidetach -d $UBINUM" >/dev/null 2>&1 || true
echo "Volumes: $vols"

case " $vols " in
*" ubi_rootfs "*) ;;
*) echo "FAILED: no ubi_rootfs volume. Do NOT reboot - run this script again."; exit 1 ;;
esac
if [ "${ecc:-0}" -ne 0 ]; then
	echo "FAILED: $ecc ECC errors while attaching. Do NOT reboot - run this script again."; exit 1
fi
echo "VERIFIED: /dev/$dev attaches cleanly with the stock volumes. Power-cycle the router to boot stock."

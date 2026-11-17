#!/bin/sh
# Pull every NAND partition from a RAM-booted WR11000 over SSH and verify it.
set -u
R=root@192.168.1.1
# A RAM boot makes a new host key every time; do not check or record it.
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
mkdir -p wr11000-backup && cd wr11000-backup
ssh $O $R wifi down                       # frees a little RAM, stops log noise
ssh $O $R cat /proc/mtd > proc_mtd.txt
# /proc/mtd lines look like:  mtd17: 00100000 00020000 "0:art"
grep '^mtd' proc_mtd.txt | while read -r dev size erase name; do
	dev=${dev%:}
	name=$(echo "$name" | tr -d '"' | tr ':' '_')
	ssh -n $O $R "cat /dev/$dev" > "$name.bin"
	want=$(ssh -n $O $R "md5sum /dev/$dev" | cut -d' ' -f1)
	have=$(md5sum "$name.bin" | cut -d' ' -f1)
	bytes=$(wc -c < "$name.bin")
	if [ "$want" = "$have" ] && [ "$bytes" -eq $((0x$size)) ]; then
		echo "OK        $dev $name.bin ($bytes bytes)"
	else
		echo "MISMATCH  $dev $name.bin ($bytes bytes, want $((0x$size)))"
	fi
done

# Put the stock Cudy firmware back on a WR11000 from the backup made with
# wr11000-backup.ps1. Run it next to the "wr11000-backup" folder, with the
# router RAM-booted (TFTP initramfs) - NOT booted from NAND.
#
#   powershell -ExecutionPolicy Bypass -File .\wr11000-restore-stock.ps1
#
# Only the "rootfs" partition is written: that is the only one sysupgrade
# changed. The image is streamed over SSH into "mtd write -", so nothing
# is stored in the router's RAM, then read back and compared by md5.

$R      = "root@192.168.1.1"
$SshOpt = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR"
$Image  = "wr11000-backup\rootfs.bin"

if (-not (Test-Path $Image)) { throw "$Image not found - run this next to the backup folder" }
$want = (Get-FileHash -Algorithm MD5 -Path $Image).Hash.ToLower()
$size = (Get-Item $Image).Length
"Backup image: $Image ($size bytes, md5 $want)"

# Must be the RAM-booted system: refuse if / is on UBI/squashfs from NAND.
$root = cmd /c "ssh -n $SshOpt $R cat /proc/mounts"
if ($root -match ' (squashfs|ubifs) ') { throw "Router seems to be running from NAND. TFTP-boot the initramfs first." }

# Find the partition and make sure its size matches the backup.
$line = (cmd /c "ssh -n $SshOpt $R cat /proc/mtd") | Where-Object { $_ -match '"rootfs"$' }
if (-not ($line -match '^(mtd\d+):\s+([0-9a-fA-F]+)')) { throw "No rootfs partition found in /proc/mtd" }
$dev = $Matches[1]; $psize = [Convert]::ToInt64($Matches[2], 16)
if ($psize -ne $size) { throw "Size mismatch: $dev is $psize bytes, backup is $size" }
"Target: /dev/$dev ($psize bytes)"

# Detach UBI if anything attached it, then write. cmd.exe does the
# redirection so the bytes reach ssh unchanged.
cmd /c "ssh -n $SshOpt $R ubidetach -p /dev/$dev" 2>$null | Out-Null
"Writing - this takes a few minutes..."
cmd /c "ssh $SshOpt $R mtd write - rootfs < $Image"

$have = ((cmd /c "ssh -n $SshOpt $R md5sum /dev/$dev") -split '\s+')[0]
if ($have -eq $want) {
	"VERIFIED: /dev/$dev matches the backup. Power-cycle the router to boot stock."
} else {
	"MISMATCH: router $have, backup $want. Do NOT reboot - run this script again."
}

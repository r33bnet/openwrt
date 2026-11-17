# Put the stock Cudy firmware back on a WR11000 from the backup made with
# wr11000-backup.ps1. Run it next to the "wr11000-backup" folder, with the
# router RAM-booted (TFTP initramfs) - NOT booted from NAND.
#
#   powershell -ExecutionPolicy Bypass -File .\wr11000-restore-stock.ps1
#
# Only the "rootfs" partition is written: that is the only one sysupgrade
# changed. The image is streamed over SSH into ubiformat, so nothing is
# stored in the router's RAM, then UBI is attached once to prove it reads
# back cleanly.
#
# Not "mtd write": that programs the empty (0xFF) pages of the dump too.
# They then look erased but carry ECC, and the next time UBI writes into
# one the page is programmed twice and fails ECC. That is how a restore
# once corrupted both UBI volume tables and left the slot unbootable for
# stock U-Boot, stock firmware and OpenWrt alike. ubiformat erases every
# block and skips the empty pages at the end of each one.

$R      = "root@192.168.1.1"
$SshOpt = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR"
$Image  = "wr11000-backup\rootfs.bin"
$UbiNum = 9

if (-not (Test-Path $Image)) { throw "$Image not found - run this next to the backup folder" }
$fs = [System.IO.File]::OpenRead((Resolve-Path $Image))
$magic = New-Object byte[] 4; [void]$fs.Read($magic, 0, 4); $fs.Close()
if ([System.Text.Encoding]::ASCII.GetString($magic) -ne "UBI#") { throw "$Image does not start with a UBI header" }
$size = (Get-Item $Image).Length
"Backup image: $Image ($size bytes)"

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
cmd /c "ssh $SshOpt $R ubiformat /dev/$dev -y -S $size -f - < $Image"

# ubiformat rewrites every EC header (erase counters, image sequence), so
# the raw bytes no longer equal the backup and an md5 of /dev/$dev cannot
# match. Check instead that UBI attaches without a single ECC error and
# that the stock volumes are there.
cmd /c "ssh -n $SshOpt $R dmesg -c" | Out-Null
cmd /c "ssh -n $SshOpt $R ubiattach -p /dev/$dev -d $UbiNum" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "FAILED: UBI on /dev/$dev does not attach. Do NOT reboot - run this script again." }
$vols = (cmd /c "ssh -n $SshOpt $R ubinfo -d $UbiNum -a") |
	Where-Object { $_ -match '^Name:\s+(\S+)' } | ForEach-Object { ($_ -split '\s+')[1] }
$ecc = [int]((cmd /c "ssh -n $SshOpt $R `"dmesg | grep -c 'ECC error'`"") | Select-Object -First 1)
cmd /c "ssh -n $SshOpt $R ubidetach -d $UbiNum" 2>$null | Out-Null
"Volumes: $($vols -join ' ')"

if ($vols -notcontains "ubi_rootfs") { throw "FAILED: no ubi_rootfs volume. Do NOT reboot - run this script again." }
if ($ecc -ne 0) { throw "FAILED: $ecc ECC errors while attaching. Do NOT reboot - run this script again." }
"VERIFIED: /dev/$dev attaches cleanly with the stock volumes. Power-cycle the router to boot stock."

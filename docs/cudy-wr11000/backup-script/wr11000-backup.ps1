# Pull every NAND partition from a RAM-booted Cudy WR11000 over SSH and
# verify each one. Windows 10/11 PowerShell 5.1 or 7, using the built-in
# OpenSSH client (ssh.exe).
#
#   powershell -ExecutionPolicy Bypass -File .\wr11000-backup.ps1
#
# Nothing is stored on the router: each partition is streamed straight
# into a file here, then streamed again to compute its md5 on the router.

$R = "root@192.168.1.1"
# A RAM boot makes a new host key every time; do not check or record it.
$SshOpt = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR"

New-Item -ItemType Directory -Force -Path "wr11000-backup" | Out-Null
Set-Location "wr11000-backup"

# Text output is fine through PowerShell.
cmd /c "ssh $SshOpt $R wifi down"
$mtd = cmd /c "ssh -n $SshOpt $R cat /proc/mtd"
$mtd | Set-Content -Encoding ascii "proc_mtd.txt"

$bad = 0
foreach ($line in $mtd) {
	# mtd17: 00100000 00020000 "0:art"
	if ($line -notmatch '^(mtd\d+):\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+"(.*)"$') { continue }
	$dev  = $Matches[1]
	$size = [Convert]::ToInt64($Matches[2], 16)
	$file = ($Matches[3] -replace ':', '_') + ".bin"

	# Binary data must not pass through PowerShell's pipeline or ">":
	# let cmd.exe do the redirection, it writes the bytes unchanged.
	cmd /c "ssh -n $SshOpt $R cat /dev/$dev > $file"

	$want  = ((cmd /c "ssh -n $SshOpt $R md5sum /dev/$dev") -split '\s+')[0]
	$have  = (Get-FileHash -Algorithm MD5 -Path $file).Hash.ToLower()
	$bytes = (Get-Item $file).Length

	if ($want -eq $have -and $bytes -eq $size) {
		"OK        {0,-6} {1} ({2} bytes)" -f $dev, $file, $bytes
	} else {
		"MISMATCH  {0,-6} {1} ({2} bytes, want {3})" -f $dev, $file, $bytes, $size
		$bad++
	}
}

if ($bad -eq 0) { "All partitions verified." } else { "$bad partition(s) failed - run the script again." }

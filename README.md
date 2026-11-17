# Cudy WR11000 — mainline OpenWrt port (bring-up)

Target `qualcommbe/ipq53xx`, kernel 6.18, profile **Cudy WR11000**
(`cudy_wr11000`, DT compatible `cudy,wr11000`).

> [!WARNING]
> Tested on one unit (see Status), built from Cudy's GPL release (QSDK 12.5 /
> OpenWrt 21.02, board "R65"), the stock v2.5.234 UART logs in this folder,
> and the GL-BE9300/BE6500 ports in this tree. Use a serial console and back
> up the whole NAND (above all `0:ART`) before writing anything.

**Tree base.** Branch `cudy-wr11000` is OpenWrt main of 2026-11-16
(`393efd7d74`, Linux 6.18.60, backports 7.2, hostapd 2.12) plus commits
for the qualcommbe/ipq53xx + GL-BE9300 work rebased from the flint3-be9300
tree, this port, and the fixes the new base needed. What was
dropped because main already has it, and what still needs porting, is
listed in those commit messages. On this base (2026-11-16): builds, TFTP
boot, NAND install and a cold NAND boot work, with the switch and both Wi-Fi
chips up (after patch 0467, open item 11). Other results below were first
obtained on Linux 6.18.39.

## Hardware

| Block | Detail | Source |
|---|---|---|
| SoC | Qualcomm **IPQ5322** (IPQ5332 family), 4× Cortex-A53 | boot log `CPU: IPQ5322` |
| RAM | 512 MiB DDR4 | U-Boot `DRAM: 512 MiB` |
| Flash | 128 MiB SPI-NAND, GigaDevice GD5F1GM7REYIG, on QPIC | U-Boot / kernel log |
| Reference design | AP-MI01.6, machid `0x8060000`, Cudy board "R65" | `model = .../AP-MI01.6/R65` |
| Wi-Fi 2.4 GHz | on-SoC, ath12k AHB, board-id `0x16` | vendor DT `&wifi0` |
| Wi-Fi 5 + 6 GHz | 1× QCN9224 dual-MAC on PCIe1, board-id `0x1019` | boot log `amss_dualmac.bin` |
| Switch | **QCA8386** ("Manhattan"), 4× 2.5G PHY at MDIO 1–4, reset GPIO 51 | vendor DT, ssdk log |
| Ports | switch port 1 = WAN, ports 2–4 = LAN | vendor `board.d/01_network` |
| LEDs | internet green 32 / red 33, WPS 34, Wi-Fi 36, status 37 | vendor DT |
| Buttons | reset GPIO 30, WPS GPIO 35 (active low) | vendor DT |

### NAND layout (SMEM partition table)

| Offset | Name | Size | Content |
|---|---|---|---|
| 0x0000000–0x0a80000 | SBL1, MIBIB, BOOTCONFIG, QSEE, DEVCFG, TME, CDT (+ `_1` copies) | | boot chain |
| 0x0a80000 | 0:APPSBLENV | 1 MiB | U-Boot env (size 0x40000) |
| 0x0b80000 | 0:APPSBL / 0:APPSBL_1 | 1.5 MiB each | U-Boot |
| 0x0f00000 | **0:ART** | 1 MiB | radio calibration, unique per unit |
| 0x1000000 | **bdinfo** | 256 KiB | base MAC, 6 bytes at `0xde00` |
| 0x1040000 | **rootfs** | 52 MiB | UBI: `kernel`, `ubi_rootfs`, `rootfs_data` |
| 0x4460000 | rootfs_1 | 52 MiB | the other firmware slot |
| 0x7880000 | rundata, debug, backup | 1 MiB each | Cudy config |

The SBL swaps the names `rootfs` and `rootfs_1` when it boots the second
slot, so `rootfs` is always the slot U-Boot is about to boot. OpenWrt only
ever writes `rootfs`, as the stock firmware's own `ubi.mtd=rootfs` does.

## What this port does, and why

**Ethernet — QCA8386 through DSA.** No existing device in this tree has this
switch, and mainline has no driver for it. The driver comes from the Linksys
SPNMX57 port (IPQ5018 + QCA8386,
[louij2/linksys-spnmx57-openwrt](https://github.com/louij2/linksys-spnmx57-openwrt)
@ `60746fd9b347`, OpenWrt PR #25902), where it works on hardware. It lives in
`target/linux/qualcommbe/files/drivers/net/dsa/qca/qca8386.c`, with:

- `0460` — Kconfig/Makefile hook (`CONFIG_NET_DSA_QCA8386`, enabled for ipq53xx)
- `0461`, `0462` — qca808x fixes for the PHY package in switch mode: UNIPHY1
  SerDes bring-up and switch-core memory hand-over. They apply on this tree's
  QCA8084 series 0301–0312, which is byte-identical to the series that port
  used.
- `0463` — marks the QCA8084 package bus clocks (AHB, MDIO, APB, switch core,
  ...) `CLK_IS_CRITICAL`. The switch waits for `qcom-ppe`, a module, so
  `clk_disable_unused()` used to gate them first; the switch then read ID
  `0xbe` and its driver gave up (first boot, 2026-11-16).

The switch's own clock controller (`qcom,qca8084-nsscc`) takes its 50 MHz XO
from the SoC CMN PLL (`IPQ5332_ETH_50MHZ_CLK`). It owns the package reset on
GPIO 51.

**One uplink instead of two.** Stock firmware links switch port 0 to PPE port
1 (LAN) *and* switch port 5 to PPE port 2 (WAN), each at 2.5G SGMII+. The DSA
driver only knows one CPU port so far. So here, WAN is an ordinary DSA user
port and LAN and WAN share the PPE port 1 ↔ switch port 0 link (`eth0`, the
conduit). PPE port 2 / `pcs1` stay off. This caps combined WAN+LAN traffic at
2.5 Gbit/s per direction.

**Boot path — 32-bit U-Boot, 64-bit kernel.** Stock runs a 32-bit kernel
from a 32-bit QSDK U-Boot 2016. That U-Boot can start an arm64 kernel: it
detects the `Image` header and calls `jump_kernel64()`. Two things in the
image recipe make it work:

- `fit-arm32-uboot` labels every FIT image `arch = "arm"`. U-Boot's
  `fit_image_check_arch()` rejects `"arm64"` outright.
- `KERNEL_LOADADDR := 0x42000000`. U-Boot loads the FIT to its fixed
  `0x41000000`, so decompressing to the target default `0x41000000` would
  overwrite the FIT mid-boot.

The FIT config is `config@mi01.6`, which is the name stock U-Boot asks for.
U-Boot reads the UBI volume `kernel` from `rootfs`. OpenWrt's `UbiFit` layout
names the squashfs volume `rootfs` (not `ubi_rootfs`), so the DTS appends
`root=/dev/ubiblock0_1`.

**Memory.** Uses the vendor 512 MiB profile: Q6 35 MiB at `0x4a900000`, then
m3-dump, ETR, caldb, MLO at `0x4db00000`, and no `tzapp`. The QCN9224 host
region uses the 50 MiB the GL ports run with. The vendor gives it 37 MiB; try
`0x02500000` if RAM is tight. ramoops sits in the gap at `0x4da00000`, so a
crash log survives a reboot.

**Wi-Fi.**

- `ipq-wifi-cudy_wr11000` holds `board-2.bin` containers keyed
  `bus=ahb,…,qmi-board-id=22` and `bus=pci,…,qmi-board-id=4121`. The BDFs are
  Cudy's own, from the stock firmware rootfs
  (`/lib/firmware/IPQ5332/WIFI_FW/bdwlan.b16` and `…/qcn9224/bdwlan.b1019`).
  The regdb is Cudy's too (`…/WIFI_FW/regdb.bin`). With it the firmware starts
  on `US` (country 840, domain 0x16, FCC DFS) and accepts country changes with
  status PASS; DFS works (5 GHz ch 116 at 160 MHz, tested 2026-11-16).
- Calibration comes from `0:ART`: `0x1000` for the IPQ5332, and
  `0x58800`/`0x27800` for the QCN9224. These offsets are from the vendor
  `ftm.conf` (`ap-mi01.6,1019,2,362496,…`) and match the GL-BE9300.

**MAC addresses.** `bdinfo` `0xde00` is the base. It goes to the conduit
through nvmem; LAN uses the base and WAN uses base + 1 (`board.d/02_network`).

## Building

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # Qualcomm Atheros 802.11be → ipq53xx → Cudy WR11000
make -j$(nproc)
```

Output in `bin/targets/qualcommbe/ipq53xx/`:

- `…-cudy_wr11000-initramfs-uImage.itb` — RAM boot, writes nothing
- `…-cudy_wr11000-squashfs-sysupgrade.bin` — install from the initramfs
- `…-cudy_wr11000-squashfs-factory.ubi` — raw UBI image of the `rootfs` slot

## First boot (RAM only, nothing written)

UART is 115200 8N1. Type 'csp' during the 1s autoboot window:

```
setenv ipaddr 192.168.1.1
setenv serverip 192.168.1.2
tftpboot 0x50000000 openwrt-qualcommbe-ipq53xx-cudy_wr11000-initramfs-uImage.itb
bootm 0x50000000
```

Load to `0x50000000`, not the usual `0x44000000`. The kernel decompresses to
`0x42000000` and an initramfs kernel runs past `0x44000000`. Everything from
`0x4a100000` to `0x4a900000` is U-Boot/TZ/SMEM and must not be touched. Stock
U-Boot's own defaults are `192.168.1.119` / `192.168.1.88`. U-Boot's TFTP
works through the port the build calls `wan` (switch port 1; first-boot log).

Stock U-Boot unpacks at most `CONFIG_SYS_BOOTM_LEN` = 64 MiB. With Wi-Fi the
initramfs must be compressed: *Target Images → ramdisk → Compression → zstd*
(the default for this profile in a fresh `.config`). With `none` the unpacked
kernel no longer fits and U-Boot refuses it.

## Back up before installing

Boot the initramfs (nothing on NAND has changed yet), then pull every
partition from a Linux/macOS shell on the PC. Do **not** copy partitions to
`/tmp` on the router: that is RAM, the NAND is 128 MiB, and the router runs
out of memory and reboots. Streaming over SSH keeps nothing on the router.

```sh
R=root@192.168.1.1
mkdir -p wr11000-backup && cd wr11000-backup
ssh $R wifi down                       # frees a little RAM, stops log noise
ssh $R cat /proc/mtd > proc_mtd.txt
# /proc/mtd lines look like:  mtd17: 00100000 00020000 "0:art"
grep '^mtd' proc_mtd.txt | while read -r dev size erase name; do
	dev=${dev%:}
	name=$(echo "$name" | tr -d '"' | tr ':' '_')
	ssh -n $R "cat /dev/$dev" > "$name.bin"
	want=$(ssh -n $R "md5sum /dev/$dev" | cut -d' ' -f1)
	have=$(md5sum "$name.bin" | cut -d' ' -f1)
	bytes=$(wc -c < "$name.bin")
	if [ "$want" = "$have" ] && [ "$bytes" -eq $((0x$size)) ]; then
		echo "OK        $dev $name.bin ($bytes bytes)"
	else
		echo "MISMATCH  $dev $name.bin ($bytes bytes, want $((0x$size)))"
	fi
done
```

Every line must say `OK`. Re-run the loop if one does not (a flaky link can
truncate a stream). Keep `0_art.bin` and `bdinfo.bin` safe forever — they
cannot be recreated.

## Install

From the initramfs:

```sh
sysupgrade -n /tmp/openwrt-qualcommbe-ipq53xx-cudy_wr11000-squashfs-sysupgrade.bin
```

`platform.sh` first deletes the stock `ubi_rootfs` volume — otherwise the
52 MiB UBI is too full for `rootfs_data` — then runs the usual
`nand_do_upgrade` on `rootfs`. The other slot (`rootfs_1`) still holds stock
firmware.

**Back to stock:** only `rootfs` was changed, so write your `rootfs.bin`
backup back to it. TFTP-boot the initramfs first (the NAND system runs from
`rootfs`), and stream the image instead of copying it to `/tmp` - it is
52 MiB and `/tmp` is RAM. From the PC, next to the `wr11000-backup` folder:

```sh
ssh root@192.168.1.1 "mtd write - rootfs" < wr11000-backup/rootfs.bin
ssh root@192.168.1.1 "md5sum /dev/mtd19"     # must equal: md5sum wr11000-backup/rootfs.bin
```

`wr11000-restore-stock.sh` / `.ps1` do the same with checks (RAM boot,
partition size, md5 after writing). On Windows PowerShell use the `.ps1`:
`<` and `>` there corrupt binary data. Then power-cycle.

## Status

Tested on hardware (2026-11-16, unit with stock firmware v2.5.234):

| Subsystem | State |
|---|---|
| Build, TFTP initramfs boot | working (initramfs must be zstd, U-Boot unpacks ≤ 64 MiB) |
| NAND sysupgrade and boot from NAND | working |
| QCA8386 / DSA: WAN + 3 LAN at 1 Gbit/s, 2.5G CPU link | working, including cold boots from NAND (patches 0463, 0465, 0466) |
| Wi-Fi 2.4 / 5 / 6 GHz, MLO AP | working, 5 GHz DFS at 160 MHz, 6 GHz at 320 MHz (country US) |
| Wi-Fi MACs from bdinfo | working, same as stock |
| MLO client (STA) | associates and working |
| LEDs / buttons | not checked |
| Return to stock | procedure above, tested |
| PPE flow offload | **not expected to work**: this tree's offload patches parse the `rtl8_4` DSA tag, not QCA's 2-byte header |

## Files added or changed for this device

```
target/linux/qualcommbe/dts/ipq5332-wr11000.dts                       new
target/linux/qualcommbe/files/drivers/net/dsa/qca/qca8386.c           new (SPNMX57 port)
target/linux/qualcommbe/patches-6.18/0460-net-dsa-qca-add-qca8386-driver.patch
target/linux/qualcommbe/patches-6.18/0461-net-phy-qca808x-bring-up-UNIPHY1-SerDes-in-switch-mode.patch
target/linux/qualcommbe/patches-6.18/0462-net-phy-qca808x-configure-switch-core-memories-in-switch-mode.patch
target/linux/qualcommbe/patches-6.18/0463-clk-qcom-nsscc-qca8k-keep-package-bus-clocks-on.patch
target/linux/qualcommbe/patches-6.18/0466-net-pcs-qcom-ipq9574-provide-uniphy-50MHz-clock-out-as-a-clock.patch
target/linux/qualcommbe/patches-6.18/0465-clk-qcom-nsscc-qca8k-wait-after-releasing-reset.patch
target/linux/qualcommbe/ipq53xx/config-default                        CONFIG_NET_DSA_QCA8386=y
target/linux/generic/config-6.18                                      # CONFIG_NET_DSA_QCA8386 is not set
target/linux/qualcommbe/image/ipq53xx.mk                              Device/cudy_wr11000, Build/fit-arm32-uboot
target/linux/qualcommbe/ipq53xx/base-files/etc/board.d/01_leds
target/linux/qualcommbe/ipq53xx/base-files/etc/board.d/02_network
target/linux/qualcommbe/ipq53xx/base-files/etc/hotplug.d/firmware/12-ath12k-caldata
target/linux/qualcommbe/ipq53xx/base-files/etc/hotplug.d/ieee80211/41-cudy-wr11000-wifi-macs   new
package/kernel/mac80211/patches/ath12k/991-wifi-ath12k-track-country-sent-to-firmware.patch   new
target/linux/qualcommbe/ipq53xx/base-files/lib/upgrade/platform.sh     (BE6500 helper renamed remove_oem_ubi_rootfs)
package/boot/uboot-tools/uboot-envtools/files/qualcommbe_ipq53xx
package/firmware/ipq-wifi/Makefile, src/board-cudy_wr11000.{ipq5332,qcn9274}
docs/cudy-wr11000/                                                     this file + stock logs
```

# Cudy WR11000 — mainline OpenWrt port (bring-up)

Target `qualcommbe/ipq53xx`, kernel 6.18, profile **Cudy WR11000**
(`cudy_wr11000`, DT compatible `cudy,wr11000`).

> [!WARNING]
> **None of this has run on hardware yet.** It is a first port, put together
> from Cudy's GPL release (QSDK 12.5 / OpenWrt 21.02, board "R65"), the stock
> v2.5.234 UART logs in this folder, and the working GL-BE9300/BE6500 ports
> in this tree. Use a serial console and back up the whole NAND (above all
> `0:ART`) before writing anything.

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

UART is 115200 8N1. Press a key during the 1 s autoboot window.

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
| MLO client (STA) | associates, then floods fw-stats errors (open item 9) |
| LEDs / buttons | not checked |
| Return to stock | procedure above, not yet run |
| PPE flow offload | **not expected to work**: this tree's offload patches parse the `rtl8_4` DSA tag, not QCA's 2-byte header |

## Open items, in the order they will bite

1. **Build it.** The DTS, patches and recipe have only been checked by
   reading against the tree (patch context, binding headers, labels).
   Expect small fixes on the first `make`.
2. **Switch bring-up on IPQ5332.** On the SPNMX57 the uplink is IPQ5018
   `gmac1`. Here it is PPE port 1 via `pcs0` at `2500base-x`. If the conduit
   links but no frames cross, check, in order:
   - `pcs0` 2500BASE-X on IPQ5332 (patches 0318/0365)
   - whether the QCA8386 UNIPHY1 needs lane swaps
   - the per-port clock parents. The driver has a debugfs register knob at
     `/sys/kernel/debug/<mdio-dev>/reg`.
3. **LAN jack order.** `lan1..lan3` follow switch ports 2..4. Walk one cable
   through the jacks and relabel in the DTS if needed.
4. **Regulatory.** Works with Cudy's BDFs + regdb (US, DFS, 160 MHz).
   Root cause of the DFS failures (log 09): a fresh config gives the 6 GHz
   radio `country '00'`; the firmware applies it but answers with no rules,
   ath12k drops that event and keeps believing the boot country `US`, and
   then ignores the user's `US` as "already set" - so the firmware stays on
   `00` and refuses DFS channels (`invalid regdomain`). Patch
   `991-wifi-ath12k-track-country-sent-to-firmware.patch` compares against
   the country last sent to the firmware instead, so `US` goes out once but
   repeated identical requests (every `wifi` reload) are not resent - an
   earlier always-resend version reset DFS state and stopped a running
   5 GHz AP (log 10). Confirmed in log 11: DFS at 160 MHz survives changing
   another radio. The temporary debug patch 990 has been removed.
5. **QCN9224 power rails.** The vendor passes MHI boot-args for GPIO 52 (MX)
   and GPIO 24 (RFA1p2) to the QCN9224 firmware. Mainline ath12k has no
   equivalent; the GL-BE9300 radio works without it, but if the 5/6 GHz
   radio fails to come up, start here.
6. **Wi-Fi MACs.** Done (log 09, BSSIDs …:6d / …:6f / …:70): the DTS gives ath12k the bdinfo
   base (IPQ5332) and base + 2 (QCN9224) via patch 701, and
   `hotplug.d/ieee80211/41-cudy-wr11000-wifi-macs` sets `macaddr_base` per
   radio to match stock `99_oem`: 2.4 GHz = base, 5 GHz = base + 2,
   6 GHz = base + 3 (WAN is base + 1). Before this the firmware invented a
   new `00:03:7f:12:…` base on every boot.
7. **Second CPU port.** Teach `qca8386.c` about port 5 (UNIPHY0, MAC5
   clocks) and enable PPE port 2 / `pcs1`, so WAN gets its own 2.5G lane
   like stock.
8. **RAM in the initramfs.** Only ~368 MiB is left for Linux after the Wi-Fi
   reservations, and the initramfs keeps the whole rootfs in RAM: with all
   three radios up about 50 MiB stays available, and one initramfs test
   session ended in an out-of-memory reboot (cause not captured). An
   installed (NAND) system does not hold the rootfs in RAM. The QCN9224 host
   DDR window here is 50 MiB versus the vendor's 37 MiB and could be trimmed.
   Log 11 (an OOM during MLO client tests): of 368 MiB, ~57 MiB was the
   initramfs rootfs (shmem), ~48 MiB unreclaimable slab, ~10 MiB all
   userspace, and ~240 MiB kernel page allocations (mostly ath12k DMA for
   two chips). Both chips already run ath12k's LOW_512_M profile (PCI via
   `qcom,ath12k-fw-memory-mode`, AHB automatically). Installing to NAND
   frees the 57 MiB.
9. **MLO client (STA) mode.** Joining an MLO AP works (3 links associate)
   but the QCN9274 then floods `time out while waiting for get fw stats`,
   `failed to pull fw stats: -71` and `No VIF found for vdev 1`. The fw
   stats requests come from station statistics polls (LuCI status page,
   `iwinfo`). Not investigated; AP mode is the target.
10. **NAND boot: switch reference clock (patches 0465, 0466).** The QCA8386
    XO is the UNIPHY0 50 MHz clock-out (0x7a00610 bit 0): clearing it at
    runtime stops all switch traffic, setting it again retrains every PHY
    (measured with devmem on a TFTP boot). Stock U-Boot sets it only when it
    starts its own network, so TFTP tests worked and flash boots had dead
    ports (log 12). Writing it from the MDIO driver at early boot (former
    patch 0464, removed) made every flash boot reset with "NOC Error"
    (log 13). Now pcs0 exports the pin as clock index 2 (patch 0466) and the
    QCA8386 clock controller uses `<&pcs0 2>` as XO, so it probes after
    pcs0 and enables the pin with the UNIPHY clocks already on. 0465 waits
    100 ms after the QCA8386 reset. Untested.

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

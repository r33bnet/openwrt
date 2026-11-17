REQUIRE_IMAGE_METADATA=1
RAMFS_COPY_BIN='dumpimage fitblk fit_check_sign'

remove_oem_ubi_rootfs() {
	local mtdnum
	local ubidev
	local ubivol

	mtdnum=$(find_mtd_index "$CI_UBIPART")
	if [ -z "$mtdnum" ]; then
		echo "Unable to find UBI MTD partition $CI_UBIPART"
		return 1
	fi

	ubidev=$(nand_find_ubi "$CI_UBIPART")
	if [ -z "$ubidev" ]; then
		# A UBI that will not attach (e.g. both volume tables fail
		# ECC) has no ubi_rootfs to remove. Do not abort here:
		# nand_do_upgrade ubiformats an unattachable partition and
		# carries on, but only if it gets to run.
		ubiattach --mtdn="$mtdnum" || {
			echo "Cannot attach $CI_UBIPART, leaving it to nand_do_upgrade"
			return 0
		}
		ubidev=$(nand_find_ubi "$CI_UBIPART")
	fi

	[ -n "$ubidev" ] || return 0

	ubivol=$(nand_find_volume "$ubidev" ubi_rootfs)
	[ -z "$ubivol" ] || {
		echo "Removing legacy ubi_rootfs volume"
		ubirmvol "/dev/$ubidev" --name=ubi_rootfs || return 1
	}
}

platform_do_upgrade() {
	case "$(board_name)" in
	cudy,wr11000)
		# Stock QSDK firmware leaves an "ubi_rootfs" volume behind that
		# would eat the space nand_do_upgrade needs for rootfs_data.
		CI_UBIPART="rootfs"
		remove_oem_ubi_rootfs || return 1
		nand_do_upgrade "$1"
		;;
	gl.inet,gl-be6500)
		CI_UBIPART="rootfs"
		remove_oem_ubi_rootfs || return 1
		nand_do_upgrade "$1"
		;;
	gl.inet,gl-be9300)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		glinet_emmc_do_upgrade "$1" || exit 1
		;;
	ubnt,u7-pro-xgs)
		CI_KERNPART="kernel0"
		fit_do_upgrade "$1"
		;;
	*)
		echo "Sysupgrade is not supported on your board yet."
		return 1
		;;
	esac
}

platform_check_image() {
	[ "$#" -gt 1 ] && return 1

	case "$(board_name)" in
	cudy,wr11000|\
	gl.inet,gl-be6500)
		return 0
		;;
	gl.inet,gl-be9300)
		glinet_emmc_check_image "$1"
		;;
	ubnt,u7-pro-xgs)
		fit_check_image "$1"
		;;
	*)
		echo "Sysupgrade is not supported on your board yet."
		return 1
		;;
	esac
}

platform_copy_config() {
	case "$(board_name)" in
	gl.inet,gl-be9300|\
	ubnt,u7-pro-xgs)
		emmc_copy_config
		;;
	esac
}

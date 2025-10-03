#!/usr/bin/bash

flagfile='/var/lib/myfirstboot/expartition.done'

if [[ -f "${flagfile}" ]]; then
	resize2fs "$(findmnt -no source /)"
	systemctl disable myfirstboot.service
else
	rootfs_partition="$(findmnt -no source /)"
	rootfs_partition_number="$(echo "${rootfs_partition}" | grep -Eo '[[:digit:]]*$')"
	rootfs_device="/dev/$(lsblk -no pkname "${rootfs_partition}")"
	echo "size=+" | sfdisk -f -N "${rootfs_partition_number}" "${rootfs_device}"
	/usr/bin/install -Dm644 /dev/null ${flagfile}
	#systemctl reboot
	sync && echo b > /proc/sysrq-trigger
fi

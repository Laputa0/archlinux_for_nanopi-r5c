#!/usr/bin/bash
set -e
#set -x

#dosfstools,libarchive-tools,sgdisk

image=nanopi-r5c.img
board=rk3568-nanopi-r5c
archtarball=ArchLinuxARM-aarch64-latest.tar.gz

function cecho (){
        local color=$1
        local msg=$2
	test $# -lt 2 && exit 101

        case $color in
        red)
                echo -e "\033[31m${msg}\033[0m"
                ;;
        green)
                echo -e "\033[32m${msg}\033[0m"
                ;;
        yellow)
                echo -e "\033[33m${msg}\033[0m"
                ;;
        blue)
                echo -e "\033[33m${msg}\033[0m"
                ;;
	title)
		echo -e "\n\033[34m=====>\033[0m ${msg}"
		;;
        *)
                echo "${msg}"
                ;;
        esac
}

function build_environment_init(){
	# build on linux
	if [[ "$(uname -s)" != 'Linux' ]]; then
		cecho red "this project requires a 'Linux' system."
		exit 1
	fi

	# require arm64
	if [[ "$(uname -m)" != 'aarch64' ]]; then
		cecho red "this project requires an 'ARM64' architecture."
		exit 1
	fi

	# download archlinux tarball
	if [[ ! -f "${archtarball}" ]]; then
		curl -L -o ${archtarball} 'http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz'
	fi

	# create rootfs for mountpoint
	if [[ ! -d "rootfs" ]]; then
		mkdir rootfs
	fi
	
	# install packages
	os_id=$(cat /etc/os-release|grep '^ID='|cut -d'=' -f2)
	if [[ ${os_id} == 'debian' || ${os_id} == 'ubuntu' ]]; then
		sudo apt-get install gdisk libarchive-tools dosfstools
	fi

	# check tools
	sudo -V &>/dev/null || exit 111
	losetup -V &>/dev/null || exit 112
	sgdisk -V &>/dev/null || exit 113
	mkfs.fat --help &>/dev/null || exit 114
	mkfs.ext4 -V &>/dev/null || exit 115
	bsdtar --help &>/dev/null || exit 116

	cecho green "The current environment meets the compilation requirements."
}

function clean(){
	local loopdev=$1
	cecho title "umounting..."
	umount -v -R rootfs
	losetup -v -d ${loopdev}
}

function create_void_image(){
	local image=$1
#	if [ -f "${image}" ]; then
#		read -p "file ${image} exists, overwrite? <y/N> " yn
#		if ! [ "${yn,,}" = 'y' -o "${yn,,}" = 'yes' ]; then
#			echo 'exiting...'
#			exit 0
#		fi
#	fi
	truncate -s "4G" "${image}"
	stat --printf='image file: %n\nsize: %s bytes\n' "${image}"
}

# partition
function disk_part(){
	local image=$1
	sgdisk --zap-all ${image}
	sgdisk -n 1:16MiB:+512MiB -t 1:EF00 -c 1:"ESP" ${image}
	sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOTFS" ${image}
	sgdisk -p ${image}
}
disk_part ${image}

loopdev="$(/usr/sbin/losetup -f)"
# mapping to block
function format_part(){
	local image=$1
	local loopdev=$2
	test -f ${image} || exit 1

	# map image to block device
	sudo losetup -vP "${loopdev}" "${image}"
	cecho yellow "loop device ${loopdev} created for image file ${image}"

	# format partition
	cecho yellow "formatting ${loopdev}p1 as fat32\n"
	sudo mkfs.fat -F 32 -n ESP "${loopdev}p1"

	cecho yellow "formatted ${loopdev}p2 as ext4.\n"
	sudo mkfs.ext4 -b 4096 -F -L ROOTFS "${loopdev}p2"
}

function mount_rootfs(){
	local loopdev=$1
	local archtarball=$2

	mount -v ${loopdev}p2 rootfs
	mkdir rootfs/boot
	mount -v ${loopdev}p1 rootfs/boot
	bsdtar -xpf ${archtarball} -C rootfs

	mount -v --bind /proc rootfs/proc
	mount -v --bind /sys rootfs/sys
	mount -v --bind /dev rootfs/dev
	mount -v --bind /run rootfs/run
	mount -v --bind /dev/pts rootfs/dev/pts
}

function cus_chroot(){
	local board=$1
	cecho title "customize configure in chroot."
	chroot rootfs /usr/bin/bash -c "sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config"
	chroot rootfs /usr/bin/bash -c "sed -i 's/^#en_US.UTF-8/en_US.UTF-8/g' /etc/locale.gen && locale-gen"
	chroot rootfs /usr/bin/bash -c "systemd-firstboot --force --locale=en_US.UTF-8 --timezone=UTC --hostname=nanopi-r5c --setup-machine-id"
	chroot rootfs /usr/bin/bash -c "bootctl --esp-path=/boot install"
	install -vm644 files/${board}/hosts rootfs/etc/hosts
	install -vm644 files/${board}/fstab rootfs/etc/fstab
	install -vm600 files/${board}/loader.conf rootfs/boot/loader/loader.conf
	install -vm600 files/${board}/arch.conf rootfs/boot/loader/entries/arch.conf
	install -vm644 files/rk3568-nanopi-r5c/myfirstboot.service rootfs/etc/systemd/system/myfirstboot.service
	install -vm744 files/rk3568-nanopi-r5c/myfirstboot.sh rootfs/usr/local/bin/myfirstboot.sh
	chroot rootfs /usr/bin/bash -c "systemctl enable myfirstboot.service"
	chroot rootfs /usr/bin/bash -c "pacman-key --init && pacman-key --populate archlinuxarm"
	chroot rootfs /usr/bin/bash -c "pacman --noconfirm -Syu"
	pkill gpg-agent
}

# u-boot
function add_uboot(){
	local image=$1
	local board=$2
	cecho title  "Writting u-boot to ${image}."
	dd if=files/${board}/u-boot-rockchip.bin of=${image} bs=32k seek=1 conv=fsync,notrunc status=progress
}

function main(){
        cecho title "Checking build environment..."
        build_environment_init

        cecho title "Creating void image..."
        create_void_image ${image}

        cecho title "Creating partitions..."
        disk_part ${image}

        cecho title "Formating partitions..."
        format_part ${image} ${loopdev}

        cecho title "Mounting block devices..."
        mount_rootfs ${loopdev} ${archtarball}

        cecho title "Customize image files..."
        cus_chroot ${board}

        cecho title "Writing u-boot to block..."
        add_uboot ${image} ${board}
}
# clean all while script exit
trap "clean ${loopdev}" EXIT INT QUIT ABRT TERM

time main $@

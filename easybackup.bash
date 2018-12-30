#!/bin/bash

CONFIGS="/etc/easybackup"
HOSTIDENTIFIER="$CONFIGS/secret_identifier"

function usage () {
	echo -n "easybackup [command] [options]

commands:
	init <device|mountpoint> [<paths-to-backup> ... ]
		Init a device/path as a target for easybackup.
		List of paths is optional, /etc and /home are used
		as default.
		List of backup-devices is kept under /etc/easybackup.

	backup <device|mountpoint>
		Scan for new devices and check if backup should be started.

	stamp <device|mountpoint> [<paths-to-backup> ...]
		Print stamp for disk to STDOUT

	signature <device|mountpoint>
		Print signature for disk to STDOUT

	wipe <device|mountpoint>
		Wipe 'easybackup' directory on disk an remove it from
		configuration directory $CONFIGS
" >&2
	exit 2
}

function errx () {
	local _ex="$1"; shift
	echo "easybackup: $@"
	exit $_ex
}

# copy stdin to a specific file w/ mode
function myinstall () {
	local fn="$1"
	local args="${2:-"-o root -g root -m 0600"}"

	tmpfile=`mktemp`
	cat - > "$tmpfile"
	sudo install $args "$tmpfile" "$fn"
	rm "$tmpfile"
}

# generate 16 random bytes, encoded as HEX
function random16hex () {
	dd if=/dev/urandom count=1 bs=16 2>/dev/null | hexdump -e '/1 "%02X"'
	echo
}

# read/generate host-identifier used for authentication of disks
# secret of your data relies on confidentiality of this file!!!
function hostidentifier () {
	if ! sudo cat "$HOSTIDENTIFIER" 2>/dev/null; then
		test -d "$CONFIGS" || sudo install -d -o root -g root -m 0755 "$CONFIGS"
		random16hex | myinstall "$HOSTIDENTIFIER"
		sudo cat "$HOSTIDENTIFIER"
	fi
}

function unmapper () {
	local _part="$1"

	if [ -e "/dev/mapper/$_part" ]; then
		_part=`readlink -f /dev/mapper/$_part`
		_part="${_part##*/}"
	fi
	echo $_part
}

function hwpartition () {
	local _part="$1"

	_part=$( unmapper $_part )

	while :; do
	case "$_part" in
		sd*|hd*)
			break
			;;
		dm-*)
			_part=`cd /sys/devices/virtual/block/$_part/slaves && echo *`
			;;
		*)
			errx 1 "hwpartition($_part): don't know what to do"
			;;
	esac
	done
	echo $_part
}

function sign () {
	hid=`hostidentifier`
	set -- `md5sum << EOF
${hid}$@
EOF`
	echo $1
}

# sets 'MD5SIGNATURE' and 'STAMP' variables
function calculate_signature () {
	local partition="$1"; shift
	local paths="$@"

	# get LABEL, UUID and TYPE of device
	# LABEL, UUID etc belong to *logical* filesystem (ext4 etc.)
	#blkid /dev/dm-3 | sed -e 's/.*: //'
	#LABEL="cryptopladde" UUID="67f1a4a8-1601-4fe4-a2f7-07c7d8509a91" TYPE="ext4"
	partition=$( unmapper $partition )
	eval $( sudo blkid "/dev/$partition" | sed -e 's/.*: //' )
	export LABEL UUID TYPE

	# get real hardware partition under the filesys
	hwpartition=$( hwpartition $partition )

	# get UUID of physical partition
	# get SERIAL-NO of hard-drive
	eval $(	/bin/udevadm info --name=/dev/$hwpartition |
		egrep 'ID_FS_UUID=|ID_SERIAL=' |
		sed -e 's/^E: //g' )
	export ID_FS_UUID ID_SERIAL

	# create a signature from specific random (for this computer)
	# and the values for UUIDs and drive's serial number
	MD5SIGNATURE=`sign "$UUID" "$ID_FS_UUID" "$ID_SERIAL"`
	read -d '' STAMP << EOF
# auto-generated by easybackup - do not edit
# immutable settings
UUID="$UUID"
ID_FS_UUID="$ID_FS_UUID"
ID_SERIAL="$ID_SERIAL"
SIGNATURE="$MD5SIGNATURE"
# changeable
LABEL="$LABEL"
PATHS="$paths"
EOF
}

# pmf == partition, mountpoint, fstype
function pmf () {
	local dev="$1"

	set -- `mount | grep $dev | grep ^/ | head -1`
	partition="${1##*/}"				# /dev/dm-3 -> dm-3
	mountpoint="$3"
	fstype="$5"
	export partition mp fstype

	[ -z "$partition" ]	&& errx 1 "cannot find partition for $dev"
	[ -z "$fstype" ]	&& errx 1 "cannot find fstype for $dev"
	[ -z "$mountpoint" ]	&& errx 1 "cannot find mountpoint for $dev"
	[ "$mountpoint" = "/" ]	&& errx 1 "refusing mountpoint '/' for $dev"
}

#### functions called from main()

function stamp () {
	local dev="$1"; shift
	local paths="$@"

	pmf "$dev"
	calculate_signature "$partition" "$paths"
	echo "$STAMP"
}

function signature () {
	local dev="$1"

	pmf "$dev"
	calculate_signature "$partition"
	echo "$MD5SIGNATURE"
}

function wipe () {
	local dev="$1"

	pmf "$dev"
	calculate_signature "$partition"

	if [ -e "$CONFIGS/$MD5SIGNATURE" ]; then
		sudo /bin/rm "$CONFIGS/$MD5SIGNATURE"
	fi
	if [ -e "$mountpoint/easybackup" ]; then
		sudo /bin/rm -rf "$mountpoint/easybackup"
	fi
}

function init () {
	local dev="$1"; shift
	local paths="${@:-/etc /home}"; shift

	pmf "$dev"

	[ -e "$mountpoint/easybackup/.easybackup" ] &&
		errx 1 "partition=$partition mp=$mountpoint already initialized." \
		"Use 'wipe' to clear."
	[ -e "$mountpoint/easybackup" ] &&
		errx 1 "partition=$partition mp=$mountpoint initialized?" \
		"Use 'wipe' to clear."

	case "$fstype" in
	ext2|ext3|ext4)
		;;
	*)
		errx 1 "refusing to use filesystem of type '$fstype' for backup"
		;;
	esac

	sudo install -d -o root -g root -m 0755 "$mountpoint/easybackup"

	calculate_signature $partition $paths
	# exports MD5SIGNATURE and STAMP

	echo -e "$STAMP" | myinstall "$CONFIGS/$MD5SIGNATURE"
	# keep a copy on the usb-disk ...
	echo -e "$STAMP" | myinstall "$mountpoint/easybackup/$MD5SIGNATURE"
}

function backup () {
	local dev="$1"

	pmf "$dev"
	calculate_signature $partition

	if [ ! -e "$CONFIGS/$MD5SIGNATURE" ]; then
		errx 0 "config $CONFIGS/$MD5SIGNATURE not found - use easybackup init"
	fi

	# XXX: eval configs is always bad, but fuck it here
	eval "$( sudo cat $CONFIGS/$MD5SIGNATURE )"
	[ "$SIGNATURE" = "$MD5SIGNATURE" ] ||
		errx 1 "signature $SIGNATURE doesn't match $MD5SIGNATURE"
	
	echo "backup to ID_FS_UUID=$ID_FS_UUID LABEL=$LABEL starting ..."
	sudo touch $mountpoint/easybackup/easybackup_start
	for p in $PATHS; do
		echo "$p -> $mountpoint/easybackup/"
		sudo rsync -au $p $mountpoint/easybackup/
	done
	sudo touch $mountpoint/easybackup/easybackup_stop
}

###
### MAIN
###

cmd="$1"; shift
case "$cmd" in
	init|backup|stamp|signature|wipe)
		"$cmd" "$@"
		;;
	*)
		usage
		;;
esac
exit 0

#################################################

# use this for testing and to see defined variables:
# $ udevadm test -a add /class/block/sdb1
...
preserve already existing symlink '/dev/disk/by-uuid/2018-04-25-06-09-17-00' to '../../sdb1'
.ID_FS_TYPE_NEW=iso9660
.MM_USBIFNUM=00
ACTION=add
DEVLINKS=/dev/disk/by-path/pci-0000:00:14.0-usb-0:1:1.0-scsi-0:0:0:0-part1 /dev/disk/by-label/Fedora-S-dvd-x86_64-28 /dev/disk/by-uuid/2018-04-25-06-09-17-00 /dev/disk/by-id/usb-SanDisk_Cruzer_Switch_4C532005770307121182-0:0-part1
DEVNAME=/dev/sdb1
DEVPATH=/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/host3/target3:0:0/3:0:0:0/block/sdb/sdb1
DEVTYPE=partition
ID_BUS=usb
ID_DRIVE_THUMB=1
ID_FS_APPLICATION_ID=GENISOIMAGE\x20ISO\x209660\x2fHFS\x20FILESYSTEM\x20CREATOR\x20\x28C\x29\x201993\x20E.YOUNGDALE\x20\x28C\x29\x201997-2006\x20J.PEARSON\x2fJ.SCHILLING\x20\x28C\x29\x202006-2007\x20CDRKIT\x20TEAM
ID_FS_BOOT_SYSTEM_ID=EL\x20TORITO\x20SPECIFICATION
ID_FS_LABEL=Fedora-S-dvd-x86_64-28
ID_FS_LABEL_ENC=Fedora-S-dvd-x86_64-28
ID_FS_SYSTEM_ID=LINUX
ID_FS_TYPE=iso9660
ID_FS_USAGE=filesystem
ID_FS_UUID=2018-04-25-06-09-17-00
ID_FS_UUID_ENC=2018-04-25-06-09-17-00
ID_FS_VERSION=Joliet Extension
ID_INSTANCE=0:0
ID_MODEL=Cruzer_Switch
ID_MODEL_ENC=Cruzer\x20Switch\x20\x20\x20
ID_MODEL_ID=5572
ID_PART_TABLE_TYPE=dos
ID_PART_TABLE_UUID=537f877e
ID_PATH=pci-0000:00:14.0-usb-0:1:1.0-scsi-0:0:0:0
ID_PATH_TAG=pci-0000_00_14_0-usb-0_1_1_0-scsi-0_0_0_0
ID_REVISION=1.26
ID_SERIAL=SanDisk_Cruzer_Switch_4C532005770307121182-0:0
ID_SERIAL_SHORT=4C532005770307121182
ID_TYPE=disk
ID_USB_DRIVER=usb-storage
ID_USB_INTERFACES=:080650:
ID_USB_INTERFACE_NUM=00
ID_VENDOR=SanDisk
ID_VENDOR_ENC=SanDisk\x20
ID_VENDOR_ID=0781
MAJOR=8
MINOR=17
PARTN=1
SUBSYSTEM=block
TAGS=:systemd:
USEC_INITIALIZED=379917051423
run: '/home/kai/p/easybackup/easybackup.bash /devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/host3/target3:0:0/3:0:0:0/block/sdb/sdb1'
Unload module index
Unloaded link configuration context.

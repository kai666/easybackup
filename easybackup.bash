#!/bin/bash

###
# Copyright (c) 2018-2019 Kai Doernemann (kai_AT_doernemann.net)
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# 3. The name of the author may not be used to endorse or promote products
#    derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY KAI DOERNEMANN "AS IS" AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
###

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
		Attributes of backup-devices are signed with a secret
		and verified before backup starts. By this, only a 100%
		cloned USB harddrive (with same serial, filesys etc.)
		will trigger the start of a backup.
		Backup to encrypted partitions is a good idea, anyhow.

	backup [<device|mountpoint> ...]
		Scan for new devices and check if backup should be started.

	clean [<device|mountpoint> ...]
		Remove old backup directories, if GENERATIONS=X key is
		used in configuration.

	list [<device|mountpoint> ...]
		List names of mountpoints with active easybackup directories.

	stamp <device|mountpoint> [<paths-to-backup> ...]
		Print stamp for disk to STDOUT

	signature [<device|mountpoint> ...]
		Print signature for disk to STDOUT

	wipe [<device|mountpoint> ...]
		Wipe 'easybackup' directory on disk an remove it from
		configuration directory $CONFIGS

This usage() is quiet shitty.
" >&2
	exit 2
}

function errx () {
	local _ex="$1"; shift
	echo "easybackup: $@"
	exit $_ex
}

# create absolute pathname from relative pn
function absolute () {
	local _x="$1"
	[ -n "${_x##/*}" ] && _x="${PWD}/$_x"
	echo "${_x}"
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
GENERATIONS=7
EOF
}

# pmf == PARTITION, MOUNTPOINT, FSTYPE
function pmf () {
	local dev="$1"

	[ -z "$dev" ] && errx 1 "no dev defined"

	dev=${dev%%/}		# cut trailing '/'
	dev="`absolute "$dev"`"

	set -- `mount | grep $dev | grep ^/ | head -1`
	PARTITION="${1##*/}"				# /dev/dm-3 -> dm-3
	MOUNTPOINT="$3"
	FSTYPE="$5"
	export PARTITION MOUNTPOINT FSTYPE

	[ -z "$PARTITION" ]	&& errx 1 "cannot find partition for $dev"
	[ -z "$FSTYPE" ]	&& errx 1 "cannot find fstype for $dev"
	[ -z "$MOUNTPOINT" ]	&& errx 1 "cannot find mountpoint for $dev"
	[ "$MOUNTPOINT" = "/" ]	&& errx 1 "refusing mountpoint '/' for $dev"
}

#### functions called from main()

function stamp () {
	local dev="$1"; shift
	local paths="$@"

	pmf "$dev"
	calculate_signature "$PARTITION" "$paths"
	echo "$STAMP"
}

function signature () {
	local dev="$1"

	pmf "$dev"
	calculate_signature "$PARTITION"
	echo "$MD5SIGNATURE"
}

function wipe () {
	local dev="$1"

	pmf "$dev"
	calculate_signature "$PARTITION"

	done=""
	if [ -e "$CONFIGS/$MD5SIGNATURE" ]; then
		sudo /bin/rm "$CONFIGS/$MD5SIGNATURE"
		done="${done}y"
	fi
	if [ -e "$MOUNTPOINT/easybackup" ]; then
		sudo /bin/rm -rf "$MOUNTPOINT/easybackup"
		done="${done}y"
	fi
	[ -z "$done" ] && errx 1 "nothing wiped on $dev"
}

function init () {
	local dev="$1"; shift
	local paths="${@:-/etc /home}"; shift

	pmf "$dev"

	[ -e "$MOUNTPOINT/easybackup/.easybackup" ] &&
		errx 1 "partition=$PARTITION mp=$MOUNTPOINT already initialized." \
		"Use 'wipe' to clear."
	[ -e "$MOUNTPOINT/easybackup" ] &&
		errx 1 "partition=$PARTITION mp=$MOUNTPOINT initialized?" \
		"Use 'wipe' to clear."

	case "$FSTYPE" in
	ext2|ext3|ext4)
		;;
	*)
		errx 1 "refusing to use filesystem of type '$FSTYPE' for backup"
		;;
	esac

	sudo install -d -o root -g root -m 0755 "$MOUNTPOINT/easybackup"

	calculate_signature $PARTITION $paths
	# exports MD5SIGNATURE and STAMP

	echo -e "$STAMP" | myinstall "$CONFIGS/$MD5SIGNATURE"
	# keep a copy on the usb-disk ...
	echo -e "$STAMP" | myinstall "$MOUNTPOINT/easybackup/$MD5SIGNATURE"
}

# check device, read config
# exports $MD5SIGNATURE and all variables defined in calculate_signature
function _ckdev () {
	local dev="$1"

	pmf "$dev"
	calculate_signature $PARTITION

	if [ ! -e "$CONFIGS/$MD5SIGNATURE" ]; then
		errx 0 "config $CONFIGS/$MD5SIGNATURE not found - use easybackup init"
	fi

	# XXX: eval configs is always bad, but fuck it here
	eval "$( sudo cat $CONFIGS/$MD5SIGNATURE )"
	[ "$SIGNATURE" = "$MD5SIGNATURE" ] ||
		errx 1 "signature $SIGNATURE doesn't match $MD5SIGNATURE"
}

# remove old backup directories
function clean () {
	local dev="$1"

	_ckdev "$dev"
	gen=${GENERATIONS:-0}
	if [ "$gen" -eq 0 ]; then
		echo "no GENERATIONS defined. nothing cleaned."
		return
	fi

	echo "cleanup old backup directories (GENERATIONS=$gen) ..."
	cd "$MOUNTPOINT/easybackup"
	for d in `/bin/ls -1t`; do
		test -d "$d" || continue
		gen=$(( $gen - 1 ))
		test $gen -ge 0 && continue
		echo "cleanup_generations: remove $d"
	done
	cd - > /dev/null
}

function backup () {
	local dev="$1"

	_ckdev "$dev"
	echo "backup to ID_FS_UUID=$ID_FS_UUID LABEL=$LABEL starting ..."
	gen=${GENERATIONS:-0}
	if [ "$gen" -eq 0 ]; then
		echo "using GENERATIONS=0. no versioning."
		yyyymndd="00000000"
	else
		echo "using GENERATIONS=$gen"
		yyyymmdd=`date +%Y%m%d`
	fi
	targetdir="$MOUNTPOINT/easybackup/$yyyymmdd"
	sudo mkdir -p "$targetdir"
	sudo touch $targetdir/easybackup_start
	for p in $PATHS; do
		echo "$p -> $targetdir"
		sudo rsync -au $p $targetdir/
	done
	sudo touch $targetdir/easybackup_stop
	clean "$dev"
}

function auto_devices () {
	mount | grep ^/ | while read dev on mp type fstype; do
		[ -d "$mp/easybackup" ] && echo $dev
	done
}

function list () {
	echo "$1"
}

###
### MAIN
###

cmd="${1:-backup}"; shift
case "$cmd" in
	init|stamp)
		"$cmd" "$@"
		;;

	backup|clean|list|signature|wipe)
		devices="${@:-`auto_devices`}"
		for d in "$devices"; do
			"$cmd" "$d"
		done
		;;
	*)
		usage
		;;
esac
exit 0

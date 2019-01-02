#!/bin/bash

# daemon calls easybackup when filesystem mounts changed

EASYBACKUP=/usr/bin/easybackup

oldstate=""

while :; do
	set -- $(mount | grep ^/ | md5sum)
	currentstate="$1"
	if [ "$oldstate" != "$currentstate" ]; then
		oldstate="$currentstate"
		$EASYBACKUP auto
	fi
	sleep 60
done
exit 0


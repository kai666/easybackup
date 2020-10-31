#!/bin/bash

# daemon calls easybackup when filesystem mounts changed

EASYBACKUP=/usr/bin/easybackup

oldstate=""
gothup=""

trap "gothup='yes'" SIGHUP

while :; do
	set -- $(mount | grep ^/ | md5sum)
	currentstate="$1"
	if [ "$oldstate" != "$currentstate" -o -n "$gothup" ]; then
		oldstate="$currentstate"
		gothup=""
		$EASYBACKUP
	fi
	sleep 60
done
exit 0


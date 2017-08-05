#!/bin/sh

TRAVEL_DIR=$(findmnt -rnf -o TARGET /dev/disk/by-label/travel)
HOSTNAME=$(hostname)
BACKUP_DIR="${TRAVEL_DIR}/backup/${HOSTNAME}"
SOURCE_DIR="/home"

P_LINKS="-lH"
P_ATTRS="-pA"
P_TIME="-t"
P_OWNER="-go"

BACKUP_LOG_FILE="${BACKUP_DIR}/backup_${HOSTNAME}_$(date +%Y%m%d%H%M%S).log"

rsync -r $P_LINKS $P_ATTRS $P_TIME $P_OWNER \
	--delete -h --progress --log-file=$BACKUP_LOG_FILE \
	$SOURCE_DIR $BACKUP_DIR


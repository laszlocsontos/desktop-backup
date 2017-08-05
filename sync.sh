#!/bin/sh

TRAVEL_LABEL="travel"
TRAVEL_DIR=$(findmnt -rnf -o TARGET /dev/disk/by-label/$TRAVEL_LABEL)
HOSTNAME=$(hostname)
BACKUP_DIR="${TRAVEL_DIR}/backup/${HOSTNAME}"
SOURCE_DIR="/home"

P_LINKS="-lH"
P_ATTRS="-pA"
P_TIME="-t"
P_OWNER="-go"

mkdir -p $BACKUP_DIR

BACKUP_LOG_FILE="${BACKUP_DIR}/backup_${HOSTNAME}_$(date +%Y%m%d%H%M%S).log"

rsync -r $P_LINKS $P_ATTRS $P_TIME $P_OWNER \
	--delete -h --progress --log-file=$BACKUP_LOG_FILE \
	$SOURCE_DIR $BACKUP_DIR


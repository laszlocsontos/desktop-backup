#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

# Set magic variables for current file & dir
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename ${__file} .sh)"
__root="$(cd "$(dirname "${__dir}")" && pwd)" # <-- change this as it depends on your app

arg1="${1:-}"

LOCKFILE="/var/lock/backup.lock"
BACKUP_LOCAL_DIR="/mnt/backup"
BACKUP_LOG_DIR="${BACKUP_LOCAL_DIR}/logs"
BACKUP_REMOTE_DIR="192.168.1.100:/backup"

VG_NAME=$(vgs --noheadings --options vg_name | tr -d " ")
SNAPSHOT_NAME="rdiff-snapshot"
SNAPSHOT_DIR="/mnt/${SNAPSHOT_NAME}"
SNAPSHOT_SIZE="1024M"
SNAPSHOT_LV_NAME="/dev/${VG_NAME}/${SNAPSHOT_NAME}"

# Previous makewhatis should execute successfully:
[ -f $LOCKFILE ] && exit 0

# Upon exit do a cleanup
function cleanup {
  umount $BACKUP_LOCAL_DIR
  rm -f $LOCKFILE
  exit 255
}

trap cleanup EXIT
trap 'echo "INTERRUPTED"' SIGINT SIGTERM
trap 'echo "ERROR"' ERR

touch $LOCKFILE

function create_snapshot {
  MOUNTPOINT=$1
  TYPE=$2
  DEV=$3

  mkdir -p $SNAPSHOT_DIR

  if [ "${TYPE}" == "lvm" ]; then
    echo "Snapshotting ${MOUNTPOINT}"
    LVS=$(lvs --noheadings --options vg_name,lv_name $DEV | awk '{ print $1","$2 }')
    IFS="," read VG_NAME LV_NAME <<< "${LVS}"
    lvcreate --size $SNAPSHOT_SIZE --snapshot "${VG_NAME}/${LV_NAME}" --name $SNAPSHOT_NAME
    mount -o nouuid,ro $SNAPSHOT_LV_NAME $SNAPSHOT_DIR
  else
    echo "Freezing ${MOUNTPOINT}"
    fsfreeze -f $MOUNTPOINT
    mount -o bind $MOUNTPOINT $SNAPSHOT_DIR
  fi
}

function delete_snapshot {
  MOUNTPOINT=$1
  TYPE=$2

  umount $SNAPSHOT_DIR

  if [ "${TYPE}" == "lvm" ]; then
    echo "Removing snapshot for ${MOUNTPOINT}"
    lvremove $SNAPSHOT_LV_NAME
  else
    echo "Un-freezing ${MOUNTPOINT}"
    fsfreeze -u $MOUNTPOINT
  fi
}

function backup_fs {
  MOUNTPOINT=$1
  TYPE=$2
  DEV=$3
  NAME=$4

  echo "Backup of file system of ${NAME} on host $(hostname) started at $(date --rfc-3339=ns)"
  create_snapshot $MOUNTPOINT $TYPE $DEV

  BACKUP_DIR="${BACKUP_LOCAL_DIR}/$(hostname)/${NAME}"
  findmnt -nl -R $MOUNTPOINT -o TARGET | tail -n+2 | \
    rdiff-backup --exclude-filelist-stdin --no-eas --no-acls \
      --print-statistics -v4 $MOUNTPOINT $BACKUP_DIR

  delete_snapshot $MOUNTPOINT $TYPE
  echo "Backup of file system of ${NAME} on host $(hostname) finished at $(date --rfc-3339=ns)"
}

mount -t nfs -o proto=tcp,port=2049 $BACKUP_REMOTE_DIR $BACKUP_LOCAL_DIR
mkdir -p $BACKUP_LOG_DIR

exec 1<>$BACKUP_LOG_DIR/backup_$(hostname)_$(date +%Y%m%d%H%M%S).log
exec 2>&1

echo "Mounted ${BACKUP_REMOTE_DIR} under ${BACKUP_LOCAL_DIR}"

IFS=$'\n'
for FILESYSTEM in \
  $(lsblk -npr -o MOUNTPOINT,LABEL,NAME,TYPE,FSTYPE | grep -v "^[[:space:]]" | tr " " "," | grep "^\/opt");
do
  IFS="," read MOUNTPOINT LABEL DEV TYPE FSTYPE    <<< "${FILESYSTEM}"
  NAME=${LABEL:-${MOUNTPOINT#/}}
  backup_fs $MOUNTPOINT $TYPE $DEV $NAME
done

echo "SUCCESS"
exit 0

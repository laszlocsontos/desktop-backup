#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

# Previous backup should be executing successfully
LOCKFILE="/var/lock/backup.lock"
[ -f $LOCKFILE ] && exit 0

# Load configuration
ARCHIVE_LOCAL_DIR="/mnt/archive"
ARCHIVE_REMOTE_DIR="192.168.1.100:/archive"
BACKUP_LOCAL_DIR="/mnt/backup"
BACKUP_REMOTE_DIR="192.168.1.100:/backup"
SNAPSHOT_NAME="rdiff-snapshot"
SNAPSHOT_SIZE="1024M"

[ -f /etc/default/backup ] && . /etc/default/backup

ARCHIVE_LOG_DIR="${ARCHIVE_LOCAL_DIR}/logs"
BACKUP_LOG_DIR="${BACKUP_LOCAL_DIR}/logs"
SNAPSHOT_DIR="/mnt/${SNAPSHOT_NAME}"

# Get the source device name for a mounted directory
function get_source_device {
  MOUNTPOINT=$1
  if [ -z "${MOUNTPOINT}" ]; then
    echo ""
    return 0
  fi

  echo $(findmnt -nl $MOUNTPOINT -o SOURCE)
}

# Make a snapshot for a given mount point or freeze it if it's not LVM backed
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
    SNAPSHOT_DEV="/dev/${VG_NAME}/${SNAPSHOT_NAME}"
    mount -o nouuid,ro $SNAPSHOT_DEV $SNAPSHOT_DIR
  else
    echo "Freezing ${MOUNTPOINT}"
    fsfreeze -f $MOUNTPOINT
    mount $DEV $SNAPSHOT_DIR
  fi
}

# Delete the snapshot of a given mount point or un-freeze it if it's not LVM backed
function delete_snapshot {
  MOUNTPOINT=$1
  TYPE=$2

  if [ "${TYPE}" == "lvm" ]; then
    echo "Removing snapshot for ${MOUNTPOINT}"
    SNAPSHOT_DEV=$(get_source_device $SNAPSHOT_DIR)
    umount $SNAPSHOT_DIR
    lvremove -f $SNAPSHOT_DEV
  else
    echo "Un-freezing ${MOUNTPOINT}"
    fsfreeze -u $MOUNTPOINT
    umount $SNAPSHOT_DIR
  fi

  rmdir $SNAPSHOT_DIR
}

function archive {
  for ARCHIVE_DIR in $(find /home -type d -name _archive); do
    echo "Archiving ${ARCHIVE_DIR} on host $(hostname) started at $(date --rfc-3339=ns)"

    BARE_ARCHIVE_DIR=${ARCHIVE_DIR%/_archive*}
    BARE_ARCHIVE_DIR=${BARE_ARCHIVE_DIR#/}
    ARCHIVE_TARGET_DIR="${ARCHIVE_LOCAL_DIR}/$(hostname)/${BARE_ARCHIVE_DIR}"
    mkdir -p ARCHIVE_TARGET_DIR

    rsync --recursive --links --hard-links --perms --owner --group --times \
      --human-readable --remove-source-files "${ARCHIVE_DIR}/" $ARCHIVE_TARGET_DIR

    # For safety reasons we check that ARCHIVE_DIR isn't empty
    if [ "${ARCHIVE_DIR:-/}" != "/" ]; then
      rm -rf ${ARCHIVE_DIR}
    fi

    echo "Archiving ${ARCHIVE_DIR} on host $(hostname) finished at $(date --rfc-3339=ns)"
  done
}

# Backup a given file system with rdiff-backup
function backup_fs {
  MOUNTPOINT=$1
  TYPE=$2
  DEV=$3
  NAME=$4

  echo "Backup of file system ${MOUNTPOINT} on host $(hostname) started at $(date --rfc-3339=ns)"
  create_snapshot $MOUNTPOINT $TYPE $DEV

  BACKUP_DIR="${BACKUP_LOCAL_DIR}/$(hostname)/${NAME}"
  findmnt -nl -R $MOUNTPOINT -o TARGET | tail -n+2 | \
    rdiff-backup --exclude-filelist-stdin --no-eas --no-acls \
      --print-statistics -v4 $MOUNTPOINT $BACKUP_DIR

  delete_snapshot $MOUNTPOINT $TYPE
  echo "Backup of file system ${MOUNTPOINT} on host $(hostname) finished at $(date --rfc-3339=ns)"
}

# Go over all the mounted file systems and backup them
function backup {
  IFS=$'\n'
  for FILESYSTEM in \
    $(lsblk -npr -o MOUNTPOINT,LABEL,NAME,TYPE,FSTYPE | grep -v "^[[:space:]]" | tr " " ",");
  do
    IFS="," read MOUNTPOINT LABEL DEV TYPE FSTYPE <<< "${FILESYSTEM}"
    NAME=${LABEL:-${MOUNTPOINT#/}}
    if [ "${FSTYPE}" != "swap" ]; then
      backup_fs $MOUNTPOINT $TYPE $DEV $NAME
    fi
  done
}

# Mount remote backup directories
function mount_remote {
  REMOTE_DIR=$1
  LOCAL_DIR=$2

  [ ! -d "${LOCAL_DIR}" ] && mkdir -p $LOCAL_DIR
  mount -t nfs -o proto=tcp,port=2049 $REMOTE_DIR $LOCAL_DIR
  echo "Mounted ${REMOTE_DIR} under ${LOCAL_DIR}"
}

# Upon exit do a cleanup
function cleanup {
  if [ -d "${SNAPSHOT_DIR}" ]; then
    SNAPSHOT_DEV=$(get_source_device $SNAPSHOT_DIR)
    if [ -n "${SNAPSHOT_DEV}" ]; then
      IFS="," read MOUNTPOINT TYPE \
        <<< $(lsblk -npr -o MOUNTPOINT,TYPE $SNAPSHOT_DEV | tr " " ",")
      delete_snapshot $MOUNTPOINT $TYPE
    fi
  fi

  # Re-open STDOUT and STDERR
  exec 1>&0
  exec 2>&0

  umount $ARCHIVE_LOCAL_DIR
  umount $BACKUP_LOCAL_DIR

  rm -f $LOCKFILE
  exit 255
}

# Install traps
trap cleanup EXIT
trap 'echo "STATUS:INTERRUPTED"' SIGINT SIGTERM
trap 'echo "STATUS:ERROR"' ERR

# Acquire global lock
touch $LOCKFILE

# Mount remote file system for placing the backup
mount_remote $ARCHIVE_REMOTE_DIR $ARCHIVE_LOCAL_DIR
mount_remote $BACKUP_REMOTE_DIR $BACKUP_LOCAL_DIR

# Redirect STDOUT and STDERR to a log file
mkdir -p $BACKUP_LOG_DIR
exec 1<>$BACKUP_LOG_DIR/backup_$(hostname)_$(date +%Y%m%d%H%M%S).log
exec 2>&1

# Archive obsolete files first
archive

# Backup when archived data has already been moved
backup

echo "STATUS:SUCCESS"
exit 0

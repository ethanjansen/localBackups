#!/bin/bash

############# VARS ###############
BACKUP_DIR="/media/BACKUP/Backup"
DATE="$(date +"%Y-%m-%d")"
FREE=0
EXISTINGFILES=0
MARGIN=0
TOTAL_SIZE=0

# Info backup
DISKS=("/dev/nvme0n1" "/dev/nvme1n1" "/dev/sda") # Use fdisk individually rather than sfdisk to get info of partitionless disks
BTRFS_FILESYSTEMS_ALL=("/" "/mnt/vms" "/home/ethan/Data")
BTRFS_SUBVOLS_ALL=("/" "/home" "/var/tmp" "/var/log" "/var/cache" "/var/spool" "/mnt/games" "/mnt/vms" "/mnt/scratch" "/var/lib/docker" "/home/ethan/Data" "/home/ethan/Downloads" "/mnt/gameBackups")

# /boot backup
BOOT_TARGET="Boot" # will backup to $BOOT_TARGET.dd.xz
BOOT_DIR="/boot"
BOOT_DEV="/dev/nvme0n1p1"
BOOT_SIZE= # in bytes

# Tar backup - array of arrays
TAR_BACKUP_TARGETS=("Games") # First will be copied to $BACKUP_DIR/$TAR_BACKUP_TARGETS[], then backed up to $BACKUP_DIR/$TAR_BACKUP_TARGETS[].tar.xz
TAR_SOURCES_0=("/mnt/games/cloneHero" "/mnt/games/links" "/mnt/games/mods")
TAR_SIZES=() # in bytes - parallel to TAR_BACKUP_TARGETS[]
TAR_SIZES_0=() # in bytes - parallel to TAR_SOURCES_0[]

# BTRFS backup - parallel arrays
BTRFS_TARGETS=("Root" "Home" "VMs" "Data" "GameBackups") # will backup to $BTRFS_TARGETS.btrfs.xz
BTRFS_SUBVOLS=("/" "/home" "/mnt/vms" "/home/ethan/Data" "/mnt/gameBackups") # "/" is notable in that it ends with a trailing slash (it is only a slash)
BTRFS_SNAPPER_CONFIG=("root" "home" "vms" "data" "gameBackups")
BTRFS_SNAPSHOTS=() # latest snapshot number/id from snapper, will backup with source $BTRFS_SUBVOLS[]/.snapshots/$BTRFS_SNAPSHOTS[]/snapshot
BTRFS_SIZES=() # in bytes


############# Helper functions ################
toBytes() {
  local value="$1"
  local unit="${2:-B}"

  local mul

  # Convert to bytes given unit
  case "$unit" in
    B|"") mul=1 ;;
    K) mul=$((1024)) ;;
    M) mul=$((1024**2)) ;;
    G) mul=$((1024**3)) ;;
    T) mul=$((1024**4)) ;;
    *) echo "Invalid unit"; return 1 ;;
  esac

  awk -v v="$value" -v m="$mul" 'BEGIN { printf "%.0f", v*m }'
}

humanSize() {
  local value="$1"
  local unit="${2:-B}"

  local bytes

  if ! bytes=$(toBytes "$value" "$unit"); then
    echo "Invalid unit"
    return 1
  fi

  local sign=""
  if awk -v b="$bytes" 'BEGIN { exit !(b<0) }'; then
    sign="-"
    bytes=$(awk -v b="$bytes" 'BEGIN { print -b }')
  fi

  local units=(B K M G T P E)

  # Find largest unit without going below 1
  local i=0
  while (( i < ${#units[@]}-1 )); do
    local next
    next=$(awk -v b="$bytes" 'BEGIN { print (b/1024) }')
    awk -v n="$next" 'BEGIN { exit !(n < 1) }' && break
    bytes="$next"
    ((i++))
  done

  printf "%s%.2f %s\n" "$sign" "$bytes" "${units[$i]}"
}

FIXEDMOUNT=true
fixBootMount() {
  if ! $FIXEDMOUNT; then
    echo "Remounting $BOOT_DIR as read-write"
    mount -o remount "$BOOT_DIR"
    FIXEDMOUNT=true
  fi
  return 0
}

############# MAIN #################

# Check if root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: run as root!"
  exit 1
fi

# Make sure boot is mounted properly
trap fixBootMount EXIT

# Check if drive is mounted and path exists, make sure Date does not already exist
if ! mountpoint -q "/media/BACKUP"; then
  echo "ERROR: BACKUP is not mounted!"
  exit 1
fi
if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: $BACKUP_DIR does not exist!"
  exit 1
fi
if [ -d "$BACKUP_DIR/$DATE" ]; then
  echo "ERROR: $BACKUP_DIR/$DATE already exists!"
  exit 1
fi

# Unmount $BOOT_DIR
bootinusecount=$(lsof +f -- "$BOOT_DIR" 2>/dev/null | tail -n +2 | wc -l)
if [[ "$bootinusecount" -gt 0 ]]; then
  echo "ERROR: Unable to unmount $BOOT_DIR It is currently in use!"
  lsof +f -- "$BOOT_DIR" 2>/dev/null
  exit 1
fi
echo "Mounting $BOOT_DIR as read-only until a backup is taken of it"
echo
FIXEDMOUNT=false
mount -o remount,ro "$BOOT_DIR"

##### Get information
echo "Collecting information. Warning this will take a while!"
echo
echo "Backup Information:"

# backup dir stats
FREE=$(toBytes "$(df -k --output=avail "$BACKUP_DIR" | tail -n1)" "K")
EXISTINGFILES=$(du -bsc -- "$BACKUP_DIR" | tail -n1 | cut -f1)  # in B
echo
echo "Free Space Before Backup: $(humanSize "$FREE")"
echo
echo "Space Used Before Backup: $(humanSize "$EXISTINGFILES")"

# backup file sizes
echo
echo "Backup file size:"

# boot size
BOOT_SIZE=$(toBytes "$(df -k --output=size "$BOOT_DIR" | tail -n1)" "K")
(( TOTAL_SIZE += BOOT_SIZE ))
echo "  Boot: $(humanSize "$BOOT_SIZE")"

# tar size
for i in "${!TAR_BACKUP_TARGETS[@]}"; do
  target="${TAR_BACKUP_TARGETS[$i]}"
  declare -n SOURCES="TAR_SOURCES_$i"
  declare -n SIZES_N="TAR_SIZES_$i"

  total=0
  for j in "${!SOURCES[@]}"; do
    source="${SOURCES[$j]}"
    size=$(du -bsc -- "$source" | tail -n1 | cut -f1)  # in B
    SIZES_N[j]=$size
    (( total += size ))
  done

  TAR_SIZES[i]=$total
  (( TOTAL_SIZE += total ))
  echo "  $target: $(humanSize "$total")"
done

# get btrfs snapshots and sizes
for i in "${!BTRFS_TARGETS[@]}"; do
  target="${BTRFS_TARGETS[$i]}"
  subvol="${BTRFS_SUBVOLS[$i]}"
  snapperConfig="${BTRFS_SNAPPER_CONFIG[$i]}"
  [[ "$subvol" == "/" ]] || subvol="${subvol}/"

  snapshot="$(snapper -c "$snapperConfig" --csv ls -t single --disable-used-space | grep timeline | sort -t',' -k6,6 | less | tail -n 1 | cut -d',' -f3)"
  size="$(btrfs filesystem du -s --raw "${subvol}.snapshots/$snapshot/snapshot" | awk 'NR==2 {print $1}')"

  BTRFS_SNAPSHOTS[i]="$snapshot"
  BTRFS_SIZES[i]=$size
  (( TOTAL_SIZE += size ))
  echo "  $target: $(humanSize "$size")  (snapshot: $snapshot)"
done

# total backup size
MARGIN=$(toBytes 50 G)  # 50GiB in B
(( TOTAL_SIZE += MARGIN ))
echo "  Margin: $(humanSize "$MARGIN")"
echo
echo "Total Backup Size: $(humanSize "$TOTAL_SIZE")"

# remaining
REMAINING=$((FREE - TOTAL_SIZE))
echo
echo "Free Space After Backup:  $(humanSize "$REMAINING")"
echo

####### Loop and check for enough free space remaining
# check if it is impossible to get enough free space
TOTAL_BACKUPDIR_SPACE=$((FREE + EXISTINGFILES))
if [[ $TOTAL_BACKUPDIR_SPACE -lt $TOTAL_SIZE ]]; then
  echo "ERROR: it is not possible to get enough free space!"
  exit 1
fi

# General continue prompt
read -r -n 1 -p "Continue? [y/N]" continue
echo
if [[ ! "$continue" =~ ^[Yy]$ ]]; then
  exit 2
fi

# Iterate through, deleting old backups if necessary
until [[ $REMAINING -gt 0 ]]; do
  echo "Not enough free space!"
  # always gets oldest file. requires deletion to iterate
  IFS= read -r -d $'\0' line < <(find "$BACKUP_DIR" -type d -maxdepth 1 -mindepth 1 -printf '%T@ %p\0' 2>/dev/null | sort -z -n)
  file="${line#* }"
  filesize=$(du -bsc -- "$file" | tail -n1 | cut -f1)  # in B

  # confirm file deletion
  read -r -n 1 -p "Remove $(basename "$file") to free up $(humanSize "$filesize")? [y/N]" continue
  echo
  if [[ ! "$continue" =~ ^[Yy]$ ]]; then
    exit 2
  fi

  # Delete oldest backup
  rm -rfI "$file"
  (( REMAINING += filesize ))
done


######## Backup
mkdir "$BACKUP_DIR/$DATE"
echo
echo "Backing up data to $DATE"

# Info
echo
echo "Info:"
touch "$BACKUP_DIR/$DATE/Info.txt"
{
echo "##################### Disk and Partition Information #####################"
for i in "${!DISKS[@]}"; do
  fdisk -l "${DISKS[$i]}"
  echo
done
echo "##################### fstab #####################"
cat /etc/fstab
echo
echo "##################### BTRFS Filesystems #####################"
for i in "${!BTRFS_FILESYSTEMS_ALL[@]}"; do
  btrfs filesystem show "${BTRFS_FILESYSTEMS_ALL[$i]}"
  echo
done
echo "##################### BTRFS Subvolumes #####################"
for i in "${!BTRFS_SUBVOLS_ALL[@]}"; do
  btrfs subvolume show "${BTRFS_SUBVOLS_ALL[$i]}" | grep -v "snapshot"
  echo
done
} >> "$BACKUP_DIR/$DATE/Info.txt"
echo "  Done."

# Boot
echo
echo "$BOOT_TARGET:"
dd if="$BOOT_DEV" status=none | pv -s "$BOOT_SIZE" | xz -9e -T 0 --memory=90% > "$BACKUP_DIR/$DATE/$BOOT_TARGET.dd.xz"
echo -n "  Done: "
fixBootMount

# Tar
for i in "${!TAR_BACKUP_TARGETS[@]}"; do
  target="${TAR_BACKUP_TARGETS[$i]}"
  size="${TAR_SIZES[$i]}"
  declare -n SOURCES="TAR_SOURCES_$i"

  echo
  echo "$target:"
  tar -cf - "${SOURCES[@]}" 2>/dev/null | pv -s "$size" | xz -9e -T 0 --memory=90% > "$BACKUP_DIR/$DATE/$target.tar.xz"
done
echo "  Done."

# BTRFS
for i in "${!BTRFS_TARGETS[@]}"; do
  target="${BTRFS_TARGETS[$i]}"
  subvol="${BTRFS_SUBVOLS[$i]}"
  snapshot="${BTRFS_SNAPSHOTS[$i]}"
  size="${BTRFS_SIZES[$i]}"
  [[ "$subvol" == "/" ]] || subvol="${subvol}/"

  echo
  echo "$target:"
  btrfs send --proto 2 "${subvol}.snapshots/$snapshot/snapshot" | pv -s "$size" | xz -9e -T 0 --memory=90% > "$BACKUP_DIR/$DATE/$target.btrfs.xz"
  break
done
echo "  Done."

echo
read -rp "Backup Done!"


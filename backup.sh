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

# Rsync backup - array of arrays
RSYNC_BACKUP_TARGETS=("Games") # First will be copied to $BACKUP_DIR/$RSYNC_BACKUP_TARGETS[], then backed up to $BACKUP_DIR/$RSYNC_BACKUP_TARGETS[].tar.xz
RSYNC_SOURCES_0=("/mnt/games/cloneHero" "/mnt/games/links" "/mnt/games/mods")
RSYNC_SIZES=() # in bytes - parallel to RSYNC_BACKUP_TARGETS[]
RSYNC_SIZES_0=() # in bytes - parallel to RSYNC_SOURCES_0[]

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

############# MAIN #################

# Check if root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: run as root!"
  exit 1
fi

# Check if drive is mounted and path exists
if ! mountpoint -q "/media/BACKUP"; then
  echo "ERROR: BACKUP is not mounted!"
  exit 1
fi
if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: $BACKUP_DIR does not exist!"
  exit 1
fi

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
BOOT_SIZE=$(toBytes "$(df -k --output=used "$BOOT_DIR" | tail -n1)" "K")
(( TOTAL_SIZE += BOOT_SIZE ))
echo "  Boot: $(humanSize "$BOOT_SIZE")"

# rsync size
for i in "${!RSYNC_BACKUP_TARGETS[@]}"; do
  target="${RSYNC_BACKUP_TARGETS[$i]}"
  declare -n SOURCES="RSYNC_SOURCES_$i"
  declare -n SIZES_N="RSYNC_SIZES_$i"

  total=0
  for j in "${!SOURCES[@]}"; do
    source="${SOURCES[$j]}"
    size=$(du -bsc -- "$source" | tail -n1 | cut -f1)  # in B
    SIZES_N[j]=$size
    (( total += size ))
  done

  RSYNC_SIZES[i]=$total
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
  # size="$(btrfs filesystem du -s --raw "${subvol}.snapshots/$snapshot/snapshot" | awk 'NR==2 {print $1}')"

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

read -r -n 1 -p "Continue? [y/N]" continue
echo
if [[ ! "$continue" =~ ^[Yy]$ ]]; then
  exit 2
fi

until [[ $REMAINING -gt 0 ]]; do
  echo "Not enough free space!"
  IFS= read -r -d $'\0' line < <(find "$BACKUP_DIR" -type d -maxdepth 1 -mindepth 1 -printf '%T@ %p\0' 2>/dev/null | sort -z -n)
  file="${line#* }"
  filesize=$(du -bsc -- "$file" | tail -n1 | cut -f1)  # in B

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
echo
echo "Backing up data"
echo
echo "$BOOT_TARGET:"

exit 0



# Backup
echo "Starting Backup..."
pushd "$mediadir" || (echo "ERROR: cannout pushd"; exit 1)
rm -fv "Plex Media Server.tar.xz"

echo "Creating Metadata Backup on Server..."
sudo -u ethan ssh -i /home/ethan/.ssh/id_ed25519_nopass ethan@rpiserver.pihole "sudo /home/ethan/PlexServerBackup.sh"

echo "Backing up Media Files..."
sudo -u ethan rsync -e 'ssh -i /home/ethan/.ssh/id_ed25519_nopass' -rltDvP --delete --size-only --exclude="lost+found" ethan@rpiserver.pihole:/media/ethan/MediaContent/ "$mediadir"/
sudo -u ethan ssh -i /home/ethan/.ssh/id_ed25519_nopass ethan@rpiserver.pihole "rm -fv /media/ethan/MediaContent/Plex\ Media\ Server.tar.xz"

popd || exit 1
read -rp Done

#!/bin/bash
echo updating
sudo apt-get update
sudo apt-get upgrade -y

echo mounting drives
sudo mount /dev/disk/by-partlabel/BACKUP /media/ethan/BACKUP
sudo mount /dev/nvme1n1p4 /media/ethan/C
sudo mount /dev/sda1 /media/ethan/D
sudo mount /dev/nvme1n1p5 /media/ethan/E
sudo mount /dev/nvme0n1p1 /media/ethan/F

echo displaying information
(xterm -hold -e "htop" &> /dev/null &)
(xterm -hold -e "watch -n 300 ls -sh /media/ethan/BACKUP/Backup/`date +"%Y-%m-%d"`/" &> /dev/null &)

dir="/media/ethan/BACKUP/Backup/"
mediadir="/media/ethan/BACKUP/MediaBackup"
C="/media/ethan/C"
D="/media/ethan/D"
E="/media/ethan/E"
F="/media/ethan/F"
cd "$dir"

d="$(date +"%Y-%m-%d")"
mkdir "$d"

echo checking file sizes
FREE=`df -k --output=avail "$dir" | tail -n1`
MEDIAFILES=`du -sc "$mediadir" | tail -n1 | cut -f1`
FILES0=`runuser -l ethan -c 'rsync -a -n --stats --exclude="lost+found" ethan@192.168.1.15:/media/ethan/MediaContent' | grep "Total file size:" | cut -c 18-34 | tr -d ','`
FILES1=`df -k --output=used "$C" | tail -n1`
FILES2=`df -k --output=used "$F" | tail -n1`
FILES3=`du -sc "$C"/Users/ethan "$D"/Data "$D"/GameBackups "$E"/Lego\ Star\ Wars\ The\ Complete\ Saga "$E"/Linked "$E"/Minecraft "$E"/PvZ  | tail -n1 | cut -f1`
FILES4=$(($FILES0/1024 + $FILES1 + $FILES2 + $FILES3 - $MEDIAFILES + 524288000))
until [[ $FREE -gt $FILES4 ]]; do
        echo less than $FILES4 free
        IFS= read -r -d $'\0' line < <(find "$dir" -type d -maxdepth 1 -mindepth 1 -printf '%T@ %p\0' 2>/dev/null | sort -z -n)
        file="${line#* }"
        ls -lLd "$file"
        rm -rfI "$file"
	FREE=`df -k --output=avail "$dir" | tail -n1`
done
echo more than $FILES4 free
echo continuing

cd "$d"
echo full C backup
sudo umount "$C"
sudo dd if=/dev/nvme1n1p4 status=progress | xz -9e -T 0 --memory=90% > ./CBackup.dd.xz
sudo mount /dev/nvme1n1p4 "$C"

echo full EFI backup
sudo dd if=/dev/nvme1n1p1 status=progress | xz -9e -T 0 --memory=90% > ./EFIBackup.dd.xz

(xterm -hold -e "du -sh '/media/ethan/C/Users/ethan' '/media/ethan/D/Data' '/media/ethan/D/GameBackups' '/media/ethan/F' '/media/ethan/E/Lego Star Wars The Complete Saga' '/media/ethan/E/Linked' '/media/ethan/E/Minecraft' '/media/ethan/E/PvZ'" &> /dev/null &)
(xterm -hold -e "runuser -l ethan -c 'rsync -ahn --size-only --stats --exclude="lost+found" ethan@192.168.1.15:/media/ethan/MediaContent/ /media/ethan/BACKUP/MediaBackup/' | grep 'Total transferred file size:'" &> /dev/null &)

echo Users
mkdir Users
rsync -avP "$C"/Users/ethan ./Users/
tar -I "xz -9e -T 0 --memory=90%" -cpvf Users.tar.xz Users
rm -rfv Users

echo Data
rsync -avP "$D"/Data ./Data
tar -I "xz -9e -T 0 --memory=90%" -cpvf Data.tar.xz Data
rm -rfv Data

echo Games
mkdir Games
rsync -avP "$D"/GameBackups ./Games/
rsync -avP "$E"/Lego\ Star\ Wars\ The\ Complete\ Saga ./Games/
rsync -avP "$E"/Linked ./Games/
rsync -avP "$E"/Minecraft ./Games/
rsync -avP "$E"/PvZ ./Games/
tar -I "xz -9e -T 0 --memory=90%" -cpvf Games.tar.xz Games
rm -rfv Games

echo VirtualMachines
rsync -avP --exclude="\$RECYCLE.BIN" --exclude="System Volume Information" "$F"/* ./VirtualMachines
tar -I "xz -9e -T 0 --memory=90%" -cpvf VirtualMachines.tar.xz VirtualMachines
rm -rfv VirtualMachines

echo MediaContent
cd "$mediadir"
rm -fv "Plex Media Server.tar.xz"
runuser -l ethan -c 'ssh ethan@192.168.1.15 "sudo /home/ethan/PlexServerBackup.sh"'
echo Making sure disk is still mounted -- USB issue
mount /dev/disk/by-partlabel/BACKUP /media/ethan/BACKUP
runuser -l ethan -c "rsync -rltDvP --delete --size-only --exclude="lost+found" ethan@192.168.1.15:/media/ethan/MediaContent/ "$mediadir"/"
runuser -l ethan -c 'ssh ethan@192.168.1.15 "rm -fv /media/ethan/MediaContent/Plex\ Media\ Server.tar.xz"'

read -p finished

sudo killall xterm
sleep 10
sudo umount /media/ethan/*

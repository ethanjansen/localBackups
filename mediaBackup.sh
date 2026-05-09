#!/bin/bash

# Helper functions for information output
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

# Check if root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: run as root!"
  exit 1
fi

# Check if drive is mounted and path exists
if ! mountpoint -q /media/BACKUP; then
  echo "ERROR: BACKUP is not mounted!"
  exit 1
fi

mediadir="/media/BACKUP/MediaBackup"
if [ ! -d "$mediadir" ]; then
  echo "ERROR: $mediadir does not exist!"
  exit 1
fi

# Get information
echo "Backup Information:"
FREE=$(df -k --output=avail "$mediadir" | tail -n1)  # in KiB
FREE=$((FREE*1024))  # in B
MEDIAFILESIZE=$(sudo -u ethan rsync -e 'ssh -i /home/ethan/.ssh/id_ed25519_nopass' -an --stats --exclude="lost+found" ethan@rpiserver.pihole:/media/ethan/MediaContent | awk '/Total file size/ {print $4}' | tr -d ',')  # in B
EXISTINGFILES=$(du -bsc "$mediadir" | tail -n1 | cut -f1)  # in B
MEDIAFILESIZE=$((MEDIAFILESIZE - EXISTINGFILES))
MARGIN=$(toBytes 50 G)  # 100GiB in B
REMAINING=$((FREE - MEDIAFILESIZE - MARGIN))

echo
echo "MediaBackup Free Space Before Backup: $(humanSize "$FREE")"
echo
echo "New Media Files to Copy:              $(humanSize "$MEDIAFILESIZE")"
echo "Backup Size Margin:                   $(humanSize "$MARGIN")"
echo
echo "MediaBackup Free Space After Backup:  $(humanSize "$REMAINING")"
echo

if [[ $REMAINING -lt 0 ]]; then
  echo "ERROR: Not enough free space!"
  echo "Clean up some backups and try again..."
  exit 1
fi

read -r -n 1 -p "Continue? [y/N]" continue
echo
if [[ ! "$continue" =~ ^[Yy]$ ]]; then
  exit 1
fi

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

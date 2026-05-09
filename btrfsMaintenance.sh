#!/bin/bash

################ VARS ################
BTRFS_FILESYSTEMS=("/" "/mnt/vms" "/home/ethan/Data")

################ Main ################

# Check if root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: run as root!"
  exit 1
fi

# BTRFS maintenance loop
echo "Running Maintenance:"
echo
echo
for i in "${!BTRFS_FILESYSTEMS[@]}"; do
  filesystem="${BTRFS_FILESYSTEMS[$i]}"

  echo "$filesystem Starting Stats:"
  btrfs filesystem df "$filesystem"

  # scrub
  echo
  echo "  scrubbing..."
  btrfs scrub start -B "$filesystem"

  # balance (only data, not metadata)
  echo
  echo "  reclaiming unused blocks..."
  btrfs balance start -dusage=0 "$filesystem"
  echo
  echo "  balancing blocks under 70% used..."
  btrfs balance start -dusage=70 "$filesystem"

  echo
  echo "$filesystem Final Stats:"
  btrfs filesystem df "$filesystem"
  btrfs device stats "$filesystem" -c 

  echo
  echo
done

echo "Done!"

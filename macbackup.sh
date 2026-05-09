#!/bin/bash
echo updating
sudo apt-get update
sudo apt-get upgrade -y

echo mounting drives
sudo mount /dev/sdd2 /media/ethan/MACBACKUP
sudo mount /dev/sda4 /media/ethan/C
sudo mount /dev/sdb1 /media/ethan/Storage
sudo /home/ethan/Programs/apfs-fuse/build/apfs-fuse /dev/sdc2 /media/ethan/MAC

echo displaying information
(xterm -hold -e "htop" &> /dev/null &)
(xterm -hold -e "watch -n 300 ls -sh /media/ethan/MACBACKUP/Backup/`date +"%Y-%m-%d"`/" &> /dev/null &)

dir="/media/ethan/MACBACKUP/Backup/"
C="/media/ethan/C"
Storage="/media/ethan/Storage"
MAC="/media/ethan/MAC"
cd "$dir"

d="$(date +"%Y-%m-%d")"
mkdir "$d"

echo checking file sizes
FREE=`df -k --output=avail "$dir" | tail -n1`
FILES0=`sudo df -k --output=used "$MAC" | tail -n1`
FILES1=`sudo df -k --output=used "$C" | tail -n1`
FILES2=`du -sc "$C" "$Storage"/Mac | tail -n1 | cut -f1`
FILES3=$(($FILES0 + $FILES1 + $FILES2 + 105157600))
until [[ $FREE -gt $FILES3 ]]; do
        echo less than $FILES3 free
        IFS= read -r -d $'\0' line < <(find "/media/ethan/MACBACKUP/Backup" -type d -maxdepth 1 -mindepth 1 -printf '%T@ %p\0' 2>/dev/null | sort -z -n)
        file="${line#* }"
        ls -lLd "$file"
        rm -rfI "$file"
		FREE=`df -k --output=avail "$dir" | tail -n1`
done
echo more than $FILES3 free
echo continuing

cd "$d"
echo full C backup
sudo umount "$C"
sudo dd if=/dev/sda4 status=progress | xz -9e --memory=90% -T 0 > ./CBackup.dd.xz

echo full MAC backup
sudo umount "$MAC"
sudo dd if=/dev/sdc status=progress | xz -9e --memory=90% -T 0 > ./MACBackup.dd.xz

echo full EFI backup
sudo dd if=/dev/sda1 status=progress | xz -9e --memory=90% -T 0 > ./EFIBackup.dd.xz

echo full CloverEFI backup
sudo dd if=/dev/sdc1 status=progress | xz -9e --memory=90% -T 0 > ./CloverEFIBackup.dd.xz

(xterm -hold -e "du -sh '/media/ethan/Storage/Mac'" &> /dev/null &)

echo Mac
rsync -avP "$Storage"/Mac ./Mac
tar -I "xz -9e --memory=90% -T 0" -cpvf Mac.tar.xz Mac
rm -rfv Mac

read -p finished

sudo killall xterm
sleep 10
sudo umount /media/ethan/*

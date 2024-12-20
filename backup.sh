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

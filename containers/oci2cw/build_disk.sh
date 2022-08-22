#!/bin/bash

OCI_TARBALL=/work/oci.tar
DISK=/work/disk.img
CRYPT_PARTITION=cwroot
CWDIR=/tmp/cwdir
MIN_DISKSIZE=52428800

create_encrypted_disk() {    
    fallocate -l $DISKSIZE $DISK

    echo "YES" | echo "$PASSWORD"| cryptsetup luksFormat --force-password -y -v --type luks1 $DISK &> /dev/null
    if [ $? != 0 ]; then
        echo "luksFormat failed"
        return 1
    fi

    echo "$PASSWORD" | cryptsetup luksOpen $DISK $CRYPT_PARTITION &> /dev/null
    if [ $? != 0 ]; then
        echo "luksOpen failed"
        return 1
    fi

    mkfs.ext4 -q /dev/mapper/$CRYPT_PARTITION &> /dev/null
    if [ $? != 0 ]; then
        echo "mkfs.ext4 failed"
        return 1
    fi

    mount /dev/mapper/$CRYPT_PARTITION $CWDIR &> /dev/null
    if [ $? != 0 ]; then
        echo "mount failed"
        return 1
    fi

    tar xpf $OCI_TARBALL -C $CWDIR
    if [ $? != 0 ]; then
        echo "error extracting tarball"
        return 1
    fi
}

mkdir -p $CWDIR

TARSIZE=`stat --printf="%s" $OCI_TARBALL`
if [ $? != 0 ]; then
        echo "couldn't get tarball size"
        exit 1
fi

let overcommit=$TARSIZE/4
let DISKSIZE=$TARSIZE+$overcommit
if (( $DISKSIZE < $MIN_DISKSIZE )); then
	DISKSIZE=$MIN_DISKSIZE
fi

echo "OCI tarball size: ${TARSIZE}"
echo "Creating a disk with size: ${DISKSIZE}"

create_encrypted_disk
ret=$?

umount $CWDIR
cryptsetup luksClose $CRYPT_PARTITION

if [ $ret != 0 ]; then
    rm -f $DISK
fi

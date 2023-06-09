#!/usr/bin/env bash

DIRNAME="$(dirname $0)"

DISK="$1"
: "${DEBIAN_RELEASE:=stretch}"
: "${DEBIAN_VERSION:=9.2.1}"
: "${DEBIAN_MIRROR:=http://ftp.debian.org}"
: "${ARCH:=amd64}"
: "${REMOTE_ISO:=https://cdimage.debian.org/debian-cd/current/${ARCH}/iso-cd/debian-${DEBIAN_VERSION}-${ARCH}-netinst.iso}"
ISO_NAME="${REMOTE_ISO##*/}"

usage() {
  cat << EOF
Usage: $0 <disk> <iso>

disk     Disk to use (e.g. /dev/sdb) - will be wiped out

Overriding options via environment variables
DEBIAN_RELEASE  Release of Debian (default: buster)
DEBIAN_VERSION  VERSION of Debian (default: 9.2.1)
DEBIAN_MIRROR   Debian mirror (default: http://ftp.debian.org)
ARCH            Architecture (default: amd64)
EOF
}

[ $# -ne 1 ]     && echo "Please provide required args" && usage && exit 1
[ -z "${DISK}" ] && echo "Please provide a disk"        && usage && exit 1

EFI="${DISK}p2"
ROOT="${DISK}p3"
KEYS="${DISK}p4"

echo "Getting ISO"
wget --continue -O "${DIRNAME}/${ISO_NAME}" "${REMOTE_ISO}"
ISO="${DIRNAME}/${ISO_NAME}"

parted ${DISK} mklabel gpt 
parted ${DISK} mkpart primary fat32 1 2
parted ${DISK} set 1 bios_grub on
parted ${DISK} mkpart primary fat32 2 100
parted ${DISK} mkpart primary ext2 100 600
parted ${DISK} mkpart primary fat32 600 629
parted ${DISK} set 2 boot on

echo "Creating a filesystem on ${EFI}"
mkfs.vfat -F32 "${EFI}"

echo "Creating a filesystem on ${ROOT}"
mkfs.ext2 "${ROOT}"

echo "Creating a filesystem on ${KEYS}"
mkfs.vfat -F32 "${KEYS}"

parted ${DISK} print

mkdir -p /mnt/
mount "${ROOT}" /mnt/
mkdir -p /mnt/boot/efi
mount "${EFI}" /mnt/boot/efi

grub-install --target=x86_64-efi "${DISK}" --efi-directory=/mnt/boot/efi --boot-directory=/mnt/boot

grub-install "${DISK}" --boot-directory=/mnt/boot

echo "Download the initrd image"
mkdir "/mnt/hdmedia-${DEBIAN_RELEASE}"
wget -O "/mnt/hdmedia-${DEBIAN_RELEASE}/vmlinuz" "${DEBIAN_MIRROR}/debian/dists/${DEBIAN_RELEASE}/main/installer-${ARCH}/current/images/hd-media/vmlinuz"
wget -O "/mnt/hdmedia-${DEBIAN_RELEASE}/initrd.gz" "${DEBIAN_MIRROR}/debian/dists/${DEBIAN_RELEASE}/main/installer-${ARCH}/current/images/hd-media/initrd.gz"
mkdir -p /mnt/isos
rsync -aP "${ISO}" /mnt/isos

echo "Create grub config file"
cat << EOF > /mnt/boot/grub/grub.cfg
set timeout_style=menu
set timeout=1
set hdmedia="/hdmedia-${DEBIAN_RELEASE}"
set preseed="/hd-media/preseed"
set iso="/isos/${ISO_NAME}"

menuentry "Debian ${DEBIAN_RELEASE} ${ARCH} auto install" {
  linux  \$hdmedia/vmlinuz iso-scan/filename=\$iso priority=critical auto=true preseed/file=\$preseed/preseed.cfg console=tty0 console=ttyS0,115200n8 DEBIAN_FRONTEND=text DEBCONF_DEBUG=5
  initrd \$hdmedia/initrd.gz
}
EOF

mkdir /mnt/preseed
cat << EOF > /mnt/preseed/debian.preseed
d-i debian-installer/locale           string   en_US
d-i keyboard-configuration/xkb-keymap select   us
d-i console-tools/archs               select   skip-config
d-i time/zone                         string   EU/Paris
d-i netcfg/enable                     boolean  true
d-i hw-detect/load_firmware           boolean  true
d-i passwd/make-user                  boolean  true
d-i passwd/root-password              password root
d-i passwd/root-password-again        password root
d-i netcfg/enable                     boolean  false
d-i clock-setup/utc                   boolean  true
d-i clock-setup/ntp                   boolean  true

# We assume the target computer has only one harddrive.
# In most case the USB Flash drive is attached on /dev/sda
# but sometimes the harddrive is detected before the USB flash drive and
# it is attached on /dev/sda and the USB flash drive on /dev/sdb
# You can set manually partman-auto/disk and grub-installer/bootdev or
# used the early_command option to automatically set the device to use.
d-i partman/early_command string \
    USBDEV=\$(mount | grep hd-media | cut -d" " -f1 | sed "s/\(.*\)./\1/");\
    BOOTDEV=\$(list-devices disk | grep -v \$USBDEV | head -1);\
    debconf-set partman-auto/disk \$BOOTDEV;\
    debconf-set grub-installer/bootdev \$BOOTDEV;

d-i grub-installer/only_debian   boolean true
d-i grub-installer/with_other_os boolean false

# Partioning
d-i partman-auto/method                string  lvm
d-i partman-auto/purge_lvm_from_device boolean true
d-i partman-auto-lvm/new_vg_name       string  sys
d-i partman-lvm/device_remove_lvm      boolean true
d-i partman-lvm/device_remove_lvm_span boolean true
d-i partman-lvm/confirm                boolean true
d-i partman/alignment                  string  optimal
d-i partman-auto-lvm/guided_size       string  max
d-i partman-auto/expert_recipe string           \
    my-scheme ::                                \
        2000 10000 2000 xfs                     \
            \$primary{ }                        \
            \$bootable{ }                       \
            method{ format } format{ }          \
            use_filesystem{ } filesystem{ xfs } \
            mountpoint{ / }                     \
        .                                       \
        100 1000 1000000000 xfs                 \
            \$defaultignore{ }                  \
            \$primary{ }                        \
            method{ lvm }                       \
            vg_name{ sys }                      \
        .                                       \
        8000 512 8000 swap                      \
            \$lvmok{ }                          \
            in_vg{ sys }                        \
            lv_name{ swap }                     \
            method{ swap }                      \
            format{ }                           \
        .                                       \
        8000 1000 10000 usr                     \
            \$lvmok{ }                          \
            in_vg{ sys }                        \
            lv_name{ usr }                      \
            method{ format }                    \
            use_filesystem{ } filesystem{ xfs } \
            mountpoint{ /usr }                  \
            format{ }                           \
        .                                       \
        8000 1000 10000 var                     \
            \$lvmok{ }                          \
            in_vg{ sys }                        \
            lv_name{ var }                      \
            method{ format }                    \
            use_filesystem{ } filesystem{ xfs } \
            mountpoint{ /var }                  \
            format{ }                           \
        .                                       \
        10000 1000 50000 var-docker             \
            \$lvmok{ }                          \
            in_vg{ sys }                        \
            lv_name{ var-docker }               \
            method{ format }                    \
            use_filesystem{ } filesystem{ xfs } \
            mountpoint{ /var/lib/docker }       \
            format{ }                           \
        .                                       \
        2000 1000 2000 tmp                      \
            \$lvmok{ }                          \
            in_vg{ sys }                        \
            lv_name{ tmp }                      \
            method{ format }                    \
            use_filesystem{ } filesystem{ xfs } \
            mountpoint{ /tmp }                  \
            format{ }                           \
        .                                       \
        5000 1000 10000 opt                     \
            \$lvmok{ }                          \
            in_vg{ sys }                        \
            lv_name{ opt }                      \
            method{ format }                    \
            use_filesystem{ } filesystem{ xfs } \
            mountpoint{ /opt }                  \
            format{ }                           \
        .                                       \
        5000 1000 50000 home                    \
            \$lvmok{ }                          \
            in_vg{ sys }                        \
            lv_name{ home }                     \
            method{ format }                    \
            use_filesystem{ } filesystem{ xfs } \
            mountpoint{ /home }                 \
            format{ }                           \
        .

# This makes partman automatically partition without confirmation, provided
# that you told it what to do using one of the methods above.
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition        select  finish
d-i partman/confirm                 boolean true
d-i partman/mount_style             select  uuid

# We don't want use a remote mirror (all stuff we need is on the USB flash drive)
d-i base-installer/install-recommends      boolean false
d-i apt-setup/non-free                     boolean true
d-i apt-setup/contrib                      boolean true
d-i apt-setup/use_mirror                   boolean true
d-i debian-installer/allow_unauthenticated boolean true

# Install a standard debian system (some recommended packages) + openssh-server
tasksel            tasksel/first                     multiselect standard
d-i                pkgsel/include                    string openssh-server
d-i                pkgsel/upgrade                    select none
popularity-contest popularity-contest/participate    boolean false
d-i                finish-install/reboot_in_progress note
EOF

sync

umount /mnt/boot/efi
umount /mnt/


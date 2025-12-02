#!/bin/bash
## This script is to automate loading of vendor specific docker images
## and installation of configuration files and vendor specific packages
## to debian file system.
##
## USAGE:
##   ./sonic_debian_extension.sh FILESYSTEM_ROOT PLATFORM_DIR
## PARAMETERS:
##   FILESYSTEM_ROOT
##          Path to debian file system root directory

FILESYSTEM_ROOT=$1
[ -n "$FILESYSTEM_ROOT" ] || {
    echo "Error: no or empty FILESYSTEM_ROOT argument"
    exit 1
}

PLATFORM_DIR=$2
[ -n "$PLATFORM_DIR" ] || {
    echo "Error: no or empty PLATFORM_DIR argument"
    exit 1
}

IMAGE_DISTRO=$3
[ -n "$IMAGE_DISTRO" ] || {
    echo "Error: no or empty IMAGE_DISTRO argument"
    exit 1
}

set -x -e

CONFIGURED_ARCH=$([ -f .arch ] && cat .arch || echo amd64)
CONFIGURED_PLATFORM=$([ -f .platform ] && cat .platform || echo generic)

. functions.sh
BUILD_SCRIPTS_DIR=files/build_scripts
BUILD_TEMPLATES=files/build_templates
IMAGE_CONFIGS=files/image_config
SCRIPTS_DIR=files/scripts
DOCKER_SCRIPTS_DIR=files/docker

DOCKER_CTL_DIR=/usr/lib/docker/
DOCKER_CTL_SCRIPT="$DOCKER_CTL_DIR/docker.sh"

# Define target fold macro
FILESYSTEM_ROOT_USR="$FILESYSTEM_ROOT/usr"
FILESYSTEM_ROOT_USR_LIB="$FILESYSTEM_ROOT/usr/lib/"
FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM="$FILESYSTEM_ROOT_USR_LIB/systemd/system"
FILESYSTEM_ROOT_USR_LIB_SYSTEMD_NETWORK="$FILESYSTEM_ROOT_USR_LIB/systemd/network"
FILESYSTEM_ROOT_USR_SHARE="$FILESYSTEM_ROOT_USR/share"
FILESYSTEM_ROOT_USR_SHARE_SONIC="$FILESYSTEM_ROOT_USR_SHARE/sonic"
FILESYSTEM_ROOT_USR_SHARE_SONIC_SCRIPTS="$FILESYSTEM_ROOT_USR_SHARE_SONIC/scripts"
FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES="$FILESYSTEM_ROOT_USR_SHARE_SONIC/templates"
FILESYSTEM_ROOT_USR_SHARE_SONIC_FIRMWARE="$FILESYSTEM_ROOT_USR_SHARE_SONIC/firmware"
FILESYSTEM_ROOT_ETC="$FILESYSTEM_ROOT/etc"
FILESYSTEM_ROOT_ETC_SONIC="$FILESYSTEM_ROOT_ETC/sonic"

GENERATED_SERVICE_FILE="$FILESYSTEM_ROOT/etc/sonic/generated_services.conf"

sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y purge kdump-tools
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot "$FILESYSTEM_ROOT" \
    apt-get -y purge \
    kexec-tools \
    ifmetric \
    bridge-utils \
    vim \
    tcpdump \
    traceroute \
    iputils-ping \
    arping \
    net-tools \
    bsdmainutils \
    efibootmgr \
    iptables-persistent \
    ebtables \
    curl \
    less \
    unzip \
    gdisk \
    sysfsutils \
    screen \
    hping3 \
    tcptraceroute \
    mtr-tiny \
    ipmitool \
    ndisc6 \
    makedumpfile \
    conntrack \
    cron \
    libprotobuf32 \
    libgrpc29 \
    libgrpc++1.51 \
    haveged \
    fdisk \
    gpg \
    linux-perf \
    sysstat \
    xxd \
    wireless-regdb \
    nvme-cli

sudo LANG=C chroot $FILESYSTEM_ROOT pip3 uninstall -y scapy

sudo chroot $FILESYSTEM_ROOT mkdir -p /opt/busybox-bin
sudo chroot $FILESYSTEM_ROOT busybox --install -s /opt/busybox-bin
echo 'export PATH="$PATH:/opt/busybox-bin"' | sudo tee -a $FILESYSTEM_ROOT/etc/profile.d/busybox.sh

sudo chroot $FILESYSTEM_ROOT rm -rf /etc/apparmor.d/local/usr.bin.tcpdump
sudo rm -rf $FILESYSTEM_ROOT/etc/sysctl.d/vmcore-sysctl.conf
sudo rm -rf $FILESYSTEM_ROOT/etc/default/kexec

sudo LANG=C cp $SCRIPTS_DIR/bmc.sh $FILESYSTEM_ROOT/usr/local/bin/bmc.sh
#!/bin/bash

# This is the FriendlyARM NanoPi2 Kali ARM build script - http://nanopi.io/
# A trusted Kali Linux image created by Offensive Security - http://www.offensive-security.com

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [[ $# -eq 0 ]] ; then
    echo "Please pass version number, e.g. $0 2.0"
    exit 0
fi

basedir=`pwd`/nanopi2-$1

# Custom hostname variable
hostname=kali
# Custom image file name variable - MUST NOT include .img at the end.
imagename=kali-linux-$1-

if [ $2 ]; then
    hostname=$2
fi

# Generate a random machine name to be used.
machine=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)

# Make sure that the cross compiler can be found in the path before we do
# anything else, that way the builds don't fail half way through.
export CROSS_COMPILE=arm-linux-gnueabihf-
if [ $(compgen -c $CROSS_COMPILE | wc -l) -eq 0 ] ; then
    echo "Missing cross compiler. Set up PATH according to the README"
    exit 1
fi
# Unset CROSS_COMPILE so that if there is any native compiling needed it doesn't
# get cross compiled.
unset CROSS_COMPILE

# Package installations for various sections.
# This will build a minimal XFCE Kali system with the top 10 tools.
# This is the section to edit if you would like to add more packages.
# See http://www.kali.org/new/kali-linux-metapackages/ for meta packages you can
# use. You can also install packages, using just the package name, but keep in
# mind that not all packages work on ARM! If you specify one of those, the
# script will throw an error, but will still continue on, and create an unusable
# image, keep that in mind.

arm="abootimg cgpt fake-hwclock ntpdate u-boot-tools vboot-utils vboot-kernel-utils"
base="e2fsprogs initramfs-tools kali-defaults kali-menu parted sudo usbutils firmware-linux firmware-atheros firmware-libertas firmware-realtek"
desktop="fonts-croscore fonts-crosextra-caladea fonts-crosextra-carlito gnome-theme-kali gtk3-engines-xfce kali-desktop-xfce kali-root-login lightdm network-manager network-manager-gnome xfce4 xserver-xorg-video-fbdev"
tools="aircrack-ng ethtool hydra john libnfc-bin mfoc nmap passing-the-hash sqlmap usbutils winexe wireshark"
services="apache2 haveged openssh-server"
extras="iceweasel xfce4-terminal wpasupplicant"

packages="${arm} ${base} ${desktop} ${tools} ${services} ${extras}"
architecture="armhf"
# If you have your own preferred mirrors, set them here.
# After generating the rootfs, we set the sources.list to the default settings.
mirror=http.kali.org

# Set this to use an http proxy, like apt-cacher-ng, and uncomment further down
# to unset it.
#export http_proxy="http://localhost:3142/"

mkdir -p ${basedir}
cd ${basedir}

# create the rootfs - not much to modify here, except maybe the hostname.
debootstrap --foreign --arch $architecture kali-rolling kali-$architecture http://$mirror/kali

cp /usr/bin/qemu-arm-static kali-$architecture/usr/bin/

LANG=C systemd-nspawn -M $machine -D kali-$architecture /debootstrap/debootstrap --second-stage
cat << EOF > kali-$architecture/etc/apt/sources.list
deb http://$mirror/kali kali-rolling main contrib non-free
EOF

echo "$hostname" > kali-$architecture/etc/hostname

cat << EOF > kali-$architecture/etc/hosts
127.0.0.1       $hostname    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

cat << EOF > kali-$architecture/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
hwaddress 76:92:d4:85:f3:0f

# This prevents NetworkManager from attempting to use this
# device to connect to wifi, since NM doesn't show which device is which.
# Unfortunately, it still SHOWS the device, just that it's not managed.
iface p2p0 inet manual
EOF

cat << EOF > kali-$architecture/etc/resolv.conf
nameserver 8.8.8.8
EOF

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

#mount -t proc proc kali-$architecture/proc
#mount -o bind /dev/ kali-$architecture/dev/
#mount -o bind /dev/pts kali-$architecture/dev/pts

cat << EOF > kali-$architecture/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF

cat << EOF > kali-$architecture/third-stage
#!/bin/bash
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d

apt-get update
apt-get --yes --allow-change-held-packages install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools u-boot-tools
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
export DEBIAN_FRONTEND=noninteractive
apt-get --yes --allow-change-held-packages install $packages
if [ $? > 0 ];
then
    apt-get --yes --allow-change-held-packages --fix-broken install
fi
apt-get --yes --allow-change-held-packages dist-upgrade
apt-get --yes --allow-change-held-packages autoremove

# Because copying in authorized_keys is hard for people to do, let's make the
# image insecure and enable root login with a password.

sed -i -e 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
update-rc.d ssh enable

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d

rm -f /third-stage
EOF

chmod 755 kali-$architecture/third-stage
LANG=C systemd-nspawn -M $machine -D kali-$architecture /third-stage

cat << EOF > kali-$architecture/cleanup
#!/bin/bash
rm -rf /root/.bash_history
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod 755 kali-$architecture/cleanup
LANG=C systemd-nspawn -M $machine -D kali-$architecture /cleanup

#umount kali-$architecture/proc/sys/fs/binfmt_misc
#umount kali-$architecture/dev/pts
#umount kali-$architecture/dev/
#umount kali-$architecture/proc

# Create the disk and partition it
# We start out at around 3MB so there is room to write u-boot without issues.
echo "Creating image file for NanoPi2"
dd if=/dev/zero of=${basedir}/kali-linux-$1-nanopi2.img bs=1M count=7000
parted kali-linux-$1-nanopi2.img --script -- mklabel msdos
parted kali-linux-$1-nanopi2.img --script -- mkpart primary ext4 4096s 264191s
parted kali-linux-$1-nanopi2.img --script -- mkpart primary ext4 264192s 100%

# Set the partition variables
loopdevice=`losetup -f --show ${basedir}/kali-linux-$1-nanopi2.img`
device=`kpartx -va $loopdevice| sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

# Create file systems
mkfs.ext4 $bootp
mkfs.ext4 -O ^flex_bg -O ^metadata_csum $rootp

# Create the dirs for the partitions and mount them
mkdir -p ${basedir}/bootp ${basedir}/root
mount $bootp ${basedir}/bootp
mount $rootp ${basedir}/root

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${basedir}/kali-$architecture/ ${basedir}/root/

# Serial console settings.
# (No auto login)
echo 'T1:12345:respawn:/sbin/agetty 115200 ttyAMA0 vt100' >> ${basedir}/root/etc/inittab

cat << EOF > ${basedir}/root/etc/apt/sources.list
deb http://http.kali.org/kali kali-rolling main non-free contrib
deb-src http://http.kali.org/kali kali-rolling main non-free contrib
EOF

# Uncomment this if you use apt-cacher-ng otherwise git clones will fail.
#unset http_proxy

git clone --depth 1 https://github.com/offensive-security/gcc-arm-linux-gnueabihf-4.7


# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.
git clone --depth 1 https://github.com/friendlyarm/linux-3.4.y -b nanopi2-lollipop-mr1 ${basedir}/root/usr/src/kernel
cd ${basedir}/root/usr/src/kernel
git rev-parse HEAD > ../kernel-at-commit
touch .scmversion
export ARCH=arm
export CROSS_COMPILE=${basedir}/gcc-arm-linux-gnueabihf-4.7/bin/arm-linux-gnueabihf-
patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/mac80211.patch
# Ugh, this patch is needed because the ethernet driver uses parts of netdev
# from a newer kernel?
patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/0001-Remove-define.patch
cp ${basedir}/../kernel-configs/nanopi2* ..
cp ../nanopi2-vendor.config .config
make -j $(grep -c processor /proc/cpuinfo)
make uImage
make modules_install INSTALL_MOD_PATH=${basedir}/root
# We copy this twice because you can't do symlinks on fat partitions.
# Also, the uImage known as uImage.hdmi is used by uboot if hdmi output is
# detected.
cp arch/arm/boot/uImage ${basedir}/bootp/uImage-720p
cp arch/arm/boot/uImage ${basedir}/bootp/uImage.hdmi
# Friendlyarm suggests staying at 720p for now.
#cp ../nanopi2-1080p.config .config
#make -j $(grep -c processor /proc/cpuinfo)
#make uImage
#cp arch/arm/boot/uImage ${basedir}/bootp/uImage-1080p
#cp ../nanopi2-lcd-hd101.config .config
#make -j $(grep -c processor /proc/cpuinfo)
#make uImage
#cp arch/arm/boot/uImage ${basedir}/bootp/uImage-hd101
#cp ../nanopi2-lcd-hd700.config .config
#make -j $(grep -c processor /proc/cpuinfo)
#make uImage
#cp arch/arm/boot/uImage ${basedir}/bootp/uImage-hd700
#cp ../nanopi2-lcd.config .config
#make -j $(grep -c processor /proc/cpuinfo)
#make uImage
# The default uImage is for lcd usage, so we copy the lcd one twice
# so people have a backup in case they overwrite uImage for some reason.
#cp arch/arm/boot/uImage ${basedir}/bootp/uImage-s70
#cp arch/arm/boot/uImage ${basedir}/bootp/uImage.lcd
#cp arch/arm/boot/uImage ${basedir}/bootp/uImage
make mrproper
cp ../nanopi2-vendor.config .config
make modules_prepare
cd ${basedir}

# FriendlyARM suggest using backports for wifi with their devices, and the
# recommended version is the 4.4.2.
cd ${basedir}/root/usr/src/
#wget https://www.kernel.org/pub/linux/kernel/projects/backports/stable/v4.4.2/backports-4.4.2-1.tar.xz
#tar -xf backports-4.4.2-1.tar.xz
git clone https://github.com/friendlyarm/wireless
cd wireless
cd backports-4.4.2-1
patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/kali-wifi-injection-4.4.patch
cd ..
#cp ${basedir}/../kernel-configs/backports.config .config
#make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j $(grep -c processor /proc/cpuinfo) KLIB_BUILD=${basedir}/root/usr/src/kernel KLIB=${basedir}/root
#make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KLIB_BUILD=${basedir}/root/usr/src/kernel KLIB=${basedir}/root INSTALL_MOD_PATH=${basedir}/root install
#make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KLIB_BUILD=${basedir}/root/usr/src/kernel KLIB=${basedir}/root mrproper
#cp ${basedir}/../kernel-configs/backports.config .config
XCROSS=${basedir}/gcc-arm-linux-gnueabihf-4.7/bin/arm-linux-gnueabihf- ANDROID=n ./build.sh -k ${basedir}/root/usr/src/kernel -c nanopi2 -o ${basedir}/root

cd ${basedir}
mkdir -p ${basedir}/root/lib/firmware/ap6212/
wget https://raw.githubusercontent.com/friendlyarm/android_vendor_broadcom_nanopi2/nanopi2-lollipop-mr1/proprietary/nvram_ap6212.txt -O ${basedir}/root/lib/firmware/ap6212/nvram.txt
wget https://raw.githubusercontent.com/friendlyarm/android_vendor_broadcom_nanopi2/nanopi2-lollipop-mr1/proprietary/fw_bcm43438a0.bin -O ${basedir}/root/lib/firmware/ap6212/fw_bcm43438a0.bin
wget https://raw.githubusercontent.com/friendlyarm/android_vendor_broadcom_nanopi2/nanopi2-lollipop-mr1/proprietary/fw_bcm43438a0_apsta.bin -O ${basedir}/root/lib/firmware/ap6212/fw_bcm43438a0_apsta.bin
wget https://raw.githubusercontent.com/friendlyarm/android_vendor_broadcom_nanopi2/nanopi2-lollipop-mr1/proprietary/bcm43438a0.hcd -O ${basedir}/root/lib/firmware/ap6212/bcm43438a0.hcd
cd ${basedir}

# Fix up the symlink for building external modules
# kernver is used so we don't need to keep track of what the current compiled
# version is
kernver=$(ls ${basedir}/root/lib/modules/)
cd ${basedir}/root/lib/modules/$kernver
rm build
rm source
ln -s /usr/src/kernel build
ln -s /usr/src/kernel source
cd ${basedir}

cp ${basedir}/../misc/zram ${basedir}/root/etc/init.d/zram
chmod 755 ${basedir}/root/etc/init.d/zram

sed -i -e 's/^#PermitRootLogin.*/PermitRootLogin yes/' ${basedir}/root/etc/ssh/sshd_config

# Unmount partitions
umount -l $bootp
umount -l $rootp

# Samsung bootloaders must be signed.
# These are the same steps that are done by
# https://github.com/friendlyarm/sd-fuse_nanopi2/blob/master/fusing.sh

# Download the latest prebuilt from the above url.
mkdir -p ${basedir}/bootloader
cd ${basedir}/bootloader
wget https://raw.githubusercontent.com/friendlyarm/sd-fuse_nanopi2/master/prebuilt/bl1-mmcboot.bin
wget https://raw.githubusercontent.com/friendlyarm/sd-fuse_nanopi2/master/prebuilt/bl_mon.img
wget https://raw.githubusercontent.com/friendlyarm/sd-fuse_nanopi2/master/prebuilt/bootloader.img # This is u-boot
wget https://raw.githubusercontent.com/friendlyarm/sd-fuse_nanopi2/master/prebuilt/loader-mmc.img

dd if=bl1-mmcboot.bin of=$loopdevice bs=512 seek=1
dd if=loader-mmc.img of=$loopdevice bs=512 seek=129
dd if=bl_mon.img of=$loopdevice bs=512 seek=513
dd if=bootloader.img of=$loopdevice bs=512 seek=3841

sync

cd ${basedir}

kpartx -dv $loopdevice
losetup -d $loopdevice

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Clean up the build system"
rm -rf ${basedir}/bootp ${basedir}/root ${basedir}/kali-$architecture ${basedir}/patches ${basedir}/wireless

# If you're building an image for yourself, comment all of this out, as you
# don't need the sha256sum or to compress the image, since you will be testing it
# soon.
echo "Generating sha256sum for kali-linux-$1-nanopi2.img"
sha256sum kali-linux-$1-nanopi2.img > ${basedir}/kali-linux-$1-nanopi2.img.sha256sum
# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing kali-linux-$1-nanopi2.img"
pixz ${basedir}/kali-linux-$1-nanopi2.img ${basedir}/kali-linux-$1-nanopi2.img.xz
echo "Deleting kali-linux-$1-nanopi2.img"
rm ${basedir}/kali-linux-$1-nanopi2.img
echo "Generating sha256sum for kali-linux-$1-nanopi2.img"
sha256sum kali-linux-$1-nanopi2.img.xz > ${basedir}/kali-linux-$1-nanopi2.img.xz.sha256sum
fi

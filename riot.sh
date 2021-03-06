#!/bin/bash

# This is the riot Kali ARM build script - http://www.riotboard.org
# A trusted Kali Linux image created by Offensive Security - http://www.offensive-security.com

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [[ $# -eq 0 ]] ; then
    echo "Please pass version number, e.g. $0 2.0"
    exit 0
fi

basedir=`pwd`/riot-$1

# Custom hostname variable
hostname=kali
# Custom image file name variable - MUST NOT include .img at the end.
imagename=kali-linux-$1-riot

if [ $2 ]; then
    hostname=$2
fi

if [ $3 ]; then
	imagename=$3
fi

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

# Don't add the kernel here.  It depends on flash-kernel which in turn will fail
# when building on amd64, instead we fake a uname/architecture further down and
# actually install the kernel package after compiling it.
arm="abootimg cgpt fake-hwclock ntpdate u-boot-tools vboot-utils vboot-kernel-utils"
base="e2fsprogs initramfs-tools kali-defaults kali-menu parted sudo usbutils firmware-linux firmware-atheros firmware-libertas firmware-realtek"
desktop="fonts-croscore fonts-crosextra-caladea fonts-crosextra-carlito gnome-theme-kali gtk3-engines-xfce kali-desktop-xfce kali-root-login lightdm network-manager network-manager-gnome xfce4 xserver-xorg-video-fbdev"
tools="aircrack-ng ethtool hydra john libnfc-bin mfoc nmap passing-the-hash sqlmap usbutils winexe wireshark"
services="apache2 openssh-server"
extras="iceweasel xfce4-terminal wpasupplicant gcc"

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

# Set hostname
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
iface eth0 inet dhcp
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

cat << 'EOF' > kali-$architecture/lib/systemd/system/regenerate_ssh_host_keys.service
[Unit]
Description=Regenerate SSH host keys
Before=ssh.service
[Service]
Type=oneshot
ExecStartPre=-/bin/dd if=/dev/hwrng of=/dev/urandom count=1 bs=4096
ExecStartPre=-/bin/sh -c "/bin/rm -f -v /etc/ssh/ssh_host_*_key*"
ExecStart=/usr/bin/ssh-keygen -A -v
ExecStartPost=/bin/sh -c "for i in /etc/ssh/ssh_host_*_key*; do actualsize=$(wc -c <\"$i\") ;if [ $actualsize -eq 0 ]; then echo size is 0 bytes ; exit 1 ; fi ; done ; /bin/systemctl disable regenerate_ssh_host_keys"
[Install]
WantedBy=multi-user.target
EOF
chmod 644 kali-$architecture/lib/systemd/system/regenerate_ssh_host_keys.service

# Fake a uname response so that flash-kernel doesn't bomb out.
cat << 'EOF' > kali-$architecture/root/fakeuname.c
#define _GNU_SOURCE
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <stdio.h>
#include <string.h>
/* Fake uname -r because we are in a chroot:
https://gist.github.com/DamnedFacts/5239593
*/
int uname(struct utsname *buf)
{
 int ret;
 ret = syscall(SYS_uname, buf);
 strcpy(buf->release, "4.16.0-kali2-armmp");
 strcpy(buf->machine, "armv7l");
 return ret;
}
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

cd /root && gcc -Wall -shared -o libfakeuname.so fakeuname.c
LD_PRELOAD=/root/libfakeuname.so apt-get --yes --allow-change-held-packages install linux-image-armmp
rm /root/libfakeuname*
cd /

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
echo "Creating image file $imagename.img"
dd if=/dev/zero of=${basedir}/$imagename.img bs=1M count=7000
parted $imagename.img --script -- mklabel msdos
parted $imagename.img --script -- mkpart primary fat32 2048s 264191s
parted $imagename.img --script -- mkpart primary ext4 264192s 100%

# Set the partition variables
loopdevice=`losetup -f --show ${basedir}/$imagename.img`
device=`kpartx -va $loopdevice| sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

# Create file systems
mkfs.vfat $bootp
mkfs.ext4 $rootp

# Create the dirs for the partitions and mount them
mkdir -p ${basedir}/bootp ${basedir}/root
mount $bootp ${basedir}/bootp
mount $rootp ${basedir}/root

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${basedir}/kali-$architecture/ ${basedir}/root/

# Enable serial console access
echo "T1:23:respawn:/sbin/agetty -L ttymxc1 115200 vt100" >> ${basedir}/root/etc/inittab

cat << EOF >> ${basedir}/root/etc/udev/links.conf
M   ttymxc1 c   5 1
EOF

cat << EOF >> ${basedir}/root/etc/securetty
ttymxc1
EOF

cat << EOF > ${basedir}/root/etc/apt/sources.list
deb http://http.kali.org/kali kali-rolling main non-free contrib
deb-src http://http.kali.org/kali kali-rolling main non-free contrib
EOF

# Uncomment this if you use apt-cacher-ng otherwise git clones will fail
#unset http_proxy

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.
#git clone --depth 1 git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git -b linux-4.4.y ${basedir}/root/usr/src/kernel
#cd ${basedir}/root/usr/src/kernel
#git rev-parse HEAD > ../kernel-at-commit
#patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/kali-wifi-injection-4.4.patch
#patch -p1 --no-backup-if-mismatch < ${basedir}/../patches/0001-wireless-carl9170-Enable-sniffer-mode-promisc-flag-t.patch
#touch .scmversion
#export ARCH=arm
#export CROSS_COMPILE=arm-linux-gnueabihf-
#cp ${basedir}/../kernel-configs/riot.config .config
#cp ${basedir}/../kernel-configs/riot.config ../riot.config
#make -j $(grep -c processor /proc/cpuinfo)
#make modules_install INSTALL_MOD_PATH=${basedir}/root
#cp arch/arm/boot/zImage ${basedir}/bootp/
#cp arch/arm/boot/dts/imx6dl-riotboard.dtb ${basedir}/bootp/
#cd ${basedir}

#rm -rf ${basedir}/root/lib/firmware
#cd ${basedir}/root/lib
#git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git firmware
#rm -rf ${basedir}/root/lib/firmware/.git
# Need some firmware from the kernel so..
#cd ${basedir}/root/usr/src/kernel
#make firmware_install INSTALL_MOD_PATH=${basedir}/root
#make mrproper
#cp ../riot.config .config
#make modules_prepare
cd ${basedir}

# Fix up the symlink for building external modules
# kernver is used so we don't need to keep track of what the current compiled
# version is
#kernver=$(ls ${basedir}/root/lib/modules/)
#cd ${basedir}/root/lib/modules/$kernver
#rm build
#rm source
#ln -s /usr/src/kernel build
#ln -s /usr/src/kernel source
#cd ${basedir}

# Mainline u-boot with RIoTboard fixes on top
wget ftp://ftp.denx.de/pub/u-boot/u-boot-2018.05.tar.bz2
tar -xf u-boot-2018.05.tar.bz2
cd u-boot-2018.05
export CROSS_COMPILE=arm-linux-gnueabihf-
make riotboard_config
make -j $(grep -c processor /proc/cpuinfo)
dd if=u-boot.imx of=$loopdevice bs=1024 seek=1
cd ${basedir}

# Generate the bootscript so that u-boot knows where everything is...
cat << __EOF__ > ${basedir}/bootp/bootscript
fdt_high=0xffffffff
initrd_high=0xffffffff

kaddr=0x12000000

loadkernel=load \${dtype} \${disk}:1 \${loadaddr} zImage

bargs=setenv bootargs console=ttymxc1,115200n8 rootwait root=PARTUUID=\${btpart} net.ifnames=0 rootfstype=ext4

loadfdt=load \${dtype} \${disk}:1 0x11000000 \${fdt_file}

doboot=part uuid \${dtype} \${disk}:2 btpart ; run bargs; if run loadkernel; then echo kernel_loaded ; if run loadfdt; then echo fdt_loaded; bootz \${loadaddr} - 0x11000000 ; else echo fail1 ; fi ; fi ; echo failed to boot
__EOF__

cp ${basedir}/../misc/zram ${basedir}/root/etc/init.d/zram
chmod 755 ${basedir}/root/etc/init.d/zram

sed -i -e 's/^#PermitRootLogin.*/PermitRootLogin yes/' ${basedir}/root/etc/ssh/sshd_config

# Unmount partitions
sync
umount -l $bootp
umount -l $rootp
kpartx -dv $loopdevice
losetup -d $loopdevice

# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing $imagename.img"
pixz ${basedir}/$imagename.img ${basedir}/../$imagename.img.xz
rm ${basedir}/$imagename.img
fi

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Removing temporary build files"
rm -rf ${basedir}
#!/bin/bash
# 阶段 1：构建 Debian 12 (bookworm) arm64 rootfs
#   - debootstrap 基础系统（含 non-free-firmware，用于 brcm80211 等固件）
#   - 板级配置：fstab / 串口控制台 / 主机名 / 首启服务（SSH key + 扩容 + swap）
#   - 桌面（XFCE）、浏览器、播放器、中文输入法、NetworkManager、诊断工具
#
# 用法： WORK=/workspace/build ./scripts/01-build-rootfs.sh
# 注意： 需要网络（下载约 1.5 GB）和 root 权限；chroot 不需要 mount。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/config/image.conf"
WORK="${WORK:-/workspace/build}"
R="$WORK/rootfs"
mkdir -p "$WORK"

echo "==> 1/6 debootstrap 基础系统"
if [ ! -x "$R/bin/bash" ]; then
  debootstrap --arch=arm64 --variant=minbase \
    --components=main,non-free-firmware \
    --include=systemd,systemd-sysv,udev,kmod,iproute2,iputils-ping,openssh-server,e2fsprogs,initramfs-tools,cpio,ifupdown,isc-dhcp-client,sudo,less,nano,ca-certificates,gnupg,firmware-brcm80211,zstd,xz-utils \
    bookworm "$R" http://deb.debian.org/debian
fi

echo "==> 2/6 板级配置（主机名 / fstab / 串口控制台）"
echo "$HOSTNAME" > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' "$HOSTNAME" > "$R/etc/hosts"
mkdir -p "$R/boot"
cat > "$R/etc/fstab" <<EOF
UUID=$ROOT_UUID	/	ext4	defaults,noatime,errors=remount-ro	0 1
UUID=1A2B-3C4D	/boot	vfat	defaults,nofail				0 0
EOF

# 串口是 UART2 @1500000。systemd 默认 baud 列表里没有 1.5M，必须用 drop-in 覆盖 ExecStart
grep -qx ttyS2 "$R/etc/securetty" 2>/dev/null || echo ttyS2 >> "$R/etc/securetty"
mkdir -p "$R/etc/systemd/system/serial-getty@ttyS2.service.d" "$R/etc/systemd/system/getty.target.wants"
cat > "$R/etc/systemd/system/serial-getty@ttyS2.service.d/baud.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \u' --keep-baud 1500000,115200,57600,38400,9600 %I $TERM
EOF
ln -sf /lib/systemd/system/serial-getty@.service \
       "$R/etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service"

echo "==> 3/6 首启服务（生成 SSH host key + 根分区扩容 + 2GiB swap）"
mkdir -p "$R/usr/local/sbin" "$R/etc/systemd/system/multi-user.target.wants"
cat > "$R/usr/local/sbin/eaidk-firstboot.sh" <<'EOF'
#!/bin/bash
set -u
# 1) SSH host key（镜像里刻意不预置，避免所有卡共用一个密钥）
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  ssh-keygen -A
fi
# 2) 根分区扩到整张卡
DEV=$(findmnt -n -o SOURCE / || true)
if [ -n "${DEV:-}" ]; then
  DISK=$(lsblk -no PKNAME "$DEV" | head -1)
  PART=${DEV##*[!0-9]}
  if [ -n "${DISK:-}" ]; then
    growpart "/dev/$DISK" "$PART" || true
    resize2fs "$DEV" || true
  fi
fi
# 3) 2 GiB swap（4GB 内存跑桌面/浏览器更稳）
if [ ! -f /swapfile ]; then
  if fallocate -l 2G /swapfile 2>/dev/null; then
    chmod 600 /swapfile
    if mkswap /swapfile >/dev/null 2>&1; then
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      swapon /swapfile 2>/dev/null || true
    fi
  fi
fi
# 4) 只跑一次
systemctl disable eaidk-firstboot.service 2>/dev/null || true
EOF
chmod +x "$R/usr/local/sbin/eaidk-firstboot.sh"
cat > "$R/etc/systemd/system/eaidk-firstboot.service" <<'EOF'
[Unit]
Description=EAIDK-610 first boot: regenerate SSH host keys + expand rootfs + swap
After=local-fs.target
Before=ssh.service
ConditionPathExists=/usr/local/sbin/eaidk-firstboot.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/eaidk-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/eaidk-firstboot.service \
       "$R/etc/systemd/system/multi-user.target.wants/eaidk-firstboot.service"

echo "==> 4/6 chroot 内安装软件包"
cp -L /etc/resolv.conf "$R/etc/resolv.conf"
cat > "$R/tmp/preseed.txt" <<'EOF'
tzdata tzdata/Areas select Asia
tzdata tzdata/Zones/Asia select Shanghai
keyboard-configuration keyboard-configuration/layoutcode select us
keyboard-configuration keyboard-configuration/modelcode select pc105
keyboard-configuration keyboard-configuration/xkb-keymap select us
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8, zh_CN.UTF-8 UTF-8
locales locales/default_environment_locale select zh_CN.UTF-8
EOF
chroot "$R" /bin/bash -e <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections /tmp/preseed.txt
apt-get update -qq
PKGS="locales tzdata console-setup keyboard-configuration
 dbus dbus-x11
 xserver-xorg-core xserver-xorg-input-libinput xinit x11-xserver-utils xauth
 libgl1-mesa-dri libegl1 libgles2 mesa-utils
 xfce4 xfce4-terminal xfce4-power-manager xfce4-notifyd thunar ristretto mousepad
 lightdm lightdm-gtk-greeter
 firefox-esr chromium mpv vlc
 pulseaudio alsa-utils pavucontrol
 fonts-dejavu fonts-wqy-zenhei fonts-noto-cjk
 firmware-misc-nonfree
 udisks2 polkitd pkexec lxpolkit cloud-guest-utils
 fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk2 fcitx5-frontend-qt5
 fcitx5-config-qt fcitx5-modules im-config
 network-manager network-manager-gnome wpasupplicant iw rfkill
 ethtool net-tools v4l-utils htop unzip zip"
# bookworm 里并非所有包都存在（例如 xfce-polkit），先过滤，避免 apt 整体失败
AVAIL=""
for p in $PKGS; do
  if apt-cache show "$p" >/dev/null 2>&1; then AVAIL="$AVAIL $p"; else echo ">>> 跳过不存在的包: $p"; fi
done
apt-get install -y --no-install-recommends $AVAIL

# --- 账户 ---
useradd -m -s /bin/bash -G sudo debian 2>/dev/null || true
echo 'root:root'   | chpasswd
echo 'debian:debian' | chpasswd

# --- 中文输入法环境 ---
im-config -n fcitx5 || true
grep -q GTK_IM_MODULE /etc/environment || cat >> /etc/environment <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
# Debian 的 fcitx5 包不带 XDG autostart 文件，自己补一个
cat > /etc/xdg/autostart/fcitx5.desktop <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Fcitx 5
Comment=Start Input Method
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
Categories=System;Utility;
X-GNOME-Autostart-Phase=Applications
X-GNOME-Autostart-Notify=true
EOF
# 默认输入法：拼音
mkdir -p /etc/skel/.config/fcitx5 /home/debian/.config/fcitx5
cat > /etc/skel/.config/fcitx5/profile <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF
cp /etc/skel/.config/fcitx5/profile /home/debian/.config/fcitx5/profile

# --- NetworkManager 接管有线；ifupdown 只管 lo（否则 NM 会把 eth0 视为 unmanaged）---
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-eaidk.conf <<'EOF'
[main]
rc-manager=file
EOF
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
EOF
cat > /etc/network/interfaces.fallback <<'EOF'
# 备用：NetworkManager 不正常时覆盖回 /etc/network/interfaces 并 systemctl restart networking
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF
ln -sf /lib/systemd/system/NetworkManager.service \
       /etc/systemd/system/multi-user.target.wants/NetworkManager.service

# --- 图形启动 ---
ln -sf /lib/systemd/system/graphical.target /etc/systemd/system/default.target
ln -sf /lib/systemd/system/lightdm.service  /etc/systemd/system/display-manager.service
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone
locale-gen
CHROOT

# /home/debian 的属主必须是 1000:1000（容器里没有 debian 用户，不能用名字 chown）
chown -R 1000:1000 "$R/home/debian"

echo "==> 5/6 驱动加载保险"
mkdir -p "$R/etc/modules-load.d"
printf 'dwmac-rk\nrealtek\n' > "$R/etc/modules-load.d/eaidk-net.conf"

echo "==> 6/6 镜像卫生（清缓存 / machine-id / SSH host key）"
rm -f "$R/var/cache/apt/archives/"*.deb
rm -rf "$R/var/lib/apt/lists/"*
: > "$R/etc/machine-id"
rm -f "$R/etc/ssh/ssh_host_"*
rm -f "$R/tmp/preseed.txt"

echo "完成：$R ($(du -sh "$R" | cut -f1), $(find "$R" | wc -l) 文件)"
#!/bin/bash
# 阶段 2：安装 Debian 内核 + 设备树 + 模块，并生成 initramfs
#
# 两个关键点：
#   1) linux-image 包里的 /boot/vmlinuz-<ver> 本身就是**裸 arm64 Image**
#      （file 显示 "Linux kernel ARM64 boot executable Image"，不是 EFI-zboot 压缩包），
#      所以 u-boot 可以直接 booti，不需要额外解包。
#   2) **必须生成 initramfs**：Debian 内核里 ext4 / mmc_dw / sdhci_of_arasan 全是 =m，
#      没有 initramfs 会 panic 在 "VFS: Unable to mount root fs"。
#
# 用法： WORK=/workspace/build ./scripts/02-install-kernel.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/config/image.conf"
WORK="${WORK:-/workspace/build}"
R="$WORK/rootfs"
cd "$WORK"

echo "==> 1/5 取 Debian 内核包并解包"
if ! ls "${KERNEL_DEB}"_*.deb >/dev/null 2>&1; then
  apt-get download "$KERNEL_DEB"
fi
DEB=$(ls -1 "${KERNEL_DEB}"_*.deb | head -1)
rm -rf kernroot && mkdir kernroot && dpkg-deb -x "$DEB" kernroot

echo "==> 2/5 准备启动分区素材（Image / dtb）"
mkdir -p bootstage/dtb/rockchip
cp "kernroot/boot/vmlinuz-$KVER" bootstage/Image
cp "kernroot/usr/lib/linux-image-$KVER/rockchip/$BOARD_DTB" bootstage/dtb/rockchip/

# 用修正过的设备树（rgmii-id）作为默认；上游原样留一份做回退
if [ -f "$HERE/dts/rk3399-eaidk-610-rgmii-id.dtb" ]; then
  cp "$HERE/dts/rk3399-eaidk-610-rgmii-id.dtb"      "bootstage/dtb/rockchip/$BOARD_DTB"
  cp "$HERE/dts/rk3399-eaidk-610-rgmii-MACdelay.dtb" "bootstage/dtb/rockchip/rk3399-eaidk-610-rgmii-macdelay.dtb"
fi
file bootstage/Image
echo "（上面应显示: Linux kernel ARM64 boot executable Image）"

echo "==> 3/5 内核模块 + depmod + initramfs"
rm -rf "$R/lib/modules/$KVER"
mkdir -p "$R/lib/modules" "$R/boot"
cp -a "kernroot/lib/modules/$KVER" "$R/lib/modules/"
cp "kernroot/boot/config-$KVER" "$R/boot/"
cp -L /etc/resolv.conf "$R/etc/resolv.conf"
chroot "$R" /bin/bash -e <<CHROOT
depmod $KVER
mkinitramfs -o /boot/initrd.img-$KVER $KVER
CHROOT
cp "$R/boot/initrd.img-$KVER" bootstage/

echo "==> 4/5 生成 extlinux.conf"
cat > bootstage/extlinux.conf <<EOF
default debian

label debian
    kernel /Image
    fdt /dtb/rockchip/$BOARD_DTB
    initrd /initrd.img-$KVER
    append root=UUID=$ROOT_UUID $CMDLINE
EOF
cat bootstage/extlinux.conf

echo "==> 5/5 完成"
ls -la bootstage bootstage/dtb/rockchip
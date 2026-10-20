#!/bin/bash
# 阶段 3：构建 u-boot（产出 idbloader.img + u-boot.itb）
#
# 说明：
#   - 主线 u-boot 原生支持本板（configs/eaidk-610-rk3399_defconfig，v2023.01 起就有）
#   - DDR 配置由 arch/arm/dts/rk3399-eaidk-610-u-boot.dtsi 决定：
#     rk3399-sdram-lpddr3-4GB-1600.dtsi  → 本板是 4GB LPDDR3，实测正确
#     若换成 LPDDR4 的板子，同目录下有 lpddr4-100 / lpddr3-2GB-1600 等可选
#   - BL31 直接取 Debian 的 arm-trusted-firmware 包（含 rk3399/bl31.elf）
#   - 容器是原生 aarch64，本地编译即可，不需要交叉工具链
#
# 构建依赖（踩过的坑，别用 --no-install-recommends 装 gcc）：
#   build-essential libc6-dev python3-setuptools python3-dev swig libssl-dev \
#   libgnutls28-dev bison flex bc libelf-dev
#
# 用法： WORK=/workspace/build ./scripts/03-build-uboot.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/config/image.conf"
WORK="${WORK:-/workspace/build}"
cd "$WORK"

echo "==> 1/4 取 u-boot 源码"
if [ ! -d "u-boot-$UBOOT_VER" ]; then
  curl -L "https://codeload.github.com/u-boot/u-boot/tar.gz/refs/tags/$UBOOT_VER" -o u-boot.tar.gz
  tar xzf u-boot.tar.gz
fi

echo "==> 2/4 取 BL31"
if [ ! -f atf/usr/lib/arm-trusted-firmware/rk3399/bl31.elf ]; then
  mkdir -p atf
  apt-get download arm-trusted-firmware
  dpkg-deb -x arm-trusted-firmware_*.deb atf
fi
BL31="$PWD/atf/usr/lib/arm-trusted-firmware/rk3399/bl31.elf"
ls -la "$BL31"

echo "==> 3/4 配置 + 编译"
cd "u-boot-$UBOOT_VER"
make "$UBOOT_DEFCONFIG"
# 自检：这些必须为 y，否则 u-boot 扫不到 FAT 启动分区 / 不认 extlinux
grep -E 'CONFIG_(BOOTSTD|BOOTSTD_DEFAULTS|BOOTMETH_EXTLINUX|FS_FAT|CMD_BOOTI)=' .config
make -j"$(nproc)" BL31="$BL31"

echo "==> 4/4 产物"
ls -la idbloader.img u-boot.itb
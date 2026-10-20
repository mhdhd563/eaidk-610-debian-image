#!/bin/bash
# 阶段 4：编译 Debian 内核漏编的 RT5651 codec 模块
#
# 背景（实测确认）：
#   Debian 6.1 内核配置里**根本没有 CONFIG_SND_SOC_RT5651 这一项**
#   （RT5640/RT5645/RT5682 等都编了，唯独漏了 RT5651）。
#   设备树里那张 simple-audio-card 是 "realtek,rt5651" + rockchip I2S，
#   缺 codec 半边 → 整张声卡注册不起来 → 板载 3.5mm 耳机孔无声。
#
# 做法：
#   用 Debian 的 linux-headers（含 Module.symvers，保证 modversions CRC 匹配）
#   把上游同版本内核的 rt5651.c 编成外部模块，装进 /lib/modules/<ver>/extra/。
#   vermagic 必须与运行内核完全一致，否则加载会失败。
#
# 用法： WORK=/workspace/build ./scripts/04-build-rt5651-module.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/config/image.conf"
WORK="${WORK:-/workspace/build}"
R="$WORK/rootfs"

echo "==> 1/5 安装内核头文件（提供 Module.symvers，modversions 必需）"
apt-get install -y "linux-headers-$KVER" libelf-dev
ls -la "/usr/src/linux-headers-$KVER/Module.symvers" || {
  echo "!! 找不到 Module.symvers，modversions 内核会拒绝加载外部模块"; exit 1; }

echo "==> 2/5 取上游源码（与内核同版本 $LINUX_TAG）"
mkdir -p "$WORK/rt5651" && cd "$WORK/rt5651"
for f in rt5651.c rt5651.h rl6231.h; do
  curl -sL "https://raw.githubusercontent.com/gregkh/linux/$LINUX_TAG/sound/soc/codecs/$f" -o "$f"
done
wc -l rt5651.c rt5651.h rl6231.h

echo "==> 3/5 编译"
printf 'obj-m := snd-soc-rt5651.o\nsnd-soc-rt5651-y := rt5651.o\n' > Makefile
make -C "/usr/src/linux-headers-$KVER" M="$PWD" modules
modinfo snd-soc-rt5651.ko | grep -E '^(filename|description|vermagic|depends|alias)'

echo "==> 4/5 安装进 rootfs"
install -D -m644 snd-soc-rt5651.ko "$R/lib/modules/$KVER/extra/snd-soc-rt5651.ko"
mkdir -p "$R/etc/modules-load.d"
echo 'snd-soc-rt5651' > "$R/etc/modules-load.d/eaidk-audio.conf"
chroot "$R" depmod "$KVER"
# 确认 OF 自动加载别名已生成（设备树 compatible = "realtek,rt5651"）
grep -i 'realtek,rt5651' "$R/lib/modules/$KVER/modules.alias" || {
  echo "!! modules.alias 里没有 rt5651 别名"; exit 1; }

echo "==> 5/5 完成"
echo "依赖模块（镜像里应已存在）："
for m in snd-soc-core snd-soc-rl6231 snd-pcm; do
  find "$R/lib/modules/$KVER" -name "$m.ko" | head -1
done
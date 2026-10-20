#!/bin/bash
# 阶段 5：把各部件拼成整盘镜像（全程不需要 mount / loop）
#
# 原理（构建环境没有 CAP_SYS_ADMIN 时的通用做法）：
#   1) ext4  : mke2fs -d <目录>  直接把目录树写进文件系统镜像，不需要挂载
#   2) FAT32 : mkfs.vfat -C 生成文件镜像 + mtools(mcopy/mmd) 免挂载写入
#   3) 分区  : sgdisk 可以直接操作普通文件（会同时写主/备 GPT）
#   4) 拼接  : dd seek=<扇区> 把各段写到正确偏移
#
# 用法： WORK=/workspace/build ./scripts/05-assemble-image.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/config/image.conf"
WORK="${WORK:-/workspace/build}"
R="$WORK/rootfs"
IMG="${IMG:-$WORK/out.img}"
cd "$WORK"

echo "==> 0/5 计算镜像体积"
USED_MIB=$(du -sm "$R" | cut -f1)
P2_MIB=$(( USED_MIB + ROOT_EXTRA_MIB )); P2_MIB=$(( (P2_MIB + 255) / 256 * 256 ))
IMG_MIB=$(( P2_START_MIB + P2_MIB ))
echo "    rootfs 占用 ${USED_MIB}MiB → 根分区 ${P2_MIB}MiB → 镜像总计 ${IMG_MIB}MiB"

echo "==> 1/5 GPT 分区表"
rm -f "$IMG" "$WORK/boot.fat" "$WORK/root.ext4"
truncate -s "${IMG_MIB}M" "$IMG"
# 注意：sgdisk 的区间是“闭区间”，-n1:16MiB:272MiB 会把 272MiB 这个扇区算进 p1，
#       与 p2 的起点重叠 → sgdisk 直接拒绝保存。必须用 “起始+大小” 语法。
sgdisk -n1:${P1_START_MIB}MiB:+${P1_SIZE_MIB}MiB -t1:ef00 -c1:armbi_boot \
       -n2:${P2_START_MIB}MiB:0                  -t2:8300 -c2:armbi_root "$IMG"
sgdisk -p "$IMG"

P2SEC=$(sgdisk -i 2 "$IMG" | awk -F': *' '/Partition size/{print $2}' | awk '{print $1}')
[ -n "$P2SEC" ] || { echo "!! 拿不到 p2 扇区数"; exit 1; }
ROOT_SIZE=$(( (P2SEC - 2048) * 512 ))     # 留 1MiB 余量，确保不越过分区末尾
echo "    root.ext4 = $(( ROOT_SIZE / 1024 / 1024 )) MiB"

echo "==> 2/5 FAT32 启动分区（${P1_SIZE_MIB}MiB）"
mkfs.vfat -F32 -n "$BOOT_LABEL" -i "$BOOT_VOLID" -C "$WORK/boot.fat" $(( P1_SIZE_MIB * 1024 )) >/dev/null
mcopy -i "$WORK/boot.fat" bootstage/Image ::/Image
mmd   -i "$WORK/boot.fat" ::/dtb ; mmd -i "$WORK/boot.fat" ::/dtb/rockchip
mcopy -i "$WORK/boot.fat" bootstage/dtb/rockchip/* ::/dtb/rockchip/
mmd   -i "$WORK/boot.fat" ::/extlinux
mcopy -i "$WORK/boot.fat" bootstage/extlinux.conf ::/extlinux/extlinux.conf
mcopy -i "$WORK/boot.fat" "bootstage/initrd.img-$KVER" "::/initrd.img-$KVER"
mdir  -i "$WORK/boot.fat" ::/

echo "==> 3/5 ext4 根文件系统（mke2fs -d，免挂载）"
truncate -s "$ROOT_SIZE" "$WORK/root.ext4"
# -i 8192：桌面版 rootfs 有 4 万多个文件，默认 inode 密度偏紧
mke2fs -q -t ext4 -L "$ROOT_LABEL" -U "$ROOT_UUID" -m 1 -i 8192 -F -d "$R" "$WORK/root.ext4"
dumpe2fs -h "$WORK/root.ext4" 2>/dev/null | grep -E 'Filesystem UUID|Filesystem state|Block count|Free blocks|Inode count'

echo "==> 4/5 拼接到镜像"
dd if="u-boot-$UBOOT_VER/idbloader.img" of="$IMG" bs=512 seek=$IDB_SEEK conv=notrunc status=none
dd if="u-boot-$UBOOT_VER/u-boot.itb"    of="$IMG" bs=512 seek=$ITB_SEEK conv=notrunc status=none
dd if="$WORK/boot.fat"                  of="$IMG" bs=512 seek=$(( P1_START_MIB * 2048 )) conv=notrunc status=none
dd if="$WORK/root.ext4"                 of="$IMG" bs=512 seek=$(( P2_START_MIB * 2048 )) conv=notrunc status=none
sync

echo "==> 5/5 完成"
ls -la "$IMG"
du -h --apparent-size "$IMG"
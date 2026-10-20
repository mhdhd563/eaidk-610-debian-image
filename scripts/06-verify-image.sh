#!/bin/bash
# 阶段 6：结构级校验 + 打包
#
# 在没有目标硬件的情况下，把能查的错全部挡住：
#   - 各段载荷从最终镜像里抠出来与源文件逐字节 cmp
#   - 在分区偏移处直接 blkid 探测文件系统
#   - e2fsck / fsck.vfat 只读校验
#   - root=UUID 三方一致性（extlinux.conf / fstab / 实际文件系统）
#   - 最后 gzip + sha256
#
# 用法： WORK=/workspace/build ./scripts/06-verify-image.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/config/image.conf"
WORK="${WORK:-/workspace/build}"
R="$WORK/rootfs"
IMG="${IMG:-$WORK/out.img}"
OUT="${OUT:-$HERE/dist}"
cd "$WORK"

IDB_SEC=$(( ( $(stat -c%s "u-boot-$UBOOT_VER/idbloader.img") + 511 ) / 512 ))
ITB_SEC=$(( ( $(stat -c%s "u-boot-$UBOOT_VER/u-boot.itb")    + 511 ) / 512 ))
FAT_SEC=$(( P1_SIZE_MIB * 2048 ))
ROOT_SIZE=$(stat -c%s root.ext4)

echo "===== 1) GPT 一致性 ====="
sgdisk -v "$IMG"
sgdisk -p "$IMG" | tail -4

echo; echo "===== 2) 各段载荷逐字节比对 ====="
dd if="$IMG" bs=512 skip=$IDB_SEEK  count=$IDB_SEC  status=none | cmp - "u-boot-$UBOOT_VER/idbloader.img" && echo "idbloader.img  OK"
dd if="$IMG" bs=512 skip=$ITB_SEEK  count=$ITB_SEC  status=none | cmp - "u-boot-$UBOOT_VER/u-boot.itb"    && echo "u-boot.itb     OK"
dd if="$IMG" bs=512 skip=$(( P1_START_MIB * 2048 )) count=$FAT_SEC status=none | cmp - boot.fat           && echo "FAT 启动分区   OK"
dd if="$IMG" bs=512 skip=$(( P2_START_MIB * 2048 )) count=$(( ROOT_SIZE / 512 )) status=none | cmp - root.ext4 && echo "根文件系统     OK"

echo; echo "===== 3) 在最终镜像的分区偏移处探测文件系统 ====="
blkid -p -O $(( P1_START_MIB * 1024 * 1024 )) "$IMG"
blkid -p -O $(( P2_START_MIB * 1024 * 1024 )) "$IMG"

echo; echo "===== 4) 文件系统只读校验 ====="
e2fsck -fn root.ext4 2>&1 | tail -3
fsck.vfat -n boot.fat | tail -2

echo; echo "===== 5) root=UUID 三方一致性 ====="
echo -n "文件系统  : "; dumpe2fs -h root.ext4 2>/dev/null | awk -F': *' '/Filesystem UUID/{print $2}'
echo -n "extlinux  : "; grep -o 'root=UUID=[0-9a-f-]*' bootstage/extlinux.conf | cut -d= -f2
echo -n "fstab     : "; grep -o '^UUID=[0-9a-f-]*' "$R/etc/fstab" | head -1 | cut -d= -f2
echo -n "期望      : "; echo "$ROOT_UUID"

echo; echo "===== 6) 启动分区内容（从最终镜像里列出） ====="
mdir -i "$IMG@@$(( P1_START_MIB * 1024 * 1024 ))" ::/
mdir -i "$IMG@@$(( P1_START_MIB * 1024 * 1024 ))" ::/extlinux

echo; echo "===== 7) 打包 ====="
mkdir -p "$OUT"
NAME="${NAME:-rk3399-eaidk-610-debian12-$(date +%Y%m%d)}"
gzip -9 -c "$IMG" > "$OUT/$NAME.img.gz"
sha256sum "$OUT/$NAME.img.gz" > "$OUT/$NAME.img.gz.sha256"
sha256sum "$IMG"             > "$OUT/$NAME.img.sha256"
gzip -t "$OUT/$NAME.img.gz" && echo "gzip 完整性 OK"
ls -la "$OUT"
cat "$OUT/$NAME.img.gz.sha256"
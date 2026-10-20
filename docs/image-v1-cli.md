# RK3399 EAIDK-610 · Debian 12 可启动镜像 — 交付说明（v1 精简版）

> ⚠️ 这是**第一版纯命令行镜像**的说明。含桌面环境的**新版（v2）**请看
> [image-v2-xfce.md](image-v2-xfce.md)。
> v2 修正了以太网链路问题（`rgmii-id`），并加入了 XFCE 桌面 / 浏览器 / 播放器。

## 1. 交付物

| 文件 | 大小 | 说明 |
|---|---|---|
| `rk3399-eaidk-610-debian12-6.1.0-53-arm64.img.gz` | 324,191,619 B (309 MiB) | **可直接烧录的镜像**（gzip 压缩） |
| `rk3399-eaidk-610-debian12-6.1.0-53-arm64.img.gz.sha256` | — | 压缩包校验和 |
| `rk3399-eaidk-610-debian12-6.1.0-53-arm64.img.sha256` | — | 解压后 raw 镜像校验和 |

```
gz  sha256  1f24b890286b9e68c5e043ddca5edb06ed56599c15ecbfe656b1247b4ed8725f
raw sha256  b1618bd1d34aa23b2f834b442875c010571f73a0311925feb8ae1ce444765fe1
解压后大小  4,294,967,296 B (4 GiB, 8,388,608 扇区)
```

**这是给 32G microSD 用的**：镜像本身 4 GiB，首次启动会自动把根分区扩到整张卡。

---

## 2. 烧录

**Linux**
```bash
sha256sum -c rk3399-eaidk-610-debian12-6.1.0-53-arm64.img.gz.sha256   # 先验校验和
lsblk                                                                  # 确认哪个是 SD 卡！
gunzip -c rk3399-eaidk-610-debian12-6.1.0-53-arm64.img.gz \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```
⚠️ `of=` 写错就是抹掉你的系统盘，务必先 `lsblk` 确认。**不要往 eMMC 写**（先 SD 验证）。

**Windows**：balenaEtcher 直接选 `.img.gz`（Rufus 需先解压成 `.img`）
**macOS**：`gunzip -c ...img.gz | sudo dd of=/dev/rdiskN bs=4m`

---

## 3. 首次启动

**串口**（唯一可靠的观察窗口）：
```
ttyS2 @ 1500000 8N1，USB-TTL 3.3V
适配器 RX ← 板子 TX，适配器 TX → 板子 RX，GND 共地（不要接 VCC）
picocom -b 1500000 /dev/ttyUSB0
```
⚠️ CH340/PL2303 在 1.5 Mbps 常不稳，建议 CP2102 / FT232 / CH343。

**登录**
```
root / root        ← 请尽快 passwd root 改掉
debian / debian    (带 sudo)
```

**启动链路**
```
BootROM → idbloader.img @32KiB (TPL/SPL, DDR 初始化 LPDDR3-4GB-1600)
        → u-boot.itb @8MiB (BL31 + U-Boot 2024.10)
        → FAT 启动分区 extlinux.conf → Image + rk3399-eaidk-610.dtb + initrd
        → ext4 根分区 (root=UUID=230a0279-8991-4499-8b75-ab2c3a8fdacb)
```

**首启会自动做两件事**（`eaidk-firstboot.service`，只跑一次）
1. 生成 SSH host key（镜像里刻意没预置，避免所有卡共用一个密钥）
2. 把根分区扩到整张卡 —— 之后 `df -h /` 应看到约 29G

**网络**：`eth0` 走 DHCP（`ip a` 查看）。WiFi/BT 见第 6 节。

---

## 4. 分区布局（实际烧进镜像的坐标）

| 偏移 | 大小 | 内容 |
|---|---|---|
| 32 KiB (LBA 64) | 161,792 B | `idbloader.img` |
| 8 MiB (LBA 16384) | 1,023,488 B | `u-boot.itb` |
| 16 MiB (LBA 32768) | 256 MiB | **p1** FAT32 标签 `BOOT`，UUID `1A2B-3C4D` → `Image`、`dtb/rockchip/rk3399-eaidk-610.dtb`、`extlinux/extlinux.conf`、`initrd.img-6.1.0-53-arm64` |
| 272 MiB (LBA 557056) | 3.7 GiB | **p2** ext4 标签 `armbi_root`，UUID `230a0279-8991-4499-8b75-ab2c3a8fdacb` |

要点：DDR 配置用的是主线 `rk3399-sdram-lpddr3-4GB-1600.dtsi`（与你确认的 4GB LPDDR3 一致）；内核是 Debian 6.1.0-53-arm64（`ext4`/`mmc` 驱动都是模块，所以**必须**有 initramfs，已生成 29.9MB 的 zstd initrd）。

---

## 5. 交付前做过的校验（全部通过）

| # | 校验 | 结果 |
|---|---|---|
| 1 | 从最终镜像 `dd` 出三段载荷与源文件 `cmp` | idbloader / u-boot.itb / FAT 分区 **逐字节一致** |
| 2 | 在最终镜像 16MiB 与 272MiB 偏移直接 `blkid -p -O` | 认出 vfat(`1A2B-3C4D`) 与 ext4(`230a0279…`)，UUID 正确 |
| 3 | `e2fsck -fn` 根文件系统 | **干净**：16898 文件，230342/978683 blocks，0 错误 |
| 4 | `fsck.vfat -n` 启动分区 | 通过（8 个文件） |
| 5 | `sgdisk -v` GPT | No problems found |
| 6 | `root=UUID` 三方一致性 | extlinux.conf == fstab == 实际 fs UUID |
| 7 | 根分区段与 `root.ext4` `cmp` | 一致 |
| 8 | `gzip -t` | 通过 |
| 9 | rootfs 冒烟 | bash 5.2 / systemd 252 / sshd 配置 / python3.11 正常；`debian` 用户 uid 1000 存在 |
| 10 | u-boot 配置自检 | `BOOTSTD` + `BOOTMETH_EXTLINUX` + `FS_FAT` + `CMD_BOOTI` 全部就位 |

---

## 6. 已知注意点 / 排错旋钮

按可能性排序：

1. **没有在真机上验证过启动** —— 容器里没有 loop/mount、也没有板子，这是唯一的空白。结构级校验已做到极限，首次上电请看串口。
2. **以太网不通**：主线用 `phy-mode = "rgmii"` + MAC 侧 `tx_delay=0x28 / rx_delay=0x11`；而你那份 v2 厂商 dts 用的是 `phy-mode = "rgmii-id"`。**若网口不亮，第一件事就是把 dtb 改成 `rgmii-id`**（复位脚/PHY 型号两边一致，改动只是延时来源）。
3. **SD vs eMMC 启动优先级**：板子 eMMC 里若已有可引导的 u-boot，可能抢在 SD 前面。串口里 1~2 秒内打断自动启动，然后：
   ```
   mmc list          # 确认 SD 卡编号（本板别名可能是 mmc 1 而非 mmc 0）
   mmc dev <N> ; bootflow scan
   ```
4. **WiFi/BT**：驱动是 Broadcom BCM43455（AP6255）。我放了尽力而为的 NVRAM（把 Debian 里 AMPAK AW-CM256SM 的复制成 `brcmfmac43455-sdio.openailab,eaidk-610.txt`）。**若 WiFi 起不来，从原厂系统的 `/lib/firmware/brcm/` 复制对应 NVRAM 到本机同名路径**即可。不影响启动。
5. **eMMC 的 CQE**：厂商 dts 给 eMMC 加了 `disable-cqe`，主线 dtb 没关。只有 eMMC 报 I/O 超时/错误时才需要回头看这条（这次根分区在 SD 上，不涉及）。
6. **首次 SSH 前确保系统已起完**：host key 是首启生成的，起完之前 sshd 不会监听。

---

## 7. 后续可以做

- **写入 eMMC**：先用这张 SD 启动，确认没问题后，再用板载系统把镜像写到 eMMC（我可以给具体命令；比直接 `dd` 到 eMMC 安全）。
- **桌面/额外软件**：现在是纯命令行 + ssh + python3。要桌面、Docker、ROS 等，我可以在这套流程上加一层。
- **重做镜像**：中间产物全在 `/workspace/build/`（6.5G，可随时删）。关键参数：root UUID `230a0279-…`、启动分区 UUID `1A2B-3C4D`、分区偏移 64 / 16384 / 32768 / 557056。
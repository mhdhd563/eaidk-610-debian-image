# RK3399 EAIDK-610 · Debian 12 + XFCE 桌面镜像 — 交付说明（v2）

> ⚠️ 这是 **v2** 的说明。**最新版 v3**（多了中文输入法、NetworkManager 图形化网络、RT5651 音频修复）请看
> [image-v3-xfce-ime-nm-audio.md](image-v3-xfce-ime-nm-audio.md)。

## 1. 交付物

| 文件 | 大小 | 说明 |
|---|---|---|
| `rk3399-eaidk-610-debian12-xfce-6.1.0-53-arm64.img.gz` | 965,510,614 B (921 MiB) | **本次新镜像**（含桌面，可直接烧录） |
| `rk3399-eaidk-610-debian12-xfce-6.1.0-53-arm64.img.gz.sha256` | — | 压缩包校验和 |
| `rk3399-eaidk-610-debian12-xfce-6.1.0-53-arm64.img.sha256` | — | 解压后 raw 校验和 |
| `rk3399-eaidk-610-debian12-6.1.0-53-arm64.img.gz` | 309 MiB | **上一版精简镜像**（纯命令行，保留备用） |

```
gz  sha256  9a48de85f82bdea4ff53c91f18ce5eb645e73d49ce9512c29d5690f5d63880e1
raw sha256  7025a26e8eee287d18c3140b842f9110d314869901cf0db5e6c11dd709616f42
解压后大小  5,117,050,880 B (4,880 MiB)
```

**给 32G microSD 用**：镜像本身 4.9 GiB，首启自动扩到整张卡。

---

## 1.1 真机验证状态（2026-10-18）

| 项 | 状态 | 说明 |
|---|---|---|
| 引导链（idbloader → u-boot → 内核） | ✅ 真机通过 | 4GB LPDDR3-1600 配置正确 |
| 串口控制台 ttyS2 @1500000 | ✅ 真机通过 | |
| **有线网络 eth0（DHCP / 上网）** | ✅ 真机通过 | `rgmii-id` 修正生效，详见 2.1 |
| 图形界面（lightdm + XFCE，HDMI） | ✅ 真机通过 | |
| 浏览器（Firefox ESR / Chromium） | ✅ 真机通过 | |
| 视频播放器（mpv / VLC） | ✅ 真机通过 | 软件解码可用；硬件解码见第 3 节说明 |
| 首启自动扩容 + swap | ✅ 已生效 | |
| WiFi / 蓝牙（AP6255） | ⚠️ 未验证 | NVRAM 为替身文件，需从原厂系统替换 |
| 硬件视频解码（hantro/rkvdec） | ⚠️ 未验证 | 主线内核无 VA-API，不保证 |
| 从 eMMC 启动 | ⚠️ 未验证 | 目前验证的是从 microSD 启动 |

---

## 2. 本次针对你反馈的两个问题的改动

### 2.1 以太网（`carrier = 0`）—— RGMII 延时模式修正 ★

**诊断过程**：你的现象是"有 `eth0`，但 `carrier = 0`"（链路层就没起来）。我先审计了驱动链，**全部正常**：

- `stmmac` / `stmmac-platform` / `dwmac-rk` 模块都在镜像里，OF 自动加载别名 `of:N*T*Crockchip,rk3399-gmac → dwmac_rk` 正确
- `realtek.ko` 支持本板的 **RTL8211E** PHY
- 驱动读的复位属性（`snps,reset` / `snps,reset-delays-us`）与设备树写法一致
- `PINCTRL_ROCKCHIP=y`、`COMMON_CLK_ROCKCHIP=y`、`MFD_RK808=y` 内建；`i2c-rk3x.ko`、`rk808-regulator.ko` 齐全（PHY 供电 `vcc_lan` 依赖）

**所以问题不在驱动，而在 RGMII 延时来源**：

| | PHY 模式 | MAC 侧延时 |
|---|---|---|
| 你那份**厂商 v2 dts** | `rgmii-id`（延时在 PHY 内） | 不设 |
| **主线 dts**（v1 镜像用的） | `rgmii` | `tx_delay=0x28`, `rx_delay=0x11` |

如果这颗 RTL8211E 的 strapping 本身就在加延时，两边叠加 → 链路起不来，正好是 `carrier = 0`。

**本次镜像已改成厂商写法**：`phy-mode = "rgmii-id"` 且去掉两个 MAC 延时（只改这 3 行，其余与主线 dtb 逐行一致，已验证）。

> ✅ **真机确认（2026-10-18）**：改后 `eth0` 正常获取 IP、可正常上网，`carrier = 0` 的问题已解决。
> 结论：**主线内核的 `rk3399-eaidk-610.dts` 把本板的 `phy-mode` 写错了**（应为 `rgmii-id`，主线却用 `rgmii` + MAC 侧延时）—— 这条对上游内核也有价值，可提 patch。

**如果还是不通**，启动分区里放了回退文件，在板子上一条命令切回去（`/boot` 就是那个 FAT 分区，已挂载）：

```bash
cp /boot/dtb/rockchip/rk3399-eaidk-610-rgmii-macdelay.dtb /boot/dtb/rockchip/rk3399-eaidk-610.dtb
reboot
```

诊断命令（这次装了 `ethtool`）：

```bash
ip -br a
cat /sys/class/net/eth0/carrier
ethtool eth0                      # Link detected / Speed / Duplex
dmesg | grep -iE 'stmmac|dwmac|eth0|Link is|phy'
```

### 2.2 网络栈加固（顺手做的竞态保险）

- `/etc/modules-load.d/eaidk-net.conf`：启动早期就加载 `dwmac-rk`、`realtek`，避免 `ifup` 跑在网卡出现之前
- `/etc/network/interfaces`：`auto eth0` + `allow-hotplug eth0` 双保险

---

## 3. 桌面环境（本次新增）

| 组件 | 内容 |
|---|---|
| 桌面 | **XFCE 4.18**（`xfce4` + `xfce4-terminal` + `thunar` + `xfce4-power-manager` + `xfce4-notifyd` + `ristretto` 看图 + `mousepad` 文本编辑） |
| 登录管理器 | **lightdm** + lightdm-gtk-greeter（开机自动进图形登录界面） |
| 浏览器 | **Firefox ESR** + **Chromium**（两个都装了，可自行删一个） |
| 视频播放 | **mpv** + **VLC** |
| 音频 | PulseAudio + `alsa-utils` + `pavucontrol`（HDMI 音频走 `dw-hdmi-i2s-audio`） |
| 中文字体 | `fonts-noto-cjk` + `fonts-wqy-zenhei` + `fonts-dejavu` |
| 语言/时区 | `LANG=zh_CN.UTF-8`、`Asia/Shanghai`、键盘 `us` |
| 图形栈 | `xserver-xorg-core` + `xserver-xorg-input-libinput` + Mesa（`panfrost_dri.so` 加速 Mali-T860，失败自动退到 `swrast` 软渲） |
| 实用工具 | `ethtool` `net-tools` `v4l-utils` `htop` `unzip` `mesa-utils`（`glxinfo`）`udisks2`（U 盘自动挂载） |
| 启动目标 | `graphical.target`（图形界面），**串口 `ttyS2` 控制台仍然保留**，方便排障 |

**开机流程**：u-boot → 内核 → 图形登录界面（HDMI）。用 `debian / debian` 登录（root 在图形登录界面通常被 PAM 拦，请用 `debian`）。

**关于硬件视频解码**：rk3399 的 VPU 在主线内核下由 `hantro-vpu.ko` / `rockchip-vdec.ko` 驱动，属于 **stateless** V4L2 Request API 接口。

⚠️ **更正**：`mpv --hwdec=v4l2m2m` **不会生效** —— `v4l2m2m` 是给 *stateful* M2M 设备的，而这两个驱动是 stateless，接口对不上。要在这块板上真正用起 VPU，需要额外一层把 stateless 接口包装成 VA-API 的库（`libva-v4l2-request`，Debian 没有这个包），见 v3 说明文档。

浏览器里（YouTube / v.qq.com 等）目前是**纯软件解码**，1080p AV1/HEVC 会把 CPU 打满；这是 mainline 内核没有 VA-API 驱动的固有限制，不是镜像配置问题。厂商 4.4 内核那套 MPP/VAAPI 闭源方案才能完全硬解。想看 GPU 有没有真正启用：`glxinfo -B`（显示 Panfrost/Mali T860 就是启用了；`llvmpipe` 表示退到软渲）。

---

## 4. 烧录 / 登录 / 首启

```bash
sha256sum -c rk3399-eaidk-610-debian12-xfce-6.1.0-53-arm64.img.gz.sha256
lsblk                                     # 确认 SD 卡设备
gunzip -c rk3399-eaidk-610-debian12-xfce-6.1.0-53-arm64.img.gz \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

| 入口 | 参数 / 账号 |
|---|---|
| 串口控制台 | `ttyS2` @ **1500000** 8N1，USB-TTL 3.3V（CH340/PL2303 在 1.5M 常不稳，建议 CP2102/FT232） |
| HDMI | 接显示器 + 键鼠，图形登录界面 |
| 账号 | `debian / debian`（带 sudo）；`root / root`（串口/本地终端） |
| 首启自动做 3 件事 | ① 生成 SSH host key ② 根分区扩到整张卡 ③ 建 2GiB swap（4GB 内存跑浏览器更稳） |

首启之后：`df -h /` 应看到约 29G，`swapon --show` 能看到 2G swap。

**请务必先改密码**：`passwd debian`、`passwd root`。

---

## 5. 分区布局

| 偏移 | 大小 | 内容 |
|---|---|---|
| 32 KiB (LBA 64) | 161,792 B | `idbloader.img` |
| 8 MiB (LBA 16384) | 1,023,488 B | `u-boot.itb` |
| 16 MiB (LBA 32768) | 256 MiB | **p1** FAT32 `BOOT`，UUID `1A2B-3C4D`：`Image`、`dtb/rockchip/rk3399-eaidk-610.dtb`（新的 rgmii-id）、`dtb/rockchip/rk3399-eaidk-610-rgmii-macdelay.dtb`（回退）、`extlinux/extlinux.conf`、`initrd.img-6.1.0-53-arm64` |
| 272 MiB (LBA 557056) | 4.5 GiB | **p2** ext4 `armbi_root`，UUID `230a0279-8991-4499-8b75-ab2c3a8fdacb` |

内核 `6.1.0-53-arm64`（Debian 官方，自带本板 dtb）；u-boot v2024.10（`rk3399-sdram-lpddr3-4GB-1600`，与你确认的 4GB LPDDR3 一致）。

---

## 6. 交付前校验（全部通过）

| # | 校验 | 结果 |
|---|---|---|
| 1 | 四段载荷（idbloader / u-boot.itb / FAT 分区 / 4.6GB 根分区）从最终镜像 `dd` 出来与源文件 `cmp` | **逐字节一致** |
| 2 | 在最终镜像 16MiB / 272MiB 偏移 `blkid -p -O` | vfat `1A2B-3C4D`、ext4 `230a0279…` 正确 |
| 3 | `e2fsck -fn` 根文件系统 | 干净：41244 文件，628311/1179387 blocks，inode 589824（余量充足） |
| 4 | `fsck.vfat -n` | 通过（9 个文件） |
| 5 | `sgdisk -v` | No problems found |
| 6 | `root=UUID` 三方一致 | extlinux.conf == fstab == 实际 fs |
| 7 | `gzip -t` | 通过 |
| 8 | 桌面组件抽查 | `startxfce4` / `lightdm` / `firefox-esr` / `chromium` / `mpv` / `vlc` / `ethtool` 全部就位 |
| 9 | 图形/视频模块 + OF 自动加载别名 | panfrost(`arm,mali-t860`)、rockchipdrm、dw-hdmi、hantro、rockchip-vdec、HDMI 音频 全部齐全 |
| 10 | 中文字体 / locale / 时区 / 启动目标 | `zh_CN.UTF-8` + CJK 字体 + `Asia/Shanghai` + `graphical.target` + `display-manager → lightdm` |

---

## 7. 已知注意点

1. ~~以太网修正未验证~~ → **已解决（真机验证通过）**：主线 `rk3399-eaidk-610.dts` 用 `rgmii` + MAC 侧延时，在本板上导致 `carrier = 0`；改用厂商的 `phy-mode = "rgmii-id"` 后 `eth0` 正常 DHCP、可上网。回退用的 `-rgmii-macdelay.dtb` 仍留在启动分区，可随时切回对比。
2. **WiFi/BT**：NVRAM 仍是尽力而为的替身文件（`brcmfmac43455-sdio.openailab,eaidk-610.txt`）。要真正可用，从原厂系统 `/lib/firmware/brcm/` 复制正确的 NVRAM。另外镜像**没装 NetworkManager**（避免和 ifupdown 抢 eth0），所以 WiFi 暂时只能用命令行 `wpa_supplicant` 配；需要图形化 WiFi 管理我可以再加一版。
3. **root 不能从图形登录界面登录**（PAM 策略），这是正常的；用 `debian` 登录后 `sudo -i`。
4. **SD vs eMMC 启动优先级**：若板子 eMMC 里已有引导，串口里打断自动启动后 `mmc list` 确认编号再 `bootflow scan`。
5. **视频硬解有限**，见第 3 节说明。

---

## 8. 重建

中间产物都在 `/workspace/build/`（约 15G，可删）。关键参数：root UUID `230a0279-8991-4499-8b75-ab2c3a8fdacb`、启动分区 UUID `1A2B-3C4D`、分区偏移 `64 / 16384 / 32768 / 557056`、镜像总大小 4880 MiB。
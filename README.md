# EAIDK-610 (RK3399) · Debian 12 可启动镜像

在 **mainline 内核**上为 **OPEN AI LAB EAIDK-610（RK3399）** 构建可直接烧录到 microSD 的 Debian 12 镜像。

本仓库包含 **构建文档、可复现脚本、设备树修正、一个上游内核补丁**。
镜像本体（`.img.gz`）放在 **Releases** 里，不进 git —— GitHub 单文件上限 100 MiB，而这些镜像是 GB 级。

## 镜像版本

| 版本 | 大小 | 内容 | 说明 |
|---|---|---|---|
| **v4** | 1043 MiB | v3 + **时间同步**（NTP + fake-hwclock，针对无 RTC 电池的板子）+ **PulseAudio 支持 root 桌面** + 音频通路保险 | **推荐** |
| v3 | 1042 MiB | Debian 12 + XFCE + Firefox ESR/Chromium + mpv/VLC + **fcitx5 中文输入法** + **NetworkManager** + **RT5651 音频修复** | 保留 |
| v2 | 921 MiB | Debian 12 + XFCE 桌面（无输入法、无图形化网络管理、无板载音频） | 保留 |
| v1 | 309 MiB | 纯命令行（以太网设备树未修正，**勿用**） | 仅存档 |

**真机验证状态**：引导链 ✅ ｜ 串口控制台 ✅ ｜ 有线网络 ✅ ｜ 图形界面 ✅ ｜ 浏览器 ✅ ｜ 视频播放器 ✅ ｜ 首启扩容+swap ✅ ｜ RT5651 声卡注册 ✅
板载耳机**出不出声 ⚠️ 未验证**（驱动已补；v4 另加了"开机显式打开耳机通路开关"的保险，待上板确认）｜ 时间同步 ⚠️ v4 已内置方案，待上板确认｜ WiFi ⚠️（NVRAM 为替身文件）｜ 视频硬解 ❌（见下）

## 下载镜像

| 版本 | 下载 | 大小 |
|---|---|---|
| **v4（推荐）** | [`.img.gz`](https://github.com/mhdhd563/eaidk-610-debian-image/releases/download/v4/rk3399-eaidk-610-debian12-xfce-v4-6.1.0-53-arm64.img.gz) ｜ [`.sha256`](https://github.com/mhdhd563/eaidk-610-debian-image/releases/download/v4/rk3399-eaidk-610-debian12-xfce-v4-6.1.0-53-arm64.img.gz.sha256) | 1043 MiB |
| v3 | [`.img.gz`](https://github.com/mhdhd563/eaidk-610-debian-image/releases/download/v3/rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.gz) ｜ [`.sha256`](https://github.com/mhdhd563/eaidk-610-debian-image/releases/download/v3/rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.gz.sha256) | 1042 MiB |
| 所有版本 | [Releases 页面](https://github.com/mhdhd563/eaidk-610-debian-image/releases) | — |

## 快速开始

```bash
# 1. 从 Releases 下载对应 .img.gz 和 .sha256
sha256sum -c rk3399-eaidk-610-debian12-xfce-v4-6.1.0-53-arm64.img.gz.sha256

# 2. 烧录（先 lsblk 确认设备！）
gunzip -c rk3399-eaidk-610-debian12-xfce-v4-6.1.0-53-arm64.img.gz \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

| 项 | 值 |
|---|---|
| 串口 | `ttyS2` @ **1500000** 8N1（USB-TTL **3.3V**，RX/TX 交叉，GND 共地） |
| 显示 | HDMI + 键鼠（XFCE 图形登录） |
| 账号 | `debian / debian`（sudo，图形界面用）；`root / root`（串口/本地终端） |
| 首启自动 | 生成 SSH host key → 根分区扩到整张卡 → 建 2 GiB swap |

> 请登录后立刻 `passwd debian`、`passwd root`。

## 仓库结构

```
.
├── README.md
├── LICENSE
├── config/
│   └── image.conf                     # 分区偏移、UUID、版本号等全部参数
├── docs/
│   ├── 01-design-plan.md              # 总体方案（分区布局、免挂载组装原理、风险评估）
│   ├── image-v1-cli.md                # v1 交付说明（纯命令行）
│   ├── image-v2-xfce.md               # v2 交付说明（桌面）
│   ├── image-v3-xfce-ime-nm-audio.md  # v3 交付说明（输入法/网络/音频，含耳机根因分析）
│   └── image-v4-xfce-timesync-pa-root.md  # v4 交付说明（时间同步 / PA root 支持 / 音频保险）
├── dts/
│   ├── rk3399-eaidk-610-rgmii-id.dtb              # 修正后（默认使用）
│   ├── rk3399-eaidk-610-rgmii-MACdelay.dtb        # 上游原样（回退对比用）
│   └── vendor-reference/
│       └── rk3399-eaidk-610-v2-vendor.dtb         # 厂商 v2 设备树（分析参照，勿直接喂给 6.1）
├── patches/
│   └── 0001-arm64-dts-rockchip-eaidk-610-rgmii-id.patch   # 上游补丁
└── scripts/
    ├── 01-build-rootfs.sh             # debootstrap + 板级配置 + 桌面/输入法/网络
    ├── 02-install-kernel.sh           # Debian 内核 + dtb + 模块 + initramfs
    ├── 03-build-uboot.sh              # u-boot（BL31 取自 Debian arm-trusted-firmware）
    ├── 04-build-rt5651-module.sh      # 自编 RT5651 codec 模块（Debian 内核漏编）
    ├── 05-assemble-image.sh           # GPT + FAT + ext4 + dd 拼成整盘镜像
    └── 06-verify-image.sh             # 结构级校验
```

## 关键结论（实测踩坑记录）

1. **以太网：上游设备树写错了 `phy-mode`**
   上游用 `phy-mode = "rgmii"` + MAC 侧 `tx_delay=0x28`/`rx_delay=0x11`，但本板 RTL8211E 的延时是由 PHY 自己产生的（厂商设备树用 `rgmii-id`，且不设 MAC 延时）→ 延时叠加，PHY **链路根本建立不起来**：`eth0` 存在但 `carrier=0`，DHCP 拿不到地址。
   改成 `phy-mode = "rgmii-id"` 并去掉两个延时后恢复正常（真机验证）。补丁：`patches/`。

2. **板载音频：Debian 内核漏编了 RT5651 codec 驱动**
   内核配置里**连 `CONFIG_SND_SOC_RT5651` 这一项都没有**（其他 Realtek codec 都编了）。设备树里那张 `simple-audio-card` 缺 codec 半边 → **整张声卡注册不起来** → 耳机无声。
   解法：用 Debian 的 `linux-headers-6.1.0-53-arm64`（含 `Module.symvers`）把上游 `rt5651.c` 编成外部模块。脚本见 `scripts/04`。
   ⚠️ 主线 rt5651 驱动不支持本板的 `hp-det-gpio`/`spk-con-gpio`，所以**没有插孔自动检测、也不支持外放喇叭**（外放还需要给声卡补 Speaker 通路 + gpio-hog）。

3. **initramfs 必须有**
   Debian 内核的 `ext4`、`mmc_dw`、`sdhci_of_arasan` 都是模块（`=m`），不生成 initramfs 会 `VFS: Unable to mount root fs`。

4. **免挂载组装镜像**
   构建环境没有 `CAP_SYS_ADMIN`（无 `/dev/loop*`、不能 mount），所以全程文件级操作：
   `mke2fs -d <dir>` 直接从目录生成 ext4、`mkfs.vfat -C` + `mtools(mcopy)` 填 FAT、`dd seek` 拼接到分区偏移。

5. **u-boot 构建依赖（三个容易漏的）**
   `libc6-dev`（`gcc` 的 Recommends，用 `--no-install-recommends` 会漏掉 → 报 `sys/types.h` 找不到）、
   `python3-setuptools`（pylibfdt）、`libgnutls28-dev`（mkeficapsule）。

6. **u-boot defconfig 已经够用**
   `eaidk-610-rk3399_defconfig` 自带 `BOOTSTD` / `BOOTMETH_EXTLINUX` / `FS_FAT` / `CMD_BOOTI`，不需要补 config fragment。

7. **sgdisk 分区区间是闭区间**
   `-n1:16MiB:272MiB` 会把结束扇区算在 p1 内，p2 从 272MiB 开始就重叠 → sgdisk 拒绝保存。用 `-n1:16MiB:+256MiB`（起始+大小）。

8. **混音器与输出选择**
   RT5651 耳机通路的 DAPM 开关默认可能是关的（`HPO MIX DAC1 Switch` 等）；另外 PulseAudio 的默认输出容易被 HDMI（板上有 HDMI 声卡）或 USB 耳机抢走。详见 `docs/image-v3-xfce-ime-nm-audio.md` §2.3。

9. **视频硬解做不到（浏览器内）**
   主线内核没有 VA-API 驱动；rk3399 的 VPU（hantro/rkvdec）是 **stateless V4L2**，且**不支持 AV1**（AV1 是 RK3588 才有的）。所以网页视频是纯软解 —— 建议在 `about:config` 里关掉 `media.av1.enabled` 让站点回退到 H.264，并降低分辨率。

10. **时间：没有 RTC 电池的板子必须自带 NTP + fake-hwclock**
    镜像里**一个 NTP 客户端都没有**（`systemd-timesyncd` 是 `systemd` 的 *Recommends*，`--no-install-recommends` 会漏掉）；而板子没有 RTC 电池，内核 `CONFIG_RTC_HCTOSYS=y` 会把空 RTC 的垃圾值读成系统时间。
    只装 timesyncd 还不够 —— 在它校时之前的几秒里，HTTPS 会因证书"尚未生效"报错、日志时间也会错乱。所以还要 `fake-hwclock`（开机先恢复上次保存的时间）+ `FORCE=force`（空 RTC 的值不可信，而默认行为**只会把时钟往前调**，覆盖不了垃圾的未来时间）。
    ⚠️ 另外**镜像里没有 cron**，Debian 默认的 `/etc/cron.hourly/fake-hwclock` 根本不会执行 → 必须自带 systemd 定时器。详见 `docs/image-v4-xfce-timesync-pa-root.md` §1。

11. **PulseAudio 与 root 桌面**
    以 `root` 登录桌面时：喇叭图标永远"连接中"、`pavucontrol` 打不开，**但 USB 耳机却有声音**。
    原因（硬证据）：`/usr/lib/systemd/user/pulseaudio.service` 与 `pulseaudio.socket` 都带 **`ConditionUser=!root`** —— 上游明确拒绝为 root 运行 PA；且 `client.conf` 的 `allow-autospawn-for-root` 默认 `no` → root 会话里没人能拉起 PA。至于"有声"，是播放器**绕过 PA 直接走 ALSA**（能响，但不归 PA 管，所以没有每应用音量/输出切换）。
    修法：`client.conf` 追加 `allow-autospawn-for-root = yes`。**桌面仍建议用 `debian` 登录**。详见 `docs/image-v4-xfce-timesync-pa-root.md` §2。

12. **音频链路：先查驱动，再查混音器**
    v1/v2 耳机无声的根因是**驱动缺失**（Debian 内核没编 `CONFIG_SND_SOC_RT5651` → `simple-audio-card` 缺 codec 半边 → 整张声卡注册不起来），**不是**混音器配置问题。
    判据很简单：`aplay -l` 里有没有那张声卡 —— 没有就是驱动层，有再谈混音器。v4 另加了一个开机服务显式打开耳机通路的 DAPM 开关作为保险。

## 从零构建

```bash
export WORK=/workspace/build          # 建议 40 GB 以上可用空间
./scripts/01-build-rootfs.sh          # ~20 分钟（下载约 1.5 GB）
./scripts/02-install-kernel.sh        # ~2 分钟
./scripts/03-build-uboot.sh           # ~3 分钟（原生 aarch64 编译）
./scripts/04-build-rt5651-module.sh   # ~1 分钟
./scripts/05-assemble-image.sh        # ~5 分钟（mke2fs 填充 2.6 GB）
./scripts/06-verify-image.sh          # ~3 分钟（逐字节比对 + fsck）
```

> 这些脚本是把本次**实际执行过的命令**整理成形的，每条命令都真实跑通过；但**没有在全新环境里端到端复跑**过。第一次跑请留意输出，特别是 `01`（依赖网络）和 `05`（依赖前面的产物）。

## 上游补丁

`patches/0001-arm64-dts-rockchip-eaidk-610-rgmii-id.patch` 修的就是上面第 1 条。上游 master 目前**仍有这个 bug**。

提交前必须做两件事：

1. 把补丁里的 `TODO Your Name <placeholder@example.invalid>` 换成**你本人真实的姓名和邮箱**（`Signed-off-by` 必须由本人签署，不能代签）
2. 用 `git send-email` 发出：

```bash
git send-email \
  --to="Heiko Stuebner <heiko@sntech.de>" \
  --cc="Rob Herring <robh@kernel.org>" \
  --cc="Krzysztof Kozlowski <krzk+dt@kernel.org>" \
  --cc="Conor Dooley <conor+dt@kernel.org>" \
  --cc="Andy Yan <andyshrk@163.com>" \
  --cc="linux-arm-kernel@lists.infradead.org" \
  --cc="linux-rockchip@lists.infradead.org" \
  --cc="devicetree@vger.kernel.org" \
  patches/0001-arm64-dts-rockchip-eaidk-610-rgmii-id.patch
```

（`Andy Yan` 是该设备树的上游作者，按惯例要 Cc 上。）

## 许可

| 目录 | 许可 |
|---|---|
| `scripts/`、`docs/`、`config/` | MIT（见 `LICENSE`） |
| `patches/` | GPL-2.0（内核代码） |
| `dts/` | GPL-2.0 OR MIT（跟随内核设备树） |
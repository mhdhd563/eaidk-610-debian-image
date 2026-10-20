# RK3399 EAIDK-610 可启动镜像制作方案（已核实版）

> 目标板：**RK3399 EAIDK-610（v2）**，OPEN AI LAB
> 产出：可直接 `dd` 到 microSD / eMMC 的可启动整盘镜像 `rk3399-eaidk-610-debian12-<date>.img.gz`
> 状态：**方案已核实，等你确认后开工**（材料见第 7 节）

---

## 0. 相对上一版方案的关键更正

| 项 | 上一版（按 RK35xx 规划） | 现在（已核实） |
|---|---|---|
| 宿主内核能否复用 | 打算复用 `6.1.141-rk35xx-ophub` | **不能**：宿主是 RK35xx，目标板是 RK3399，SoC 不同，内核/u-boot/DTB 全部不通用 |
| 内核从哪来 | 需拉 ophub/Armbian 的 rk35xx deb | **Debian 12 官方 6.1 内核直接够用**，且现成带本板 dtb |
| u-boot 从哪来 | 需找匹配的 u-boot deb | **主线 U-Boot 原生支持本板**，本机原生编译即可（容器是 aarch64） |
| 厂商 SDK 依赖 | — | **不需要**：内核、dtb、BL31 三个关键件全部有 Debian 现成包 |
| `console` | RK35xx 的 `ttyS2,1500000` | 同为 **`ttyS2,1500000`**（EAIDK-610 调试口也是 UART2 @1.5M） |

**结论：这条链路比原方案干净得多 —— 全流程只依赖 Debian 源 + 两个上游源码包，全部可本机离线组装。**

---

## 1. 已核实的事实（带证据，非推测）

| # | 事实 | 证据 |
|---|---|---|
| 1 | Debian 12 内核**自带本板 dtb** | `linux-image-6.1.0-53-arm64`(6.1.187-1) 内含 `rockchip/rk3399-eaidk-610.dtb`（62,875 B）— `dpkg-deb -c` 实测 |
| 2 | Debian 内核镜像**可直接 `booti`** | `/boot/vmlinuz-6.1.0-53-arm64` = `Linux kernel ARM64 boot executable Image, little-endian, 4K pages`，32 MB，**不是** EFI-zboot 压缩包，头部 `MZ`+偏移 56 `ARMd` 魔数正确 |
| 3 | 内核模块随包提供 | 包内 4,556 个 `/lib/modules/6.1.0-53-arm64/...` 条目（含 mmc/网卡等） |
| 4 | 主线 Linux v6.1 有该 dts | `arch/arm64/boot/dts/rockchip/rk3399-eaidk-610.dts`，`model = "OPEN AI LAB EAIDK-610"`，`compatible = "openailab,eaidk-610"` |
| 5 | 主线 U-Boot 原生支持本板 | `configs/eaidk-610-rk3399_defconfig` 在 **v2023.01 与 v2024.10 均存在** |
| 6 | 控制台串口 | u-boot: `DEBUG_UART_BASE=0xFF1A0000`(UART2) + `BAUDRATE=1500000` → 内核 cmdline 需 `console=ttyS2,1500000` |
| 7 | DDR 配置 | `rk3399-eaidk-610-u-boot.dtsi` 引用 `rk3399-sdram-lpddr3-4GB-1600.dtsi` → **4GB LPDDR3-1600** |
| 8 | BL31 现成 | Debian `arm-trusted-firmware` 2.8.0 内含 `/usr/lib/arm-trusted-firmware/rk3399/bl31.elf`（336,984 B）；备选 rkbin `rk3399_bl31_v1.36.elf` |
| 9 | Debian 的 `u-boot-rockchip` 包**不含**本板 | 只含 firefly / nanopc-t4 / nanopi-neo4 / pinebook-pro / puma / roc-pc / rock-pi-4 / rockpro64 等 → **u-boot 必须自己编译** |
| 10 | 网络与工具 | 容器可达 deb.debian.org / github.com / codeload / raw.githubusercontent；e2fsprogs（`mke2fs -d`）已装 |

## 2. 本板硬件画像（摘自主线 dts，便于你核对是不是同一块板）

- **SoC**：RK3399（2×A72 + 4×A53），PMIC **RK808** + SYR827/828（CPU/GPU 供电）
- **存储**：eMMC 8-bit（`sdhci`）、microSD（`sdmmc`，CD 脚 GPIO0_A7）、SDIO WiFi/BT **AP6255**（Broadcom brcmfmac + bcm4345c5，BT 走 `uart0`）
- **网络**：GMAC RGMII + Realtek PHY（复位脚 GPIO3_B7，tx_delay 0x28 / rx_delay 0x11）
- **显示**：HDMI（DDC 走 i2c3）+ PWM0 背光 + VOPB/VOPL
- **音频**：RT5651 + I2S1
- **USB**：USB-C（FUSB302，dwc3-0 角色切换）+ USB2 ×2 + USB3，`vcc5v0_host1/3` 由 GPIO0_A6/B0 控制
- **按键/LED**：Power key GPIO0_A5，5 路 LED（work/user/heartbeat/wlan/bt）
- **调试口**：UART2，**1500000 8N1**

> 如果你的 v2 板在这几处（PHY 复位脚、WiFi 模组、USB 供电脚、DDR 类型）与上面不同，那才需要把你的 dts 差异打进去 —— 见第 3 节。

## 3. 你那份 `rk3399-eaidk-610-v2.dtb` 的分析结论（已做，结论：**不需要用它**）

**文件**：100,498 B，sha256 `dbda2ef0…31af12`，编译时**带 `__symbols__`**（内核构建产物，非手写）。
反编译后与 Debian 自带的 `rk3399-eaidk-610.dtb`（62,875 B，mainline 6.1）逐节点比对：

| 比对维度 | 结果 |
|---|---|
| `model` / `compatible` | **完全一致**：`OPEN AI LAB EAIDK-610` / `openailab,eaidk-610` + `rockchip,rk3399` |
| `status="okay"` 的节点集合 | **40 个 vs 40 个，完全一致（交集 40，双方独有 0）** |
| 全部节点路径集合 | v2 = 593、主线 = 535；差异**全部是 SoC 层（rk3399.dtsi）的厂商/主线差异**，无一个板级外设 |
| ethernet / 三个 mmc / wifi 子节点逐属性 diff | 差异**几乎全是 phandle 重新编号**（等价噪声），真正的值差异只有 2 处，见下 |

只在 v2 侧存在的节点：`ddr_timing`、`nocp-*-msch`、`rkisp1`、`rkisp1`、`rng`、`rkvdec/vepu/vdpu`、`rockchip-suspend`、`rockchip-system-monitor`、`pvtm`、`voppwm`、`__symbols__`、`dsi@ff96*`（主线改名为 `mipi@ff96*`）—— **全是 Rockchip 厂商私有内核的驱动/调频基础设施，不是板级硬件**。

真正的两处值差异：

1. **GMAC 延时方式不同（重要，留作排错旋钮）**
   - 你的 v2：`phy-mode = "rgmii-id"`（延时由 PHY 内部产生，**无** tx/rx_delay）
   - 主线：`phy-mode = "rgmii"` + `tx_delay = 0x28` + `rx_delay = 0x11`（延时由 MAC 产生）
   - 复位脚/供电**相同**（`snps,reset-gpio = <&gpio3 15 ACTIVE_LOW>`、`phy-supply` 一致），PHY 是同一个。
   - 两者是达成同一件事的两种方式。**若首启以太网不通，第一件事就是把主线 dtb 改回 `rgmii-id`**（这也可能是 v2 相对 v1 的真实改动）。
2. **eMMC 的 CQE**：v2 有 `disable-cqe;` + `disable-cqe-dcmd;`，主线没有（其余 `bus-width=8`、`non-removable`、`rockchip,rk3399-sdhci-5.1` 全一致）。一般不影响启动；若 eMMC 出现 I/O 超时再排查。

**决策：走路线 A —— 直接用 Debian 自带的主线 dtb。**
理由：硬件描述一致（同一块板、同一组外设、同一颗 WiFi/PHY/eMMC），而它是为 6.1 主线编译的、有 Debian 与大量 RK3399 板卡的实机背书。
⚠️ **不要**把这份 4.4 厂商 dtb 直接喂给 6.1 内核：`rockchip,ddr-timing`、`nocp-*-msch`、`voppwm`、`rockchip-suspend` 等绑定 6.1 完全不认，属于不受支持且无收益的风险。你的 dtb 保留作**排错参照**即可。
（若日后确认需要移植，就是把上面两条 delta 打回主线 dts 再 `dtc` 重编，成本几分钟。）

⚠️ **仍然注意：设备树管不到 DDR 初始化。** DDR 在 u-boot TPL 里（主线按 `rk3399-sdram-lpddr3-4GB-1600.dtsi`）。dtb 里**既没有 `/memory` 也没有 `/chosen` 节点**（由 u-boot 运行时补），所以**这份 dtb 无法回答 RAM 容量/类型** —— 第一号风险仍然要靠下面第 7 节的信息来排除。

## 4. 镜像布局（RK3399 沿用同一套，已被 Armbian/主线生态验证）

| 偏移 | 大小 | 内容 |
|---|---|---|
| 0 | 17 KiB | GPT |
| **32 KiB**（LBA 64） | ~1 MiB | `idbloader.img`（TPL + SPL，含 DDR 初始化） |
| **8 MiB**（LBA 16384） | ~1 MiB | `u-boot.itb`（BL31 + U-Boot proper + dtb） |
| 16 MiB ~ 272 MiB | 256 MiB | p1 `armbi_boot` **FAT32**：`Image`、`dtb/rockchip/rk3399-eaidk-610.dtb`、`extlinux/extlinux.conf` |
| 272 MiB ~ 末尾 | 剩余 | p2 `armbi_root` **ext4**：Debian 12 rootfs |

两个容易踩的点：

1. **u-boot 环境变量**在 mmc 偏移 `0x3F8000`（≈3.97 MiB，defconfig 里 `CONFIG_ENV_OFFSET`）—— 落在 idbloader 之后的保留区，**不与任何分区冲突**，但别把分区 1 往前挪。
2. **mmc 编号有坑**：内核 aliases 是 `mmc0=sdio0`(WiFi)、`mmc1=sdmmc`(SD)、`mmc2=sdhci`(eMMC)，u-boot 沿用同一套别名 → 插卡启动时 **SD 卡在 u-boot 里很可能是 `mmc 1` 而不是 `mmc 0`**。首次串口调试请用 `mmc list` / `mmc dev` 确认，必要时在 `extlinux.conf` 里用 `devnum` 或写死 `bootcmd`。

## 5. 制作流程（7 个阶段，全程无需 mount）

### 阶段 1 — 装工具
```bash
apt-get update
apt-get install -y --no-install-recommends \
  debootstrap dosfstools mtools fdisk gdisk \
  device-tree-compiler u-boot-tools kmod \
  python3 python3-pyelftools bison flex swig libssl-dev bc \
  make gcc git curl xz-utils ca-certificates rsync file
```

### 阶段 2 — 构建 rootfs（Debian 12 arm64）
```bash
debootstrap --arch=arm64 --variant=minbase \
  --include=systemd,systemd-sysv,udev,kmod,iproute2,openssh-server,e2fsprogs,initramfs-tools \
  bookworm /workspace/build/rootfs http://deb.debian.org/debian
```
- 容器有 `CAP_SYS_CHROOT`，chroot 可用；debootstrap 若因**无法 mount /proc** 报错，回退到零 mount 方案：`apt-get --download-only` 抓包 + `dpkg --root=` 解包 + `chroot` 跑配置（我在阶段 2 会直接处理，不用你介入）。
- 板级定制：`/etc/fstab`（写 p2 的 UUID）、`/etc/hostname`、root 密码或普通用户、`systemctl enable serial-getty@ttyS2`（否则串口看不到登录提示）、SSH、`net.ifnames=0`。

### 阶段 3 — 内核 + 设备树（全部来自 Debian 现成包）
```bash
apt-get download linux-image-6.1.0-53-arm64
dpkg-deb -x linux-image-6.1.0-53-arm64_*.deb /workspace/build/kernel

# 1) 内核：那个 vmlinuz 本身就是裸 arm64 Image，改名 Image 即可直供 booti
cp kernel/boot/vmlinuz-6.1.0-53-arm64  boot/Image

# 2) 设备树
cp kernel/usr/lib/linux-image-6.1.0-53-arm64/rockchip/rk3399-eaidk-610.dtb \
   boot/dtb/rockchip/rk3399-eaidk-610.dtb
#   若走路线 B（用你的 dts）：
#   dtc -I dts -O dtb -@ -o rk3399-eaidk-610.dtb rk3399-eaidk-610-v2.dts

# 3) 模块 + depmod（离线生成 modules.dep）
cp -a kernel/lib/modules/6.1.0-53-arm64 rootfs/lib/modules/
depmod -b rootfs 6.1.0-53-arm64
```
`boot/extlinux/extlinux.conf`：
```
default debian
label debian
    kernel /Image
    fdt /dtb/rockchip/rk3399-eaidk-610.dtb
    append root=UUID=<p2 的 UUID> rootwait rw console=ttyS2,1500000 console=tty0 net.ifnames=0
```

### 阶段 4 — 编译 U-Boot（本机原生 aarch64，约几分钟）
```bash
curl -L https://codeload.github.com/u-boot/u-boot/tar.gz/refs/tags/v2024.10 | tar xz
cd u-boot-2024.10
make eaidk-610-rk3399_defconfig
# 关键自检：确认能读 FAT、能认 extlinux，否则 boot 分区扫不到
grep -E 'CONFIG_(DISTRO_DEFAULTS|BOOTSTD|FS_FAT|CMD_FS_GENERIC|BOOTMETH_EXTLINUX)=' .config
make -j"$(nproc)" BL31=/usr/lib/arm-trusted-firmware/rk3399/bl31.elf
# 产物：idbloader.img、u-boot.itb
```
> 若自检发现 FAT/extlinux 支持缺失，我会追加 `CONFIG_DISTRO_DEFAULTS=y` 之类的 config fragment（必要时再用写死 `bootcmd` 的方式绕开 bootstd，保证一定能引导）。

### 阶段 5 — 离线组装整盘镜像（不 mount、不 loop）
```bash
truncate -s 8G out.img
# GPT 分区表（gdisk/sgdisk 可直接操作普通文件）
sgdisk -n1:16MiB:272MiB -t1:ef00 -c1:armbi_boot \
       -n2:272MiB:0    -t2:8300 -c2:armbi_root out.img

# boot 分区：mkfs.vfat -C 直接生成文件镜像，mtools 免挂载写入
mkfs.vfat -F32 -n boot -C boot.fat 262144          # 256 MiB
mcopy -i boot.fat Image ::/Image
mmd   -i boot.fat ::/dtb ; mmd -i boot.fat ::/dtb/rockchip
mcopy -i boot.fat rk3399-eaidk-610.dtb ::/dtb/rockchip/
mmd   -i boot.fat ::/extlinux
mcopy -i boot.fat extlinux.conf ::/extlinux/extlinux.conf

# root 分区：mke2fs -d 直接吃目录，无需挂载 ★
mke2fs -q -t ext4 -L armbi_root -d rootfs root.ext4 <size>

# 拼接
dd if=idbloader.img of=out.img bs=512 seek=64    conv=notrunc   # 32 KiB
dd if=u-boot.itb    of=out.img bs=512 seek=16384 conv=notrunc   # 8 MiB
dd if=boot.fat      of=out.img bs=512 seek=32768 conv=notrunc   # 16 MiB
dd if=root.ext4     of=out.img bs=512 seek=557056 conv=notrunc  # 272 MiB
```
**UUID 闭环**（容易漏、漏了就不开机）：先 `mke2fs` 出 root.ext4 拿到 UUID → 写进 `extlinux.conf` 的 `root=` 和 rootfs 的 `/etc/fstab` → 再打 FAT 镜像。

### 阶段 6 — 校验（没有硬件，把结构错误挡在这里）
- `sgdisk -v out.img` GPT 一致；分区不重叠不越界
- `e2fsck -fn root.ext4`、`fsck.vfat -n boot.fat`
- `file Image` = arm64 Image；`dtc -I dtb -O dts` 能反编译出 dtb
- 偏移处魔数：`dd if=out.img bs=512 skip=64 count=1 | od -c`（RKSIP/RKNS 头）、`skip=16384`（`d00dfeed` FIT）
- `extlinux.conf` 的 `root=UUID` == `blkid` 读到的 p2 UUID
- u-boot 里 `CONFIG_ENV_OFFSET=0x3F8000` 区域与分区无重叠

### 阶段 7 — 交付
```bash
gzip -9 -k out.img && sha256sum out.img.gz > out.img.gz.sha256
```
附烧录说明：**先烧 microSD 验证**；确认能开机后再用 SD 上的系统写 eMMC（或 `rkdeveloptool`），别一上来就写板载 eMMC。

## 6. 风险清单

| 级别 | 风险 | 应对 |
|---|---|---|
| 🔴 高 | **DDR 类型/容量不符**（主线按 4GB LPDDR3-1600 配置）。若是 2GB 或 LPDDR4，TPL 初始化失败 → 串口无输出、不启动 | 先确认板载 RAM；不符则换 `rk3399-sdram-*.dtsi`（或按芯片手册写时序）重编 u-boot |
| 🟠 中 | u-boot 的 FAT/extlinux 支持没编进去 → 扫不到 boot 分区 | 阶段 4 的 `.config` 自检 + fragment 补齐；兜底写死 `bootcmd` |
| 🟠 中 | mmc 编号（SD 可能是 `mmc 1`）导致 bootcmd 指向错设备 | 串口 `mmc list` 确认；extlinux 由 bootstd 自动扫描可规避 |
| 🟡 低 | 以太网不通：主线用 `rgmii`+MAC 延时，v2 厂商 dts 用 `rgmii-id` | 首启不通就把 dtb 的 `phy-mode` 改回 `rgmii-id`（已备好补丁思路，见第 3 节） |
| 🟡 低 | eMMC CQE：v2 厂商 dts 关了，主线没关 | 仅当 eMMC 报 I/O 超时才排查 CQE |
| 🟡 低 | WiFi/BT 需要 AP6255(BCM43455) 固件与板级 NVRAM | 装 `firmware-brcm80211`；若缺 NVRAM 用 SDK 里的 `brcmfmac43455-sdio*.txt` 补。**只影响 WiFi/BT，不影响启动** |
| 🟡 低 | 容器不能实机验证 | 结构级校验 + 你上真机串口验证；**先 SD 后 eMMC** |
| 🟡 低 | 无 `CAP_SYS_ADMIN`（无 mount/loop） | 全程用 `mke2fs -d` / `mkfs.vfat -C` + `mtools` / `dd seek` 组装 |

## 7. 需要你确认/提供

| # | 事项 | 为什么需要 | 状态 |
|---|---|---|---|
| 1 | ~~你那份 dts 的内容~~ | 已完成分析，结论：**用 Debian 主线 dtb，不需要它** | ✅ 已收到并分析 |
| 2 | **板载 RAM 容量**（现有系统上 `free -h`）；最好连 RAM 芯片丝印 | 决定 DDR 配置，第一号风险；dtb 里查不到 | ✅ **仍缺** |
| 3 | **目标介质与容量**（microSD / eMMC，8G/16G/32G…） | 定镜像大小与分区 | ✅ **仍缺** |
| 4 | rootfs 需求：主机名、用户名/密码、是否装桌面、是否要 SSH | 阶段 2 定制 | ⭕ 可选 |
| 5 | 是否已有串口线（USB-TTL，1.5 Mbps） | 首次启动排错基本靠它 | ⭕ 可选 |
| 6 | 可选加分项：SDK 里 u-boot 的 `rk3399-sdram-*.dtsi` 或现成 `idbloader.img`/`u-boot.itb` | 直接消除第 2 项的风险（可与主线交叉验证 DDR 配置） | ⭕ 可选 |
| 7 | 可选加分项：SDK 里的 AP6255 NVRAM 文件（`brcmfmac43455-sdio*.txt` 之类） | 决定 WiFi/BT 能否用 | ⭕ 可选 |

## 8. 预估

- 材料齐 → 从零到 `img.gz`：**约 1~1.5 小时**（大头是 debootstrap 与 u-boot 编译）
- 若走路线 A（不需要你的 dts 差异）：内核/dtb 零编译成本
- 唯一需要你在真机上做的事：烧 SD、接串口、看是否起得来（我给出排错清单）
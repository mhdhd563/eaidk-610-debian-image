# RK3399 EAIDK-610 · Debian 12 + XFCE 镜像 v3 — 交付说明

## 1. 交付物

| 文件 | 大小 | 说明 |
|---|---|---|
| `rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.gz` | 1,092,489,833 B (1042 MiB) | **本版镜像**：桌面 + 输入法 + 网络图形化管理 + 音频修复 |
| `rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.gz.sha256` | — | 压缩包校验和 |
| `rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.sha256` | — | 解压后 raw 校验和 |

```
gz  sha256  9a09b4fedd7995db1e75711c9f63d8782771e79218968491827defb004e14e46
raw sha256  a011f89a49509cfce4f7f546c85a095c456d0f3f6cce01177fec69eeddf3e331
解压后大小  5,385,486,336 B (5136 MiB)
```

**版本历史**

| 版本 | 大小 | 内容 |
|---|---|---|
| v1 | 309 MiB | 纯命令行（以太网 dtb 是坏的，**勿用**） |
| v2 | 921 MiB | + XFCE 桌面 / Firefox / Chromium / mpv / VLC，修好以太网 |
| **v3** | **1042 MiB** | v2 + **中文输入法** + **NetworkManager 图形化管理** + **RT5651 音频修复** |

---

## 2. 本版新增

### 2.1 中文输入法（fcitx5 + 拼音）

| 项 | 内容 |
|---|---|
| 组件 | `fcitx5`、`fcitx5-chinese-addons`（libpinyin 引擎）、GTK3/GTK2/Qt5 前端、`fcitx5-config-qt` |
| 框架选择 | `im-config -n fcitx5`（已写入 `/etc/X11/xinit/xinputrc`） |
| 环境变量 | `/etc/environment`：`GTK_IM_MODULE=fcitx`、`QT_IM_MODULE=fcitx`、`XMODIFIERS=@im=fcitx` |
| 自启 | `/etc/xdg/autostart/fcitx5.desktop`（Debian 的 fcitx5 包没带这个文件，是我补的） |
| 默认输入法 | 拼音设为默认首选：`/etc/skel/.config/fcitx5/profile` + `/home/debian/.config/fcitx5/profile` |

**用法**：登录后在任意输入框按 **Ctrl+Space** 切换中英；托盘有 fcitx5 图标（右键可配）；要调设置运行 `fcitx5-configtool`。

> 首次登录后如果托盘图标没出来，注销重登一次（会话级配置在首次登录时才完全建立）。

### 2.2 网络图形化管理（NetworkManager）

- 装了 `network-manager` + `network-manager-gnome`（**nm-applet 自启，出现在 XFCE 通知区**），以及 `wpasupplicant`/`iw`/`rfkill`
- **eth0 改由 NetworkManager 接管**：`/etc/network/interfaces` 只剩 `lo`。
  这一步是必须的 —— NM 的 ifupdown 插件会把写在该文件里的接口标成 unmanaged，那样界面上就管不了 eth0。
- `/etc/NetworkManager/conf.d/10-eaidk.conf`：`rc-manager=file`（NM 直接写 `/etc/resolv.conf`，不依赖 resolvconf/systemd-resolved）
- **回退方案**：`/etc/network/interfaces.fallback`。万一 NM 起不来，在串口里执行：
  ```bash
  cp /etc/network/interfaces.fallback /etc/network/interfaces
  systemctl restart networking
  ```
  就回到 v2 的 ifupdown 方式（eth0 走 DHCP）。
- WiFi：nm-applet 可扫描/连接（前提是 `wlan0` 出现，取决于 NVRAM，见第 5 节）

### 2.3 音频修复（耳机）★

**根因（已确认，非推测）**：

```
Debian 6.1 内核配置里连 CONFIG_SND_SOC_RT5651 这一项都没有
（其他 Realtek codec 如 RT5640/RT5645/RT5682 都编了，就漏了 RT5651）
```

设备树里那块模拟声卡是 `simple-audio-card` + `realtek,rt5651`，**缺了 codec 这半边 → 整张声卡注册不起来 → 耳机孔必然没声音**。这不是配置问题，是内核缺驱动。

**修复做法**：自己编了这个模块并打进镜像。

| 步骤 | 内容 |
|---|---|
| 源码 | 上游 v6.1.187 的 `sound/soc/codecs/rt5651.c` + `rt5651.h` + `rl6231.h` |
| 编译 | 用 Debian `linux-headers-6.1.0-53-arm64`（含 `Module.symvers`）外部模块编译 |
| 产物 | `snd-soc-rt5651.ko`（706 KB），`vermagic = 6.1.0-53-arm64 SMP mod_unload modversions aarch64`（与内核完全一致） |
| 安装 | `/lib/modules/6.1.0-53-arm64/extra/` + `depmod`；OF 别名 `of:N*T*Crealtek,rt5651 → snd_soc_rt5651` 已生效；另写入 `/etc/modules-load.d/eaidk-audio.conf` 做保险 |
| 依赖 | `snd-soc-core` / `snd-soc-rl6231` / `snd-pcm` 都在镜像里 ✓ |

**上板验证**（v3 启动后）：

```bash
aplay -l                       # 应出现 realtek,rt5651-codec 声卡
dmesg | grep -iE 'rt5651|asoc' # 应看到 codec 注册
```

**可能还需要手动一步**（我在无硬件环境里无法验证混音器默认值）：RT5651 的耳机通路有几个 DAPM 开关，默认可能是关的：

```bash
alsamixer -c <N>     # F6 选中 rt5651 那张卡
                     # 用 m 打开：HPO MIX DAC1 Switch / HPO MIX HPVOL Switch / HPO L Playback / HPO R Playback
                     # 音量拉满：HP Playback Volume
```

或者直接批量（把 `<N>` 换成声卡号，一般是 0 或 1）：

```bash
amixer -c <N> sset 'HPO MIX DAC1 Switch' on
amixer -c <N> sset 'HPO MIX HPVOL Switch' on
amixer -c <N> sset 'HPO L Playback' on
amixer -c <N> sset 'HPO R Playback' on
amixer -c <N> sset 'HP Playback Volume' 100%
alsactl store        # 存到 /var/lib/alsa/asound.state，重启保留
```

还有一处很常见的坑：**PulseAudio 默认输出选到了 HDMI**（板子 HDMI 音频会另外注册一张卡）。检查/切换：

```bash
pactl list sinks short      # 看有没有 analog 输出
pavucontrol                 # “输出设备”标签里把模拟输出设为默认（右上角绿勾）
```

**还有两个能力目前不支持**（需要的话我再出一版，见第 6 节）：

1. **外放喇叭**：主线 rt5651 驱动只在 DAPM 里建模了耳机（HPOL/HPOR）和线路输出，**没有 Speaker 通路**；而且设备树里的 `spk-con-gpio`（GPIO0_PB3，外放功放使能）主线驱动也不认。要外放得改两处：给声卡加 Speaker widget/route + 用 gpio-hog 把该 GPIO 拉高。
2. **插孔自动检测**：板子用的是 `hp-det-gpio`，主线 rt5651 只支持 `realtek,jack-detect-source`，所以不会自动在耳机/外放间切换。

---

## 3. 分区布局

| 偏移 | 大小 | 内容 |
|---|---|---|
| 32 KiB (LBA 64) | 161,792 B | `idbloader.img` |
| 8 MiB (LBA 16384) | 1,023,488 B | `u-boot.itb` |
| 16 MiB (LBA 32768) | 256 MiB | **p1** FAT32 `BOOT`，UUID `1A2B-3C4D` |
| 272 MiB (LBA 557056) | 4864 MiB | **p2** ext4 `armbi_root`，UUID `230a0279-8991-4499-8b75-ab2c3a8fdacb` |

启动分区里仍然同时放着 `rk3399-eaidk-610.dtb`（rgmii-id，默认用）和 `rk3399-eaidk-610-rgmii-macdelay.dtb`（回退）。

---

## 4. 烧录 / 登录 / 首启

```bash
sha256sum -c rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.gz.sha256
lsblk
gunzip -c rk3399-eaidk-610-debian12-xfce-v3-6.1.0-53-arm64.img.gz \
  | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

| 入口 | 说明 |
|---|---|
| 串口 | `ttyS2` @ **1500000** 8N1（USB-TTL 3.3V） |
| HDMI | 图形登录界面（lightdm） |
| 账号 | `debian / debian`（带 sudo，图形界面用这个）；`root / root`（串口/本地终端） |
| 首启自动 | ① 生成 SSH host key ② 根分区扩到整张卡 ③ 建 2GiB swap |

**请先改密码**：`passwd debian`、`passwd root`。

---

## 5. 校验结果（全部通过）

| # | 校验 | 结果 |
|---|---|---|
| 1 | 四段载荷从最终镜像 `dd` 出来与源文件 `cmp` | 逐字节一致 |
| 2 | 偏移处 `blkid -p -O` | vfat `1A2B-3C4D` / ext4 `230a0279…` ✓ |
| 3 | `e2fsck -fn` | 干净：43437 文件，702824/1244923 blocks，inode 622592 |
| 4 | `fsck.vfat -n` / `sgdisk -v` | 通过 / No problems found |
| 5 | `root=UUID` 三方一致 | extlinux.conf == fstab == fs |
| 6 | `gzip -t` | 通过 |
| 7 | 自编模块 | `modinfo` 显示 filename/vermagic/depends 全部正确 |
| 8 | v3 组件 | `fcitx5`、`libpinyin.so`、`nm-applet`、`NetworkManager`、`amixer`/`aplay`/`speaker-test` 就位 |
| 9 | 属主 | `/home/debian/.config` 为 `1000:1000`（否则 fcitx5 存不了配置） |

---

## 6. 已知注意点

1. **WiFi/BT**：NVRAM 仍是替身文件（`brcmfmac43455-sdio.openailab,eaidk-610.txt`）。要真能用，请从原厂系统 `/lib/firmware/brcm/` 复制正确的 NVRAM 文件给我或自己放到同路径。
2. **音频**：模块已就位；混音器默认值 / PulseAudio 默认 sink 可能需手动一次（见 2.3）。外放喇叭与插孔自动检测目前不支持，需要我改 DT 才能做。
3. **NetworkManager 接管了 eth0**：如果界面上网络异常，用 2.2 的回退文件切回 ifupdown。
4. **root 不能从图形登录界面登录**（PAM 策略），用 `debian` 登录后 `sudo -i`。
5. **v1 镜像别用**（以太网 dtb 是坏的）。
6. **视频硬解有限**：主线内核无 VA-API，浏览器内视频是软解。

---

## 7. 重建要点

- 自编模块的源码与 Makefile：`/workspace/build/rt5651/`（`rt5651.c` / `rt5651.h` / `rl6231.h` / `Makefile`）
- 编译需要容器里有 `linux-headers-6.1.0-53-arm64` + `libelf-dev`；命令：
  `make -C /usr/src/linux-headers-6.1.0-53-arm64 M=/workspace/build/rt5651 modules`
- 关键参数：root UUID `230a0279-8991-4499-8b75-ab2c3a8fdacb`、启动分区 UUID `1A2B-3C4D`、分区偏移 `64 / 16384 / 32768 / 557056`、镜像总大小 5136 MiB
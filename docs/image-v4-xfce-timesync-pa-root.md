# v4 · Debian 12 + XFCE（时间同步 + PulseAudio root 支持 + 音频通路保险）

v4 在 v3 基础上只做三件事，全部来自真机上踩到的问题。

```
gz  sha256  55c5ad110d5d94f58a8eceda2c0aed437a4029b1d14b81bf9393108ef1984348
raw sha256  0c803ef6809556764ee80020ac25b0eff1cafe6ed2f21c04061713cef6a26455
gz 大小      1,093,341,107 B (1043 MiB)
解压后大小   5,385,486,336 B (5136 MiB)
```

---

## 1. 时间同步（板子没有 RTC 纽扣电池）

**现象**：系统时间不对，联网后也不会自动更新。

**根因**（三条叠加）：

1. 镜像里**没有任何 NTP 客户端** —— `systemd-timesyncd` 是 `systemd` 的 *Recommends*，构建时用了 `--no-install-recommends` 被跳过（`chrony`/`ntp`/`ntpsec`/`openntpd` 也都没有）
2. 板子**没有 RTC 电池** → 每次上电 RTC 是空的，而内核配了 `CONFIG_RTC_HCTOSYS=y`，会把这个垃圾值当成系统时间读进来
3. 时区本身没问题（`/etc/localtime → Asia/Shanghai`、`/etc/timezone = Asia/Shanghai`），**坏的只是时钟本身**

**修法**（电池板的标准组合，树莓派也是这么做的）：

| 组件 | 作用 |
|---|---|
| `systemd-timesyncd` | 联网后精确校时，预配 `ntp.aliyun.com` / `time1.cloud.tencent.com` / `cn.pool.ntp.org` |
| `fake-hwclock` | 开机瞬间先恢复上次保存的时间 —— 这样在 NTP 校时之前的几秒里时间也接近正确，**避免 HTTPS 证书"尚未生效"报错、日志时间错乱** |
| `/etc/default/fake-hwclock` 里 `FORCE=force` | 无条件采用保存值。空 RTC 的值不可信，而默认行为**只会把时钟往前调**，覆盖不了垃圾的未来时间 |
| 自带 `fake-hwclock-save.timer` | ⚠️ 镜像里**没有 cron**，Debian 默认的 `/etc/cron.hourly/fake-hwclock` 不会执行；用 systemd 定时器替代（开机 10 分钟后存一次，之后每小时存一次） |
| 预置 `/etc/fake-hwclock.data` | 首启就有一个合理起点，不必等第一次存盘 |

验证：

```bash
timedatectl
# Time zone: Asia/Shanghai (CST, +0800)
# System clock synchronized: yes      ← 关键
# NTP service: active
```

想换成别的 NTP：编辑 `/etc/systemd/timesyncd.conf` 的 `NTP=` 行，然后 `systemctl restart systemd-timesyncd`。

---

## 2. PulseAudio 支持 root 桌面

**现象**：桌面右上角喇叭图标点开后一直显示"连接中"，声音设置（pavucontrol）打不开；**但 USB 耳机有声音**。

**根因**（有硬证据，不是猜测）：

1. 桌面是以 **`root`** 登录的
2. `/usr/lib/systemd/user/pulseaudio.service` 和 `pulseaudio.socket` 都带 **`ConditionUser=!root`** —— 上游**明确拒绝**为 root 运行 PulseAudio
3. `/etc/pulse/client.conf` 未设置 `allow-autospawn-for-root`（上游默认 `no`）→ root 会话里的客户端（那个喇叭插件）**无法把 PA 拉起来**
4. 于是面板插件永远连不上；而"有声音"是因为播放器（mpv/VLC 等）**绕过 PA 直接走 ALSA** —— 能响，但不归 PA 管（所以每应用音量、输出设备切换都没有）

**修法**：

- `/etc/pulse/client.conf` 追加一行 `allow-autospawn-for-root = yes`（**对非 root 用户无任何影响**）
- `debian` 加入 `audio` 组（万一 logind 的 ACL 没生效时的保险）

**仍然建议桌面用 `debian` 登录**：`root` 和 `debian` 两个账号都在（密码分别是 `root` / `debian`），但浏览器长期以 root 运行风险更高。

验证（在 root 桌面里）：

```bash
pactl info        # 应显示 Server Name: pulseaudio
xfce4-panel -r    # 重启面板，让喇叭图标重新连接
```

---

## 3. 音频通路保险（⚠️ 未真机验证）

新增 `eaidk-audio-unmute.service`：开机把 RT5651 耳机通路的 DAPM 开关显式打开。

- 背景：v3 耳机无声的**根因是驱动缺失**（Debian 内核没编 `CONFIG_SND_SOC_RT5651`，v3 已用自编模块修好，且 `aplay -l` 里已出现该声卡）。但耳机通路的 DAPM 开关**默认值取决于驱动**，若为关则无声
- 服务用驱动编译产物里**确切的控件名**：`HPO MIX DAC1 Switch`、`HPO MIX HPVOL Switch`、`HPO L Playback`、`HPO R Playback`、`HPOVOL L`、`HPOVOL R`，外加 `HP Playback Volume` unmute；控件不存在时静默跳过（`|| true`）
- 如果默认本来就是通的，这个服务**等价于空操作，不会破坏已有状态**
- ⚠️ 本项**当时没有耳机可测，未经真机验证**

想手动测：

```bash
aplay -l                                              # 看 rt5651 卡的编号
speaker-test -D plughw:<编号>,0 -c 2 -t sine -l 2     # 插耳机听
```

如果 `speaker-test` 没声但 USB 有声，把 `/usr/local/sbin/eaidk-audio-unmute.sh` 里的控件名对照 `amixer -c <卡名> scontrols` 的输出核对一遍，把差异告诉我。

---

## 4. 本版没做的事（明确列出）

| 项 | 状态 |
|---|---|
| 外放喇叭 | ❌ 主线 rt5651 驱动**没有 Speaker 通路**，且设备树的 `spk-con-gpio`（功放使能）主线驱动不认 —— 要外放需改 DT（加 Speaker widget/route + gpio-hog） |
| 插孔自动检测 | ❌ 主线不支持板子用的 `hp-det-gpio`（只认 `realtek,jack-detect-source`），因此不会自动在耳机/外放间切换 |
| 浏览器内硬件视频解码 | ❌ 主线无 VA-API；rk3399 VPU（hantro/rkvdec，stateless V4L2）**不支持 AV1**。网页视频为软解 |
| WiFi/BT | ⚠️ NVRAM 是替身文件，需从原厂系统 `/lib/firmware/brcm/` 复制正确的那份 |

构建流程与分区参数见仓库根 `README.md`；v1/v2/v3 的完整说明见 `docs/` 下对应文档。
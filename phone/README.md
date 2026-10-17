# 手机端：抖音硬阻断（不用系统「屏幕限时」）

到点把抖音**禁用**（图标消失、打不开、进程被 force-stop），`20:00–23:00` 自动恢复。
纯本地、不联网、不碰系统数字健康。

## 装三样

| 工具 | 用途 | 来源 |
|---|---|---|
| **Shizuku** | 拿到 shell 权限（不 root） | GitHub / 应用商店，开源 |
| **Termux** | 跑脚本 | **F-Droid 版**（Play 版太旧，别用） |
| **Termux:Boot** | 开机自启（可选） | F-Droid，跟 Termux 配套 |

## 一次配置

1. 设置 → 关于手机 → 连点「版本号」开开发者选项 → **无线调试**打开
2. 开 Shizuku →「通过无线调试启动」→ 配对 → 启动
3. Termux 里：`pkg update && pkg install termux-api`
4. Shizuku → 右下角「Use rish」→ 按页面提示把 `rish` 和 `rish_shizuku.dex` 放到 `$HOME`，然后 `chmod +x ~/rish`
5. 把本目录三个文件传到手机（比如 `~/storage/downloads/phone/`），Termux 里：

```bash
cd ~/storage/downloads/phone
bash install.sh
~/afs-phone/guard.sh status
~/afs-phone/guard.sh run
```

6. **ColorOS 会杀 Termux 后台**：设置 → 电池 → 应用耗电管理 → Termux → 允许完全后台行为

## 日常

```bash
~/afs-phone/guard.sh status   # 看状态
~/afs-phone/guard.sh allow    # 临时放开
~/afs-phone/guard.sh block    # 立刻禁用
~/afs-phone/guard.log         # 日志
```

时间窗口改 `guard.sh` 顶部的 `ALLOW_START` / `ALLOW_END`（HHMM，支持跨午夜）。

**报 `$'\r': command not found`** = 文件被 Windows 转成了 CRLF。修：

```bash
sed -i 's/\r$//' ~/afs-phone/*.sh ~/storage/downloads/phone/*.sh
```

## 三个洞，必须知道

1. **重启后 Shizuku 掉线 → 阻断失效。** 得重新用无线调试启动一次（约 1 分钟）。没有 root 就没有真正的开机自启。
2. **关掉无线调试 / 强停 Shizuku / 卸载 Termux**，任一个都能在 30 秒内破功。
3. **浏览器里的抖音网页版没被拦。** 这方案只管 App，不管 douyin.com。

抖音系有三个独立包，漏一个等于没限：

```
com.ss.android.ugc.aweme        抖音
com.ss.android.ugc.aweme.lite   抖音极速版
com.ss.android.ugc.live         抖音火山版
```

## 想真正锁死，只有一条路

**Device Owner**（一次性 `adb` + 一个 DPC App）。它给的能力正好对应这个项目的三个机制：

| 这个项目 | Device Owner |
|---|---|
| `Stop-Process` 杀进程 | `setPackagesSuspended` |
| 卸载守卫 | `DISALLOW_UNINSTALL_APPS` |
| 每分钟 enforcer | `JobScheduler` 定时切窗口 |

而且**用户自己撤不掉**，只能 `adb shell dpm remove-active-admin` 或恢复出厂。

代价：设备上不能有账号才能设（大概率要先恢复出厂）。本机没有 Android SDK，走这条我得先装工具链再编 APK。

---

Windows 那套 `src/` 跟这里互不影响。

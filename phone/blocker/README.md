# AFS 守卫 · 无障碍版

不需要 Device Owner，不需要 Shizuku，不需要连电脑。
开机自启，重启不失效 —— 这是它在你的机器上唯一能跑起来的方案。

| | Device Owner 版（`../dpc`） | 无障碍版（本目录） |
|---|---|---|
| 能否在 PLR110 上装 | ❌ 被应用分身的 clone profile 挡住 | ✅ 能 |
| 要不要恢复出厂 | 要 | **不要** |
| 重启后 | 一直有效 | 自动恢复（无需电脑） |
| 抖音还能不能打开 | 冻结，点开提示"已暂停" | 能打开，但立刻被送回桌面 |
| 强停/卸载 | 设置里点不动 | 设置里能关（系统不允许应用自我锁定） |
| 实现方式 | `setPackagesSuspended()` | `performGlobalAction(GLOBAL_ACTION_HOME)` |

## 原理

```
抖音切到前台 ──▶ 无障碍服务收到 TYPE_WINDOW_STATE_CHANGED
                        │
                  现在在放行窗口内？
                   ├─ 是 → 什么都不做
                   └─ 否 → performGlobalAction(HOME) 送回桌面 + Toast 提示
```

外加一个 3 秒的巡检，处理「人一直停在抖音里、跨过 23:00 边界」——那种情况不会再有窗口事件，只能定时查。

## 装

```bash
ADB="C:/Users/nj/.afs-android/sdk/platform-tools/adb.exe"
"$ADB" install -r afs-blocker.apk

# 方式一：手机上开（推荐，能看见开关状态）
#   设置 → 无障碍 → 已下载的应用 → AFS 守卫 → 打开
#   注意：adb install 装的应用在部分系统上要先打开一次 App 才出现在列表里

# 方式二：命令行直接开（需要 adb，shell 有 WRITE_SECURE_SETTINGS）
"$ADB" shell settings put secure enabled_accessibility_services com.afs.blocker/com.afs.blocker.BlockerService
"$ADB" shell settings put secure accessibility_enabled 1

# 顺手加电池白名单，别让 ColorOS 把服务清掉
"$ADB" shell dumpsys deviceidle whitelist +com.afs.blocker
```

> ⚠️ `adb install -r` 覆盖安装会**清掉** `enabled_accessibility_services`，
> 升级完必须重新打开一次无障碍开关。

## ColorOS 上必须补的两个权限

1. **自启动**：设置 → 应用 → 应用自启动管理 → 允许「AFS 守卫」
2. **耗电管理**：设置 → 应用 → 应用管理 → AFS 守卫 → 耗电管理 → 允许后台活动

不给这两个，重启或长期待机后服务可能被 OEM 清掉。

## 改时段

改 `java/com/afs/blocker/Guard.java` 顶部四个常量：

```java
public static final int ALLOW_START_H = 20;
public static final int ALLOW_START_M = 0;
public static final int ALLOW_END_H   = 23;
public static final int ALLOW_END_M   = 0;
```

然后：

```bash
cd phone/blocker
bash build.sh
"$ADB" install -r ../afs-blocker.apk
# 重新打开无障碍开关（见上面的警告）
```

支持跨午夜：`START_H=23, END_H=20` 就是 23:00 到次日 20:00 放行。

## 管的包

```
com.ss.android.ugc.aweme        抖音
com.ss.android.ugc.aweme.lite   抖音极速版
com.ss.android.ugc.live         抖音火山版
```

**三个都要**。极速版和火山版是独立安装包，漏一个等于没管。

浏览器里的抖音网页版默认不管，要管就把 `ALSO_BLOCK_BROWSERS` 改 `true`。

## 离线回归

不需要手机，不需要 Android 运行时：

```bash
bash test/run.sh
```

用「逐分钟暴力扫描」当标准答案，对拍边界跳跃算法；覆盖默认窗口（20:00→23:00）和跨午夜窗口（23:00→20:00）两种配置，各 4320 个时间点。
当前：**15 PASS / 0 FAIL**（两套配置各 15 项）。

## 还剩什么洞

诚实列出来：

1. **进设置能关掉**。无障碍服务是用户可撤销的，系统不允许应用自己锁死自己——这是 Android 的设计。想真正拆不掉，只有 Device Owner，而这台机器装不上。
2. **关机 / 强制停止应用**能临时绕过。不过重启后服务会自动恢复。
3. **浏览器里的抖音网页版**默认不管。
4. **"假死"页面**：如果你在抖音里能让它一直在前台（比如投屏/小窗），事件不再触发，要等到下一次窗口切换才会被踢。

# AFS 守卫 · 无障碍版

不需要 Device Owner，不需要 Shizuku，不需要连电脑。
**重启后系统自动恢复**（前提是从系统设置里手动开启过一次，见 §4）。

| | Device Owner 版（`../dpc`） | 无障碍版（本目录） |
|---|---|---|
| 能否在 PLR110 上装 | ❌ 被应用分身的 clone profile 挡住 | ✅ 能 |
| 要不要恢复出厂 | 要 | **不要** |
| 重启后 | 一直有效 | 自动恢复 |
| 抖音还能不能打开 | 冻结，点开提示"已暂停" | 能打开，但立刻被送回桌面 |
| 强停/卸载 | 设置里点不动 | 设置里能关（系统不允许应用自我锁定） |

## 1. 功能

- **选择应用**：从已安装的可启动应用里勾选，管哪些由你定。默认预置抖音三件套。
- **放行时段**：默认 `20:00–23:00`，可改；支持跨午夜（如 `23:00–20:00`）。
- **强制模式**：两种触发，都是**不可提前解除**的
  - 自动：进入屏蔽时段就自动锁，到点自动解
  - 手动：点「开启强制模式」选 1/3/6/12 小时，期间**连放行时段也照拦**，只能等到点

## 2. 原理

```
App 切到前台 ──▶ 无障碍服务收到 TYPE_WINDOW_STATE_CHANGED
                        │
                  现在在拦截状态吗？
                  （强制模式中 或 不在放行时段）
                   ├─ 否 → 什么都不做
                   └─ 是 → performGlobalAction(HOME) 送回桌面 + Toast 提示
```

外加 3 秒巡检，处理「人一直停在 App 里、跨过边界」——那种情况不会再有窗口事件，只能定时查。

## 3. 装

```bash
ADB="C:/Users/nj/.afs-android/sdk/platform-tools/adb.exe"
"$ADB" install -r afs-blocker.apk
"$ADB" shell dumpsys deviceidle whitelist +com.afs.blocker   # 电池白名单
```

## 4. 必须手动开一次无障碍（关键）

`adb shell settings put secure enabled_accessibility_services ...` 能立刻生效，
**但系统会在开机 / 覆盖安装时把它清掉**，实测重启后变回 `null`。

所以一定要走系统设置这条：

> **设置 → 无障碍 → 已下载的应用 → AFS 守卫 → 打开**

开完之后，重启也能自动恢复（系统按这个开关重新绑定服务）。

ColorOS 还要补两个权限，否则长期待机可能被 OEM 清掉：

1. **自启动**：设置 → 应用 → 应用自启动管理 → 允许「AFS 守卫」
2. **耗电管理**：设置 → 应用 → 应用管理 → AFS 守卫 → 耗电管理 → 允许后台活动

## 5. 锁定规则（这是"强制"的核心）

**拦截状态 = 强制模式中 或 不在放行时段。**

在这个状态下，App 里所有设置（选应用、改时段、开强制）全部变灰，
**没有任何"解除"按钮**，只能等到点。

代价要讲清楚：想改设置，只能在放行时段里改。默认就是每天 `20:00–23:00` 这 3 小时。
如果时段设错了，就得等它自己走到放行窗口。

> 首次安装有一次性宽限：还没保存过任何配置时不锁，方便你先选应用、设时段。
> 保存之后立即开始按上面的规则走。

## 6. 改时段 / 改应用

直接在 App 里点（放行时段内），不需要重编。
数据存在 SharedPreferences（`afs_blocker`），卸载即清空。

## 7. 离线回归

不需要手机，不需要 Android 运行时：

```bash
bash test/run.sh
```

`Guard` 是纯 Java（不 import 任何 Android 类），窗口从参数传进来，
所以一个进程里跑多套配置：默认窗口、跨午夜窗口、强制模式语义。

当前：**27 PASS / 0 FAIL**
- 两套窗口各 4320 个时间点逐分钟暴力对拍，失配 0
- 强制模式关键断言：**放行时段里开强制 → 仍然拦**（否则等于没开）
- `forceUntil == now` 视为已结束

## 8. 强化杀进程（需要 Shizuku）

只按 Home 等于把 App 挪到后台。实测在这台机器上：

| 手段 | 结果 |
|---|---|
| `performGlobalAction(HOME)` | 有效，但进程留着、划回来就在原画面 |
| `ActivityManager.killBackgroundProcesses` | **杀不掉抖音**——按 Home 后系统把它放进 `mPreviousProcess` 槽位，受保护 |
| `am kill`（shell 也一样） | 同上，杀不掉 |
| `am force-stop` | ✅ 进程立刻消失，冷启动 |

`force-stop` 需要 `FORCE_STOP_PACKAGES`，普通 App 拿不到，只能借 Shizuku 的 shell 身份。
所以 App 内置了 Shizuku API（`libs/shizuku-api.jar` + `shizuku-provider.jar`，v12.2.0，
因为 v13 移除了 `newProcess`）：

```
退到桌面 700ms 后 → Shizuku.newProcess(["am","force-stop",pkg])
                  → 失败则退回 killBackgroundProcesses
```

**开启条件（实测跑通过的全部条件，少一条都不行）：**

1. **Shizuku 必须用 12.x**（[v12.14.0](https://github.com/RikkaApps/Shizuku/releases/tag/v12.14.0)）。
   v13 移除了 `newProcess`，API 13 的 jar 里根本没有这个方法。
2. 启动 Shizuku（非 root 走 adb）：
   ```bash
   adb shell sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh
   ```
3. 给本 App 授自定义权限（**dangerous 级，必须运行时授予**）：
   ```bash
   adb shell pm grant com.afs.blocker moe.shizuku.manager.permission.API_V23
   ```
4. 两个 App 都要加电池白名单，否则 Shizuku 报 `Request timeout`：
   ```bash
   adb shell dumpsys deviceidle whitelist +moe.shizuku.privileged.api
   adb shell dumpsys deviceidle whitelist +com.afs.blocker
   ```

**binder 是手动注入的**（`ShizukuBridge.java`）。官方的
`requestBinderForNonProviderProcess()` 在这台机器上不生效，`pingBinder()` 恒为 false。
改成直接调自己的 Provider 拿 `IBinder`，再喂给 `Shizuku.onBinderReceived()`：

```java
Bundle b = getContentResolver().call(
        Uri.parse("content://com.afs.blocker.shizuku"),
        ShizukuProvider.METHOD_GET_BINDER, null, null);
Shizuku.onBinderReceived(b.getBinder(ShizukuProvider.METHOD_SEND_BINDER), getPackageName());
```

主页「无障碍服务」卡片显示当前状态：
- 绿：`已接通 Shizuku，退到桌面后直接 force-stop`
- 红：`Shizuku 未运行` —— 只退桌面，不杀进程

实测日志：
```
kicked com.ss.android.ugc.aweme (#1)
force-stop com.ss.android.ugc.aweme exit=0 out=[] err=[]
```

⚠️ **Shizuku 重启后失效**（非 root 模式必须重新连电脑启动一次）。
它没在跑的时候，App 自动降级为"只退桌面"，不报错也不会卡住。

## 9. 自愈（系统把开关清掉后自动写回）

ColorOS 会不定时把无障碍开关清成 `null` / `0`（侧载 App 的"受限设置"策略），
表现就是"突然不拦了"。普通 App 没权限改，但 **Shizuku 是 shell 身份，有 WRITE_SECURE_SETTINGS**。

`Heal.java` 每 **2 分钟**查一次，发现服务没登记就写回去：

```sh
appops set com.afs.blocker ACCESS_RESTRICTED_SETTINGS allow
settings put secure enabled_accessibility_services com.afs.blocker/com.afs.blocker.BlockerService
settings put secure accessibility_enabled 1
```

调度用 `AlarmManager.setInexactRepeating`（60s 起，实际按系统对齐），
`HealReceiver` 每次被唤醒都重新挂下一次，并监听 `BOOT_COMPLETED` 重启链路。

实测：手动把 `enabled_accessibility_services` 删掉、`accessibility_enabled=0`，
144 秒后自动恢复（日志 `heal ran, now=true`）。

⚠️ **自愈也依赖 Shizuku**。Shizuku 不在时它什么也做不了，
所以"重启后"这个洞自愈补不上，只能靠连电脑启动 Shizuku。
⚠️ 你手动关掉无障碍，两分钟内会被它自己打开 —— 这是设计如此。

## 10. 还剩什么洞

诚实列出来：

1. **进设置能关掉无障碍**。系统不允许应用自己锁死自己——这是 Android 的设计，绕不过。
2. **清应用数据**会清掉选中的应用和强制模式状态。
3. **强制停止**能临时生效；不过重启后服务会自动恢复。
4. **浏览器里的抖音网页版**默认不管（没有网页版拦截逻辑）。
5. **覆盖安装 `adb install -r` 会清掉无障碍开关**，升级完必须重新打开一次。

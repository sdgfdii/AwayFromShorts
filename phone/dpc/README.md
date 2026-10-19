# AwayFromShorts · Device Owner 版

手机上唯一真正锁得住的方案：把 App 变成 **Device Owner（设备所有者）**，然后用
`setPackagesSuspended()` 到点冻结目标 App。

## 三步装好

```bash
bash build.sh        # 可选，仓库里已经带了 afs-guard.apk
bash deploy.sh       # 自检 + 安装 + 设为设备所有者 + 验证
```

`deploy.sh` 会先查三个硬条件（**无账号、单用户、无已有 Owner**），
不满足直接告诉你卡在哪、怎么解。装不上先看
[COMPATIBILITY.md](COMPATIBILITY.md)——90% 是"应用分身"留下的第二个用户。

拆掉只有一条路：

```bash
bash uninstall.sh
```

## 构建环境

只要 JDK 17 + Android SDK 的 `build-tools` 和 `platforms/android-34`，**不需要 Gradle**。

```bash
export AFS_SDK=/path/to/android-sdk    # 或 ANDROID_HOME
bash build.sh
```

脚本会自动找版本最高的 build-tools，Windows / macOS / Linux 都能编。

---

手机上唯一真正锁得住的方案：把 App 变成 **Device Owner（设备所有者）**，然后用
`setPackagesSuspended()` 到点冻结抖音。

跟系统「屏幕限时」的区别：

| | 系统屏幕限时 | 这个 DPC |
|---|---|---|
| 到点后「延长 15 分钟」 | 有，输密码就行 | **没有这个按钮** |
| 强停 / 卸载 | 能 | 设置里点不动 |
| 恢复出厂洗掉 | 能 | 被 `DISALLOW_FACTORY_RESET` 拦住 |
| 安全模式绕过 | 能 | 被 `DISALLOW_SAFE_BOOT` 拦住 |
| 改系统时间绕过 | 能 | 被 `DISALLOW_CONFIG_DATE_TIME` 拦住 |

代价说清楚：**装上去以后只能靠 adb 拆**，路径见文末「逃生口」。

**管哪些 App**：打开 App →「＋ 添加应用」→ 从已安装应用里勾。
默认预置抖音三件套（抖音 / 极速版 / 火山版）。改完立刻重新冻结，不用等下一次闹钟；
被移出列表的 App 会自动解冻（靠 `RuleStore.applied` 记住上一次应用过谁）。

## 每个应用各自的时段

每个应用是**独立的一条规则**：自己的放行星期 + 自己的放行时段。

```
抖音    每天 21:00-23:00     → 只有这两小时能刷
微信    每天 07:00-22:00     → 白天随便用
B站     周末 10:00-22:00     → 只在周末开
```

首页只有状态和三个按钮（黑名单 / 强制模式 / 立即应用）。
**应用列表单独一页**（`AppListActivity`），一行一个：名字 + 时段 + 状态，点开改那条规则，
长按移出黑名单。应用一多也不会把首页撑得老长。

**加新应用时**默认套用"上次改过的那条规则"，改一下就行。

「＋ 添加应用」跟其他设置一样受锁定：全部应用都在屏蔽中时它是灰的，点不动。
唯一例外是黑名单为空 —— 空列表里没有任何窗口，不给加就永远加不回来。
新加的应用有 10 分钟可以编辑（默认规则多半正好落在屏蔽时间里，
不给这点时间你连时段都设不了）；但这 10 分钟**不能移除**它，否则等于留了后门。

底层：`RuleStore` 把 `{包名 → (星期, 起点, 终点)}` 存成一个 JSON；
闹钟只排**所有应用里最早的那个**翻转时刻，响了之后 `apply()` 把每个应用重判一遍。

## 强制模式与锁定

**锁定是按应用算的。** 某个 App 正处在自己的屏蔽时间里，它在黑名单里那一行就打不开：

- 改不了星期（一~日）
- 改不了起点 / 终点
- 移不出黑名单（列表页长按、选择页取消勾选，两条路都被挡住）
- 加不了新应用（「＋ 添加应用」也是灰的；只有黑名单为空时才破例，
  否则空列表没有任何窗口，等于永久锁死）

别的应用不受影响 —— 微信在放行时段里，你照样能改微信的时段。

**没有任何解除按钮。** 想改抖音的时段，只能在抖音自己的放行时段里改。

这条是必需的：否则冻结期间点一下「移除」再「立即应用」，一秒就绕过去了。

全部应用都在屏蔽中时，首页整页切深色，看上去就是"锁着"的状态。

**强制模式**：一个开关，没有时长。开着时**所有应用一律冻结**（连各自的放行时段也不算），
设置同样锁死。要关掉它，得等到**任意一个应用**进入自己的放行时段。

**首次宽限**：第一次打开 App 后有 **10 分钟**可以随便配（应用、星期、时段），
之后开始按锁定规则走。装完正好落在屏蔽时段也不会被锁死。

## 放行星期

每个应用七个按钮，默认全选（每天）。规则：

```
放行 = 今天在选中的星期里  且  时间落在 [起点, 终点)
其余一律冻结
```

没选中任何一天 = 全天冻结。跨午夜（起点 > 终点）时，"选中的星期"指窗口**起始日**：
周一 23:00–次日 20:00 的凌晨那段算周一的窗口。

---

## 0. 先确认一件事：要不要恢复出厂

`dpm set-device-owner` 要求设备上**没有任何账号**（Google / OPPO / 微信 / QQ / 支付宝都算），
也不能有应用分身和工作资料。

**先别清机，按这个顺序试**——多数机器删完账号就通了（先照 §2 打开 USB 调试并连上电脑）：

```bash
ADB="C:/Users/nj/.afs-android/sdk/platform-tools/adb.exe"

# 1) 看看有哪些账号
"$ADB" shell dumpsys account | grep "Account {"

# 2) 每删掉一个，就重跑一次设置命令
"$ADB" shell dpm set-device-owner com.afs.guard/.AfsAdmin
```

删账号的顺序：Google / OPPO 先删（无痛），微信放最后（删之前先备份聊天记录）。

| 报错 | 含义 | 处理 |
|---|---|---|
| `already some accounts` | 还有账号没删干净 | 继续删，看 `dumpsys account` |
| `already several users` | 开了应用分身 / 隐私空间 | 先全部关掉 |
| `already provisioned` | OEM 额外限制 | **这条才需要恢复出厂** |
| `Success: Device owner set to package` | 成功 | 收工，账号可以逐个登回去 |

只有最后那条「恢复出厂」的路，顺序才是：**恢复出厂 → 跳过账号登录 → 装 APK 设 DO → 再登账号**。
设成 DO 之后**不能**再走这条路，`DISALLOW_FACTORY_RESET` 会把「恢复出厂」按钮变灰。

---

## 1. 打包（在电脑上）

```bash
cd phone/dpc
bash build.sh
```

产物：`phone/afs-guard.apk`（21 KB，已签名）。

签名库在 `phone/dpc/keystore/afs.keystore`（密码 `afsguard`）。
**换 key 就没法覆盖升级**，别弄丢。

> 已经打包好的那份在 `phone/afs-guard.apk`，直接拿去用即可，跳过这一步。

## 2. 手机准备

1. 设置 → 关于手机 → 版本号，连点 7 次 → 打开开发者选项
2. 设置 → 系统设置 → 开发者选项 → 打开 **USB 调试**
3. ColorOS 还要额外打开 **「禁止权限监控」** 和 **「USB 安装」**（不同版本名字略有差异）
4. 数据线连电脑，手机上点「允许 USB 调试」

## 3. 装 APK 并设为设备所有者

```bash
ADB="C:/Users/nj/.afs-android/sdk/platform-tools/adb.exe"

# 确认连上了（手机上会出现授权弹窗，勾"始终允许"）
"$ADB" devices

# 安装
"$ADB" install -r phone/afs-guard.apk

# 设为设备所有者（这一步是全部关键）
"$ADB" shell dpm set-device-owner com.afs.guard/.AfsAdmin
```

成功会输出：

```
Success: Device owner set to package ComponentInfo{com.afs.guard/com.afs.guard.AfsAdmin}
```

核对一下：

```bash
"$ADB" shell dpm list-owners
```

然后手机桌面上打开 **AFS 守卫**，页面第一行应该显示 `设备所有者　是（已锁死）`。

---

## 4. 它会怎么工作

```
        ┌──────────── 允许时段 20:00 - 23:00 ────────────┐
00:00 ────────────────────────────────┬──────────────┬── 24:00
      冻结（图标变灰，点开提示"已暂停"）   ↑              ↑
                                   20:00          23:00
                                  解冻            再冻结
```

- **只在两个边界时刻各响一次**（20:00 / 23:00），不是每分钟轮询 → 不费电
- 外加 `JobScheduler` 每 15 分钟兜底一次，防止闹钟被系统掐掉
- 开机 / 重装后自动重新落一遍
- 冻结态是**持久的**：即使进程被杀，抖音也打不开

改时段：编辑 `java/com/afs/guard/Guard.java` 顶部四个常量，然后

```bash
cd phone/dpc && bash build.sh
"$ADB" install -r ../afs-guard.apk
```

```java
public static final int ALLOW_START_H = 20;
public static final int ALLOW_START_M = 0;
public static final int ALLOW_END_H   = 23;
public static final int ALLOW_END_M   = 0;
```

跨午夜也支持，比如 `START_H=23, END_H=20` 就是每晚 23:00 到第二天 20:00 放行。

---

## 5. 加固开关（`Guard.java` 顶部）

| 常量 | 默认 | 作用 |
|---|---|---|
| `BLOCK_FACTORY_RESET` | `true` | 禁止恢复出厂。**真正的锁死**，关了就等于留了个一键清空的后门 |
| `BLOCK_SAFE_BOOT` | `true` | 禁止安全模式（否则安全模式里所有第三方 App 都不加载） |
| `BLOCK_APPS_CONTROL` | `true` | 设置里「强行停止 / 卸载 / 清除数据」全部变灰 |
| `BLOCK_TIME_CHANGE` | `true` | 禁止手动改时间（否则把钟拨到 20:00 就绕过去了） |
| `BLOCK_UNINSTALL_ALL` | `false` | 禁止卸载**任何**应用，比较狠，默认关 |
| `ALSO_SUSPEND_BROWSERS` | `false` | 屏蔽时段连浏览器一起冻结，堵抖音网页版 |

---

## 6. 管哪几个包

```
com.ss.android.ugc.aweme        抖音
com.ss.android.ugc.aweme.lite   抖音极速版
com.ss.android.ugc.live         抖音火山版
```

**三个都管**。只写一个等于没管 —— 极速版和火山版是独立安装包。

---

## 7. 还剩什么洞

诚实列一下，这些是改代码也堵不掉的：

1. **知道怎么改代码的人能自己改回去** —— 改常量、重新编译、`adb install -r`。
   这是设计上的逃生门，但它同时也是一条绕路。**别把 adb 和这份源码放在自己随手可及的地方。**
2. **手机连着电脑就能拆** —— `adb shell dpm remove-active-admin` 两条命令搞定。同理，数据线收起来。
3. **`adb install -r` 覆盖安装不校验签名一致性以外的策略**，所以升级窗口期请别改时段。
4. **Web 版抖音**：默认不管，需要就开 `ALSO_SUSPEND_BROWSERS`。
5. **时区**：`DISALLOW_CONFIG_DATE_TIME` 拦的是手动改，出差自动换时区拦不住。

---

## 8. 逃生口（拆掉守卫）

```bash
ADB="C:/Users/nj/.afs-android/sdk/platform-tools/adb.exe"
"$ADB" shell dpm remove-active-admin com.afs.guard/.AfsAdmin
"$ADB" uninstall com.afs.guard
```

`remove-active-admin` 会连带清掉所有 user restriction，所以
`DISALLOW_FACTORY_RESET` 也就一起没了。**在它生效期间你是没法在手机上做这些的。**

---

## 9. 离线回归

不需要手机，也不需要 Android 运行时：

```bash
cd phone/dpc
bash test/run.sh
```

用「逐分钟暴力扫描」当标准答案，去对 `Rule.nextFlip()` 的跳跃算法，
覆盖每天窗口、跨午夜窗口（23:00→20:00）、只选周一、只选周末四种规则，
另加多应用场景（各自时段互不影响、下次翻转取最早的）。
当前结果：**45/45 PASS**。

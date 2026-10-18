# 跨机型部署可行性

这份文档回答一个问题：**我的手机能不能用这个方案？**

先说结论：**能，但有一条硬门槛——设备上不能有任何"第二个用户"。**
多数人装不上都栽在这一条，跟机型关系不大。

---

## 1. 为什么必须是 Device Owner

要做"自己也绕不过去"的屏蔽，只有一条路：拿到系统的
`DevicePolicyManager`，用 `setPackagesSuspended()` 冻结 App。
这个能力只给 **Device Owner**（设备所有者），而 DO 只能通过两种途径获得：

- 恢复出厂后在"设置向导"阶段由 DPC 应用自己申请（Google 的
  `Managed Provisioning` 流程，需要 NFC/二维码/`afw#` 等方式）
- 或者设备上**没有任何用户数据**时，用 `adb shell dpm set-device-owner` 直接设

最省事的是第二种。它的硬性前提由 Android 源码写死，跟厂商无关：

| 条件 | 原因 | 自检命令 |
|---|---|---|
| 设备上**没有账号** | `DevicePolicyManagerService` 拒绝有账号的设备 | `adb shell dumpsys account \| grep "Account {"` |
| 只有**一个用户** | 多用户说明有分身/工作资料，DO 不允许 | `adb shell pm list users` |
| 没有已存在的 DO | 一个设备只能有一个 | `adb shell dpm list-owners` |
| Android 7.0+ (API 24) | 本应用的 minSdk | `adb shell getprop ro.build.version.sdk` |

`deploy.sh` 已经把这三条做成了自动检查，失败会直接告诉你卡在哪。

---

## 2. 机型与 ROM 的实际难度

按"踩坑概率"从低到高排。**除第一行外，其余都是根据 Android 机制推断，
不是逐台实测**——欢迎提 issue 补充你的机型结果。

| 机型 / ROM | 难度 | 说明 |
|---|---|---|
| **已实测：一加 Ace 6T / ColorOS 16 / Android 16** | 已跑通 | 恢复出厂 + 跳过手机搬家后，一次成功。**必须先清掉应用分身**（见下） |
| Pixel / 原生 Android / AOSP 类 | 低 | 没有分身概念，删账号即可 |
| 三星 One UI | 低 | 支持 DPC，Knox 与 DO 不冲突；注意"安全文件夹"算独立用户 |
| 华为 EMUI / HarmonyOS | 中 | DO 支持完整；但"隐私空间"会创建第二个用户 |
| 小米 MIUI / HyperOS | 中 | "手机分身 / 第二空间"是第二用户；另需关闭"MIUI 优化"才容易连 adb |
| vivo / iQOO OriginOS | 中 | "应用分身"同 OPPO |
| **OPPO / 一加 ColorOS** | **高** | 应用分身创建 `Type: profile.CLONE` 的 user 999，删掉分身应用后**依然残留**，`pm remove-user` / `am stop-user` / `pm clear` 全部无效，重启也不消失 |
| 部分国行精简 ROM / 定制机 | 可能不支持 | 少数 ROM 裁掉了 DPC 组件，`dpm` 命令直接不存在 |

### ColorOS 那个坑，值得单独说

这是本项目唯一实测撞过的坑，花了半天：

```
$ adb shell pm list users
Users:
    UserInfo{0:机主:4c13} running
    UserInfo{999:MultiApp:4001010} running     ← 应用分身留下的
```

- 它不是普通用户，是 `profile.CLONE`
- 把分身应用全删了，它还在
- `pm remove-user 999` → 报错；`am stop-user` → 报错；`pm clear com.oplus.multiapp` → 无效
- 重启 → 还在

**结论：ColorOS 上只要开过应用分身，且没恢复出厂，DO 就装不上。**
恢复出厂是唯一确定有效的解。

---

## 3. 最常见的三个失败与解法

### ① `Can not set up DeviceOwner because there are already several users`

有第二个用户。按顺序试：

1. 关掉应用分身 / 手机分身 / 隐私空间 / 工作资料，**重启**，再看 `pm list users`
2. 还不行 → 备份 → **恢复出厂**
3. 恢复出厂后的开机向导里：**不要点「手机搬家」「数据迁移」「从旧设备恢复」**
   —— 它会把分身配置带回来，前功尽弃

### ② `Not allowed to set the device owner because there are already some accounts`

去 `设置 → 账号` 把所有账号退掉。注意：

- Google、OPPO、小米、华为账号都算
- **任何 App 注册的账号也算**。实测：登录抖音后系统里会多出一个
  `Account {name=..., type=com.ss.android.ugc.aweme}`
- 微信、QQ、支付宝同理

### ③ `Invalid component` / `was already an admin`

上个版本的残留。先 `dpm remove-active-admin com.afs.guard/.AfsAdmin`，
再重跑 `deploy.sh`。如果 `pm list packages | grep afs.guard` 是空的却仍报这个，
是系统的 admin 记录脏了，恢复出厂。

---

## 4. 装不上的替代方案

如果恢复出厂也不愿意（数据太多、或 ROM 干脆不支持 DPC），还有两条路，
按"强度"降序：

| 方案 | 强度 | 代价 |
|---|---|---|
| **无障碍版**（`phone/blocker`） | 中：能拦、能被自己强停 | 不需要 DO，装完即用；但用户随时能在设置里关掉 |
| **Shizuku + 无障碍** | 中高：能真 `force-stop` | 每次重启要连电脑启动 Shizuku |
| 系统自带"屏幕限时" | 低 | 有"延长 15 分钟"按钮，对成瘾基本无效 |

无障碍版的取舍写在 `phone/blocker/README.md`，一句话：**它只挡"没想就点开"，
挡不住"决定拆掉它"**。

---

## 5. 什么样的机器最适合

按难度排，最省事的组合是：

1. **一台已经用了一两年、数据可以备份的安卓机**（能接受恢复出厂）
2. **没开过应用分身 / 第二空间 / 隐私空间**
3. Android 7.0 以上（本项目 minSdk 24）

如果你不想恢复出厂，先跑一遍这三条命令看有没有戏：

```bash
adb shell pm list users                          # 期望：只有 UserInfo{0:...}
adb shell dumpsys account | grep "Account {"     # 期望：无输出
adb shell dpm list-owners                        # 期望：no owners
```

三条都干净，`bash deploy.sh` 十有八九能成。

---

## 6. 想补充你的机型结果？

跑完 `deploy.sh`，把这段贴到 issue 里就够了：

```bash
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell pm list users
adb shell dpm list-owners
```

成功 / 失败 / 卡在哪个报错，都欢迎。这份表的目标是把"能不能装"从玄学变成查表。

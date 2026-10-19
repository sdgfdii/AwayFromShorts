package com.afs.guard;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.UserManager;

import java.util.Calendar;
import java.util.List;
import java.util.Map;

/**
 * 全部判定与落地逻辑都在这里，UI / 定时器 / 开机广播共用一套。
 *
 * 核心：Device Owner 的 setPackagesSuspended() 会把目标 App 直接冻结，
 * 图标变灰、点不开、后台被杀，而且没有「忽略限制」「延长 15 分钟」这种口子。
 *
 * 每个应用有自己的 {@link Rule}（放行星期 + 放行时段），判定一律按包名走。
 */
public final class Guard {

    /* ==================== 可调参数 ==================== */

    /** 默认管哪些包 —— 用户没在「添加应用」里改过就用这个 */
    public static final String[] DEFAULT_TARGETS = new String[] {
            "com.ss.android.ugc.aweme",       // 抖音
            "com.ss.android.ugc.aweme.lite",  // 抖音极速版
            "com.ss.android.ugc.live"         // 抖音火山版
    };

    /** 加固开关。想松一点就改 false 重新编译。 */
    public static final boolean BLOCK_FACTORY_RESET = true;  // 禁止恢复出厂（真正的锁死）
    public static final boolean BLOCK_SAFE_BOOT     = true;  // 禁止安全模式
    public static final boolean BLOCK_APPS_CONTROL  = true;  // 禁止设置里强停 / 卸载 / 清数据
    public static final boolean BLOCK_TIME_CHANGE   = true;  // 禁止改系统时间（否则改个钟就绕过去了）
    public static final boolean BLOCK_UNINSTALL_ALL = false; // 禁止卸载任何应用（比较狠，默认关）

    /** 只要有应用处于冻结，就把浏览器一起冻结（堵短视频网页版）。默认关。 */
    public static final boolean ALSO_SUSPEND_BROWSERS = false;

    private static final String[] BROWSERS = new String[] {
            "com.android.chrome",
            "com.coloros.browser",
            "com.heytap.browser",
            "com.android.browser",
            "com.quark.browser",
            "com.UCMobile"
    };

    /* ==================== 常量 ==================== */

    private static final int ALARM_REQ = 1001;
    private static final int JOB_ID    = 2001;
    private static final long FALLBACK_MS = 15L * 60L * 1000L;

    private Guard() {
    }

    /* ==================== 基础设施 ==================== */

    public static ComponentName admin(Context ctx) {
        return new ComponentName(ctx.getPackageName(), AfsAdmin.class.getName());
    }

    public static DevicePolicyManager dpm(Context ctx) {
        return (DevicePolicyManager) ctx.getSystemService(Context.DEVICE_POLICY_SERVICE);
    }

    public static boolean isOwner(Context ctx) {
        try {
            DevicePolicyManager d = dpm(ctx);
            return d != null && d.isDeviceOwnerApp(ctx.getPackageName());
        } catch (Throwable t) {
            return false;
        }
    }

    /* ==================== 判定（按应用） ==================== */

    /**
     * 纯判定：现在是否该冻结 = 不在自己的放行窗口里。
     * 不碰 Context —— 离线回归直接调它。
     */
    public static boolean blocked(Rule r, Calendar c) {
        return !r.inWindow(c);
    }

    /**
     * 多个应用里最早的下一次翻转。
     * 闹钟只能排一个时刻，排最早的；响了之后 apply() 会把所有应用重判一遍。
     */
    public static long nextFlipOf(java.util.Collection<Rule> rules, Calendar now) {
        long best = Long.MAX_VALUE;
        for (Rule r : rules) {
            long t = r.nextFlip(now);
            if (t < best) {
                best = t;
            }
        }
        return best == Long.MAX_VALUE ? now.getTimeInMillis() + 3600000L : best;
    }

    /**
     * 这个应用现在是否该冻结。
     * 强制模式开着 → 全部冻结；否则看它自己的窗口。
     */
    public static boolean blockedNow(Context ctx, String pkg) {
        return blocked(RuleStore.get(ctx, pkg), Calendar.getInstance());
    }

    /** 这个应用现在是否在自己的放行窗口里（不看强制模式）。 */
    public static boolean inWindowNow(Context ctx, String pkg) {
        return RuleStore.get(ctx, pkg).inWindow(Calendar.getInstance());
    }

    /**
     * 这个应用现在能不能改设置。
     *
     * ★ 只看它自己的窗口，不看强制模式 —— 否则强制模式一开就永远"锁定"，
     * 连放行时段也关不掉，自己把自己锁死。
     */
    public static boolean lockedNow(Context ctx, String pkg) {
        if (Config.inGrace(ctx)) {
            return false;
        }
        // 刚加进来的 10 分钟里允许改时段，否则上午加应用、当场锁死到 21 点
        if (RuleStore.isFresh(ctx, pkg)) {
            return false;
        }
        return !inWindowNow(ctx, pkg);
    }

    /**
     * 能不能把它移出列表。
     * ★ 只认"此刻真的在它的放行窗口里"，不吃刚加的宽限 ——
     * 否则"加进来 → 趁宽限删掉"就是一条绕过路径。
     */
    public static boolean canRemove(Context ctx, String pkg) {
        return Config.inGrace(ctx) || inWindowNow(ctx, pkg);
    }

    /** 有没有应用正处在放行窗口（决定强制模式能不能关）。 */
    public static boolean anyUnlocked(Context ctx) {
        Calendar now = Calendar.getInstance();
        for (Rule r : RuleStore.all(ctx).values()) {
            if (r.inWindow(now)) {
                return true;
            }
        }
        return false;
    }

    /** 全部应用都处于屏蔽 → 整页切深色。 */
    public static boolean allBlocked(Context ctx) {
        return !anyUnlocked(ctx);
    }

    public static int blockedCount(Context ctx) {
        Calendar now = Calendar.getInstance();
        int n = 0;
        for (Rule r : RuleStore.all(ctx).values()) {
            if (blocked(r, now)) {
                n++;
            }
        }
        return n;
    }

    /**
     * 下一次有应用要翻转状态的时刻 —— 取所有应用里最早的那个。
     *
     * 每个应用各有各的窗口，闹钟只能排最早的一个边界；响了之后
     * apply() 会把所有应用重新判一遍，并重新排下一次。
     */
    public static long nextFlipMillis(Context ctx) {
        return nextFlipOf(RuleStore.all(ctx).values(), Calendar.getInstance());
    }

    /* ==================== 落地 ==================== */

    /**
     * 按当前时间把每个目标 App 单独冻结/解冻，并补齐各项限制。
     * 幂等：反复调用没有副作用。
     */
    public static String apply(Context ctx) {
        DevicePolicyManager d = dpm(ctx);
        if (d == null) {
            return "拿不到 DevicePolicyManager";
        }
        if (!isOwner(ctx)) {
            return "尚未成为设备所有者，什么都没做。\n请先按 README 用 adb 执行 set-device-owner。";
        }

        ComponentName a = admin(ctx);
        applyRestrictions(ctx, d, a);

        Map<String, Rule> rules = RuleStore.all(ctx);
        Calendar now = Calendar.getInstance();
        boolean anyBlocked = false;
        for (Rule r : rules.values()) {
            if (blocked(r, now)) {
                anyBlocked = true;
                break;
            }
        }

        PackageManager pm = ctx.getPackageManager();
        StringBuilder sb = new StringBuilder();
        int frozen = 0;

        // 被移出列表的必须先解冻，否则它会永远停在被冻结的状态
        for (String p : RuleStore.applied(ctx)) {
            if (!rules.containsKey(p)) {
                try {
                    d.setPackagesSuspended(a, new String[] { p }, false);
                    d.setUninstallBlocked(a, p, false);
                } catch (Throwable ignored) {
                }
            }
        }

        for (Map.Entry<String, Rule> e : rules.entrySet()) {
            String pkg = e.getKey();
            Rule r = e.getValue();
            if (!installed(pm, pkg)) {
                sb.append("- ").append(pkg).append("：未安装\n");
                continue;
            }
            boolean block = blocked(r, now);
            try {
                d.setUninstallBlocked(a, pkg, true);
            } catch (Throwable ignored) {
            }
            String state;
            try {
                d.setPackagesSuspended(a, new String[] { pkg }, block);
                state = block ? "已冻结" : "放行中";
            } catch (Throwable t) {
                state = "冻结失败：" + t.getClass().getSimpleName();
            }
            if (block) {
                frozen++;
            }
            // 应用名给人看，包名方便核对是哪个版本，后面带它自己的时段
            sb.append("- ").append(labelOf(pm, pkg)).append("（").append(pkg).append("）：")
                    .append(state).append(" · ").append(r.summary()).append('\n');
        }
        RuleStore.setApplied(ctx, rules.keySet());

        if (ALSO_SUSPEND_BROWSERS) {
            for (int i = 0; i < BROWSERS.length; i++) {
                if (!installed(pm, BROWSERS[i])) {
                    continue;
                }
                try {
                    d.setPackagesSuspended(a, new String[] { BROWSERS[i] }, anyBlocked);
                    if (anyBlocked) {
                        sb.append("- ").append(BROWSERS[i]).append("：已冻结（堵网页版）\n");
                    }
                } catch (Throwable ignored) {
                }
            }
        }

        // ★ 每次 apply 都重排一次定时。package 覆盖安装会清掉所有 alarm/job，
        // 而 schedule() 原本只在开机/闹钟/Job 回调里调用 —— 装完就再也排不上了。
        schedule(ctx);

        String head = "结果：" + rules.size() + " 个应用，" + frozen + " 个冻结\n";
        return head + sb.toString();
    }

    private static void applyRestrictions(Context ctx, DevicePolicyManager d, ComponentName a) {
        add(d, a, BLOCK_FACTORY_RESET ? UserManager.DISALLOW_FACTORY_RESET : null);
        add(d, a, BLOCK_SAFE_BOOT     ? UserManager.DISALLOW_SAFE_BOOT     : null);
        add(d, a, BLOCK_APPS_CONTROL  ? UserManager.DISALLOW_APPS_CONTROL  : null);
        add(d, a, BLOCK_TIME_CHANGE   ? UserManager.DISALLOW_CONFIG_DATE_TIME : null);
        add(d, a, BLOCK_UNINSTALL_ALL ? UserManager.DISALLOW_UNINSTALL_APPS : null);
        try {
            d.setUninstallBlocked(a, ctx.getPackageName(), true);
        } catch (Throwable ignored) {
        }
        // 设备所有者可以直接给自己发精确闹钟权限，边界时刻才准
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                d.setPermissionGrantState(a, ctx.getPackageName(),
                        "android.permission.SCHEDULE_EXACT_ALARM",
                        DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);
            } catch (Throwable ignored) {
            }
        }
    }

    private static void add(DevicePolicyManager d, ComponentName a, String restriction) {
        if (restriction == null) {
            return;
        }
        try {
            d.addUserRestriction(a, restriction);
        } catch (Throwable ignored) {
        }
    }

    /** 应用名；取不到就退回包名。 */
    static String labelOf(PackageManager pm, String pkg) {
        try {
            return String.valueOf(pm.getApplicationInfo(pkg, 0).loadLabel(pm));
        } catch (Throwable t) {
            return pkg;
        }
    }

    private static boolean installed(PackageManager pm, String pkg) {
        try {
            pm.getPackageInfo(pkg, 0);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /* ==================== 定时 ==================== */

    /** 只在边界时刻各响一次 + 15 分钟 JobScheduler 兜底，不搞每分钟轮询。 */
    public static void schedule(Context ctx) {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am != null) {
            PendingIntent pi = alarms(ctx);
            long at = nextFlipMillis(ctx);
            try {
                // ★ 用 setAlarmClock：它是系统闹钟级，ColorOS 的 OplusAlarmAdjustment
                // 不敢批处理它，窗口恒为 0。setExactAndAllowWhileIdle 实测被拉成 1 小时窗口，
                // 边界会晚整整一小时才触发，放行时段等于白给。
                if (Build.VERSION.SDK_INT >= 21) {
                    am.setAlarmClock(new AlarmManager.AlarmClockInfo(at, pi), pi);
                } else if (Build.VERSION.SDK_INT >= 23) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi);
                } else {
                    am.setExact(AlarmManager.RTC_WAKEUP, at, pi);
                }
            } catch (Throwable t) {
                try {
                    am.set(AlarmManager.RTC_WAKEUP, at, pi);
                } catch (Throwable ignored) {
                }
            }
        }

        JobScheduler js = (JobScheduler) ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if (js == null) {
            return;
        }
        try {
            List<JobInfo> pending = js.getAllPendingJobs();
            for (int i = 0; i < pending.size(); i++) {
                if (pending.get(i).getId() == JOB_ID) {
                    return;
                }
            }
            JobInfo ji = new JobInfo.Builder(JOB_ID, new ComponentName(ctx, GuardJob.class))
                    .setPeriodic(FALLBACK_MS)
                    .setPersisted(true)
                    .build();
            js.schedule(ji);
        } catch (Throwable ignored) {
        }
    }

    private static PendingIntent alarms(Context ctx) {
        Intent i = new Intent(ctx, AlarmReceiver.class);
        return PendingIntent.getBroadcast(
                ctx, ALARM_REQ, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /* ==================== 展示 ==================== */

    public static String describe(Context ctx) {
        Calendar now = Calendar.getInstance();
        int total = RuleStore.count(ctx);
        int frozen = blockedCount(ctx);

        StringBuilder sb = new StringBuilder();
        sb.append("设备所有者　").append(isOwner(ctx) ? "是（已锁死）" : "否 —— 冻结不会生效").append('\n');
        sb.append("当前时间　").append(stamp(now.getTimeInMillis())).append('\n');
        sb.append("应用　　　").append(total).append(" 个，").append(frozen).append(" 个冻结中").append('\n');
        sb.append("下次切换　").append(total == 0 ? "—（没添加应用）" : stamp(nextFlipMillis(ctx))).append('\n');
        sb.append('\n');
        sb.append("加固项　").append(restrictionSummary()).append('\n');
        return sb.toString();
    }

    private static String restrictionSummary() {
        java.util.List<String> items = new java.util.ArrayList<String>();
        if (BLOCK_FACTORY_RESET) items.add("禁恢复出厂");
        if (BLOCK_SAFE_BOOT)     items.add("禁安全模式");
        if (BLOCK_APPS_CONTROL)  items.add("禁强停/清数据");
        if (BLOCK_TIME_CHANGE)   items.add("禁改时间");
        if (BLOCK_UNINSTALL_ALL) items.add("禁卸载");
        if (items.isEmpty()) {
            return "无";
        }
        // 每两项一行。(char)10 = 换行, (char)0x3000 = 全角空格
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) {
                sb.append(i % 2 == 0 ? (char) 10 : (char) 0x3000);
            }
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    public static String stamp(long millis) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(millis);
        int[] wd = { 0, 7, 1, 2, 3, 4, 5, 6 };
        String[] names = { "", "周一", "周二", "周三", "周四", "周五", "周六", "周日" };
        StringBuilder sb = new StringBuilder();
        sb.append(c.get(Calendar.MONTH) + 1).append('/')
          .append(c.get(Calendar.DAY_OF_MONTH)).append(' ')
          .append(pad2(c.get(Calendar.HOUR_OF_DAY))).append(':')
          .append(pad2(c.get(Calendar.MINUTE))).append('（')
          .append(names[wd[c.get(Calendar.DAY_OF_WEEK)]]).append('）');
        return sb.toString();
    }

    private static String pad2(int v) {
        return v < 10 ? "0" + v : String.valueOf(v);
    }
}

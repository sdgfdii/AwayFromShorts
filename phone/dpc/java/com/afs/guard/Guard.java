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

/**
 * 全部判定与落地逻辑都在这里，UI / 定时器 / 开机广播共用一套。
 *
 * 核心：Device Owner 的 setPackagesSuspended() 会把目标 App 直接冻结，
 * 图标变灰、点不开、后台被杀，而且没有「忽略限制」「延长 15 分钟」这种口子。
 */
public final class Guard {

    /* ==================== 可调参数 ==================== */

    /** 默认管哪些包 —— 用户没在「选择应用」里改过就用这个 */
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

    /** 屏蔽时段要不要连浏览器一起冻结（堵抖音网页版）。默认关，觉得有必要改成 true。 */
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

    /* ==================== 时间窗口 ==================== */

    /**
     * 现在是否屏蔽。三个来源：
     *   1) 强制模式中            → 无条件屏蔽
     *   2) 今天不在选中的星期    → 全天屏蔽
     *   3) 不在 [start, end) 里  → 屏蔽
     *
     * 跨午夜（start > end）时，"选中的星期"指窗口起始日：
     * 周一 23:00–次日 20:00 的凌晨那段，算周一的窗口。
     */
    public static boolean isBlocked(Calendar c, int daysMask, int startMin, int endMin, long forceUntil) {
        if (forceUntil > c.getTimeInMillis()) {
            return true;
        }
        int mod = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
        int s = norm(startMin);
        int e = norm(endMin);
        int today = Config.monIndex(c);
        int yesterday = (today + 6) % 7;

        if (s == e) {
            // 起止相同 = 全天放行（只对选中的星期生效）
            return !Config.daySelected(daysMask, today);
        }
        if (s < e) {
            boolean ok = Config.daySelected(daysMask, today) && mod >= s && mod < e;
            return !ok;
        }
        // 跨午夜
        boolean evening = Config.daySelected(daysMask, today) && mod >= s;
        boolean morning = Config.daySelected(daysMask, yesterday) && mod < e;
        return !(evening || morning);
    }

    /** 当前配置下是否屏蔽。 */
    public static boolean isBlockedNow(Context ctx) {
        return isBlocked(Calendar.getInstance(), Config.days(ctx),
                Config.startMin(ctx), Config.endMin(ctx), Config.forceUntil(ctx));
    }

    /**
     * 现在能不能改设置。跟 isBlocked 同义，唯一区别是：
     * 从没保存过配置时放行一次，否则装完正好落在屏蔽时段就成死锁了。
     */
    public static boolean isLockedNow(Context ctx) {
        if (!isBlockedNow(ctx)) {
            return false;
        }
        return !Config.inGrace(ctx);
    }

    /**
     * 下一次状态翻转的时刻（毫秒）。
     *
     * 逐分钟扫，最多扫 8 天。以前的"跳到下一个边界"算法在引入星期之后会算错
     * （比如只选周一，下一个边界得跳过整整六天），逐分钟扫反而简单可靠：
     * 8×1440 = 11520 次循环，微秒级，没必要优化。
     */
    public static long nextFlipMillis(Calendar now, int daysMask, int startMin, int endMin) {
        Calendar t = (Calendar) now.clone();
        t.set(Calendar.SECOND, 0);
        t.set(Calendar.MILLISECOND, 0);
        boolean cur = isBlocked(t, daysMask, startMin, endMin, 0L);
        for (int i = 0; i < 8 * 1440 + 2; i++) {
            t.add(Calendar.MINUTE, 1);
            if (isBlocked(t, daysMask, startMin, endMin, 0L) != cur) {
                return t.getTimeInMillis();
            }
        }
        return now.getTimeInMillis() + 3600000L;
    }

    private static int norm(int minuteOfDay) {
        return ((minuteOfDay % 1440) + 1440) % 1440;
    }

    /* ==================== 落地 ==================== */

    /**
     * 按当前时间把目标 App 冻结/解冻，并补齐各项限制。
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
        boolean allow = !isBlockedNow(ctx);
        applyRestrictions(ctx, d, a);

        StringBuilder sb = new StringBuilder();
        sb.append("模式：").append(allow ? "放行" : "屏蔽").append('\n');

        PackageManager pm = ctx.getPackageManager();
        java.util.Set<String> now = Targets.packages(ctx);
        java.util.Set<String> prev = Targets.applied(ctx);
        // 被移出列表的必须先解冻，否则它会永远停在被冻结的状态
        for (String p : prev) {
            if (!now.contains(p)) {
                try {
                    d.setPackagesSuspended(a, new String[] { p }, false);
                    d.setUninstallBlocked(a, p, false);
                    sb.append("- ").append(p).append("：已移出列表，解冻\n");
                } catch (Throwable ignored) {
                }
            }
        }
        for (String p : now) {
            if (!installed(pm, p)) {
                sb.append("- ").append(p).append("：未安装，跳过\n");
                continue;
            }
            try {
                d.setUninstallBlocked(a, p, true);
            } catch (Throwable ignored) {
            }
            String state;
            try {
                d.setPackagesSuspended(a, new String[] { p }, !allow);
                state = allow ? "已放行" : "已冻结";
            } catch (Throwable t) {
                state = "冻结失败：" + t.getClass().getSimpleName();
            }
            sb.append("- ").append(p).append("：").append(state).append('\n');
        }
        Targets.setApplied(ctx, now);

        if (ALSO_SUSPEND_BROWSERS && !allow) {
            for (int i = 0; i < BROWSERS.length; i++) {
                if (!installed(pm, BROWSERS[i])) {
                    continue;
                }
                try {
                    d.setPackagesSuspended(a, new String[] { BROWSERS[i] }, true);
                    sb.append("- ").append(BROWSERS[i]).append("：已冻结（堵网页版）\n");
                } catch (Throwable ignored) {
                }
            }
        } else if (ALSO_SUSPEND_BROWSERS) {
            for (int i = 0; i < BROWSERS.length; i++) {
                if (!installed(pm, BROWSERS[i])) {
                    continue;
                }
                try {
                    d.setPackagesSuspended(a, new String[] { BROWSERS[i] }, false);
                } catch (Throwable ignored) {
                }
            }
        }
        // ★ 每次 apply 都重排一次定时。package 覆盖安装会清掉所有 alarm/job，
        // 而 schedule() 原本只在开机/闹钟/Job 回调里调用 —— 装完就再也排不上了。
        schedule(ctx);
        return sb.toString();
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

    private static boolean installed(PackageManager pm, String pkg) {
        try {
            pm.getPackageInfo(pkg, 0);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /* ==================== 定时 ==================== */

    /** 只在两个边界时刻各响一次 + 15 分钟 JobScheduler 兜底，不搞每分钟轮询。 */
    public static void schedule(Context ctx) {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am != null) {
            PendingIntent pi = alarms(ctx);
            long at = nextFlipMillis(Calendar.getInstance(),
                    Config.days(ctx), Config.startMin(ctx), Config.endMin(ctx));
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
        StringBuilder sb = new StringBuilder();
        sb.append("设备所有者　").append(isOwner(ctx) ? "是（已锁死）" : "否 —— 冻结不会生效").append('\n');
        sb.append("当前时间　").append(stamp(now.getTimeInMillis())).append('\n');
        int daysMask = Config.days(ctx);
        int sm = Config.startMin(ctx);
        int em = Config.endMin(ctx);
        long force = Config.forceUntil(ctx);
        sb.append("放行星期　").append(Config.daysText(daysMask)).append('\n');
        sb.append("放行时段　").append(hm(sm / 60, sm % 60))
                .append(" - ").append(hm(em / 60, em % 60))
                .append(sm > em ? "（跨午夜）" : "").append('\n');
        if (force > now.getTimeInMillis()) {
            sb.append("强制模式　剩余 ").append(remainText(force - now.getTimeInMillis())).append('\n');
        }
        sb.append("现在状态　").append(isBlockedNow(ctx) ? "屏蔽中" : "放行中").append('\n');
        sb.append("下次切换　").append(stamp(nextFlipMillis(now, daysMask, sm, em))).append('\n');
        sb.append('\n');
        sb.append("加固项　").append(restrictionSummary()).append('\n');
        return sb.toString();
    }

    public static boolean isCrossDay(Context ctx) {
        return Config.startMin(ctx) > Config.endMin(ctx);
    }

    /** 剩余时间文案。 */
    public static String remainText(long millis) {
        if (millis <= 0) {
            return "0 分";
        }
        long totalMin = millis / 60000L;
        long h = totalMin / 60;
        long m = totalMin % 60;
        return h > 0 ? (h + " 小时 " + m + " 分") : (m + " 分");
    }

    private static String restrictionSummary() {
        StringBuilder sb = new StringBuilder();
        if (BLOCK_FACTORY_RESET) sb.append("禁恢复出厂 ");
        if (BLOCK_SAFE_BOOT)     sb.append("禁安全模式 ");
        if (BLOCK_APPS_CONTROL)  sb.append("禁强停/清数据 ");
        if (BLOCK_TIME_CHANGE)   sb.append("禁改时间 ");
        if (BLOCK_UNINSTALL_ALL) sb.append("禁卸载 ");
        String s = sb.toString().trim();
        return s.length() == 0 ? "无" : s;
    }

    public static String hm(int h, int m) {
        StringBuilder sb = new StringBuilder();
        pad(sb, h);
        sb.append(':');
        pad(sb, m);
        return sb.toString();
    }

    private static void pad(StringBuilder sb, int v) {
        if (v < 10) {
            sb.append('0');
        }
        sb.append(v);
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

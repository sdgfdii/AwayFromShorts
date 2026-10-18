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

    /** 允许使用抖音的时段（含起点，不含终点）。支持跨午夜，例如 23:00 -> 20:00 */
    public static final int ALLOW_START_H = 22;
    public static final int ALLOW_START_M = 0;
    public static final int ALLOW_END_H   = 23;
    public static final int ALLOW_END_M   = 0;

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

    public static int startMin() {
        return ALLOW_START_H * 60 + ALLOW_START_M;
    }

    public static int endMin() {
        return ALLOW_END_H * 60 + ALLOW_END_M;
    }

    public static boolean inWindow(int minuteOfDay) {
        int s = startMin();
        int e = endMin();
        if (s == e) {
            return true;
        }
        if (s < e) {
            return minuteOfDay >= s && minuteOfDay < e;
        }
        return minuteOfDay >= s || minuteOfDay < e;   // 跨午夜
    }

    public static boolean inWindow(Calendar c) {
        return inWindow(c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE));
    }

    public static boolean allowNow() {
        return inWindow(Calendar.getInstance());
    }

    /** 下一次状态翻转的时刻（毫秒）。找不到就一小时后兜底。 */
    public static long nextFlipMillis() {
        return nextFlipMillis(Calendar.getInstance());
    }

    /** 同上，但允许注入"现在"，方便离线回归测试。 */
    public static long nextFlipMillis(Calendar now) {
        boolean allow = inWindow(now);
        for (int dayOffset = 0; dayOffset <= 1; dayOffset++) {
            for (int i = 0; i < 2; i++) {
                Calendar t = (Calendar) now.clone();
                t.add(Calendar.DAY_OF_YEAR, dayOffset);
                t.set(Calendar.HOUR_OF_DAY, i == 0 ? ALLOW_START_H : ALLOW_END_H);
                t.set(Calendar.MINUTE, i == 0 ? ALLOW_START_M : ALLOW_END_M);
                t.set(Calendar.SECOND, 0);
                t.set(Calendar.MILLISECOND, 0);
                if (t.getTimeInMillis() <= now.getTimeInMillis()) {
                    continue;
                }
                if (inWindow(t) != allow) {
                    return t.getTimeInMillis();
                }
            }
        }
        return now.getTimeInMillis() + 3600000L;
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
        boolean allow = allowNow();
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
            long at = nextFlipMillis();
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
        sb.append("允许时段　").append(hm(ALLOW_START_H, ALLOW_START_M))
                .append(" - ").append(hm(ALLOW_END_H, ALLOW_END_M))
                .append(isCrossDay() ? "（跨午夜）" : "").append('\n');
        sb.append("现在状态　").append(allowNow() ? "放行中" : "屏蔽中").append('\n');
        sb.append("下次切换　").append(stamp(nextFlipMillis())).append('\n');
        sb.append('\n');
        sb.append("加固项　").append(restrictionSummary()).append('\n');
        return sb.toString();
    }

    public static boolean isCrossDay() {
        return startMin() > endMin();
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

    private static String hm(int h, int m) {
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

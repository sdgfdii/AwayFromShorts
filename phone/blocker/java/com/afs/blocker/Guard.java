package com.afs.blocker;

import java.util.Calendar;

/**
 * 纯 Java 的判定逻辑，不依赖任何 Android API —— 离线回归可以直接跑。
 *
 * 无障碍版跟 Device Owner 版的区别：
 *   DO   = 把 App 从系统层面冻结（图标变灰、点不开），但要求设备无账号且只有一个 user。
 *   这边 = 只在 App 被切到前台时把它踢回桌面。不需要 DO，不需要 Shizuku，不需要电脑。
 */
public final class Guard {

    /* ==================== 可调参数 ==================== */

    /** 允许使用的时段（含起点，不含终点）。跨午夜也支持，例如 23:00 -> 20:00 */
    public static final int ALLOW_START_H = 20;
    public static final int ALLOW_START_M = 0;
    public static final int ALLOW_END_H   = 23;
    public static final int ALLOW_END_M   = 0;

    /** 抖音三件套，漏一个等于没管 */
    public static final String[] TARGETS = new String[] {
            "com.ss.android.ugc.aweme",       // 抖音
            "com.ss.android.ugc.aweme.lite",  // 抖音极速版
            "com.ss.android.ugc.live"         // 抖音火山版
    };

    /** 屏蔽时段要不要连浏览器一起踢（堵抖音网页版）。默认关。 */
    public static final boolean ALSO_BLOCK_BROWSERS = false;

    private static final String[] BROWSERS = new String[] {
            "com.android.chrome",
            "com.coloros.browser",
            "com.heytap.browser",
            "com.android.browser",
            "com.quark.browser",
            "com.UCMobile"
    };

    /** 两次踢之间最小间隔，防止自己跟自己打架（毫秒）。 */
    public static final long KICK_COOLDOWN_MS = 1200L;

    /** 后台巡检间隔（毫秒）—— 处理"停在被管 App 里跨过窗口边界"的情况。 */
    public static final long TICK_MS = 3000L;

    private Guard() {
    }

    /* ==================== 时间窗口 ==================== */

    public static int startMin() {
        return ALLOW_START_H * 60 + ALLOW_START_M;
    }

    public static int endMin() {
        return ALLOW_END_H * 60 + ALLOW_END_M;
    }

    /** 窗口是否跨午夜（起 > 止）。起 == 止 视为全天放行。 */
    public static boolean isCrossDay() {
        return startMin() > endMin();
    }

    /** 把毫秒时刻格式化成 HH:mm，只给日志 / 回归用。 */
    public static String stamp(long millis) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(millis);
        return hhmm(c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE));
    }

    public static boolean inWindow(int minuteOfDay) {
        int s = startMin();
        int e = endMin();
        if (s == e) {
            return true;             // 起止相同 = 全天放行
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

    /** 当前时刻是否应该拦。 */
    public static boolean blockedNow() {
        return !allowNow();
    }

    /* ==================== 目标判定 ==================== */

    public static boolean isTarget(String pkg) {
        if (pkg == null) {
            return false;
        }
        for (String p : TARGETS) {
            if (p.equals(pkg)) {
                return true;
            }
        }
        if (ALSO_BLOCK_BROWSERS) {
            for (String p : BROWSERS) {
                if (p.equals(pkg)) {
                    return true;
                }
            }
        }
        return false;
    }

    /* ==================== 时间工具 ==================== */

    public static String hhmm(int minuteOfDay) {
        int m = ((minuteOfDay % 1440) + 1440) % 1440;
        return String.format("%02d:%02d", m / 60, m % 60);
    }

    public static String windowText() {
        return hhmm(startMin()) + "–" + hhmm(endMin());
    }

    /**
     * 下一次状态翻转的时刻（毫秒）。找不到就一小时后兜底。
     * 允许注入"现在"，方便离线回归用暴力扫描对拍。
     */
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

    public static long nextFlipMillis() {
        return nextFlipMillis(Calendar.getInstance());
    }
}

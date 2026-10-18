package com.afs.blocker;

import java.util.Calendar;

/**
 * 纯 Java 的判定逻辑，不 import 任何 Android 类 —— 离线回归可以直接跑。
 *
 * 三个概念，别混：
 *   inWindow  = 现在是不是放行时段（默认 20:00–23:00）
 *   blocked   = 现在要不要拦（强制模式中 或 不在放行时段）
 *   locked    = 现在能不能改设置（跟 blocked 完全一致：该拦的时候就不许改）
 */
public final class Guard {

    /** 默认放行时段，第一次装 / 没配置过时用 */
    public static final int DEFAULT_START_MIN = 20 * 60;
    public static final int DEFAULT_END_MIN = 23 * 60;

    /** 默认只管抖音三件套；用户在「选择应用」里改过就以配置为准 */
    public static final String[] DEFAULT_TARGETS = new String[] {
            "com.ss.android.ugc.aweme",       // 抖音
            "com.ss.android.ugc.aweme.lite",  // 抖音极速版
            "com.ss.android.ugc.live"         // 抖音火山版
    };

    /** 两次踢之间最小间隔，防止自己跟自己打架（毫秒）。 */
    public static final long KICK_COOLDOWN_MS = 1200L;

    /** 后台巡检间隔（毫秒）—— 处理"停在被管 App 里跨过边界"的情况。 */
    public static final long TICK_MS = 3000L;

    private Guard() {
    }

    /* ==================== 核心判定 ==================== */

    public static boolean inWindow(int minuteOfDay, int startMin, int endMin) {
        int s = norm(startMin);
        int e = norm(endMin);
        if (s == e) {
            return true;                 // 起止相同 = 全天放行
        }
        if (s < e) {
            return minuteOfDay >= s && minuteOfDay < e;
        }
        return minuteOfDay >= s || minuteOfDay < e;   // 跨午夜
    }

    /**
     * 现在要不要拦。
     *
     * 强制模式优先：只要 forceUntil 还没到，无视放行时段一律拦。
     * 这一点很关键 —— 否则「我在放行时段开了强制」会变成开着也不拦。
     */
    public static boolean isBlocked(int minuteOfDay, long nowMillis,
                                    long forceUntilMillis, int startMin, int endMin) {
        if (forceUntilMillis > nowMillis) {
            return true;
        }
        return !inWindow(minuteOfDay, startMin, endMin);
    }

    /** 现在能不能改设置。跟 isBlocked 同义，单独留个名字是为了让调用处读得懂。 */
    public static boolean isLocked(int minuteOfDay, long nowMillis,
                                   long forceUntilMillis, int startMin, int endMin) {
        return isBlocked(minuteOfDay, nowMillis, forceUntilMillis, startMin, endMin);
    }

    public static int minuteOfDay(Calendar c) {
        return c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
    }

    /* ==================== 文案 ==================== */

    public static String hhmm(int minuteOfDay) {
        int m = norm(minuteOfDay);
        return String.format("%02d:%02d", m / 60, m % 60);
    }

    public static String windowText(int startMin, int endMin) {
        return hhmm(startMin) + "–" + hhmm(endMin);
    }

    public static String remainText(long millis) {
        if (millis <= 0) {
            return "0 分";
        }
        long totalMin = millis / 60000L;
        long h = totalMin / 60;
        long m = totalMin % 60;
        if (h > 0) {
            return h + " 小时 " + m + " 分";
        }
        return m + " 分";
    }

    /* ==================== 时间工具 ==================== */

    /**
     * 下一次状态翻转的时刻（毫秒）。找不到就一小时后兜底。
     * 允许注入"现在"和窗口，方便离线回归用暴力扫描对拍。
     */
    public static long nextFlipMillis(Calendar now, int startMin, int endMin) {
        boolean allow = inWindow(minuteOfDay(now), startMin, endMin);
        int sh = norm(startMin) / 60;
        int sm = norm(startMin) % 60;
        int eh = norm(endMin) / 60;
        int em = norm(endMin) % 60;
        for (int dayOffset = 0; dayOffset <= 1; dayOffset++) {
            for (int i = 0; i < 2; i++) {
                Calendar t = (Calendar) now.clone();
                t.add(Calendar.DAY_OF_YEAR, dayOffset);
                t.set(Calendar.HOUR_OF_DAY, i == 0 ? sh : eh);
                t.set(Calendar.MINUTE, i == 0 ? sm : em);
                t.set(Calendar.SECOND, 0);
                t.set(Calendar.MILLISECOND, 0);
                if (t.getTimeInMillis() <= now.getTimeInMillis()) {
                    continue;
                }
                if (inWindow(minuteOfDay(t), startMin, endMin) != allow) {
                    return t.getTimeInMillis();
                }
            }
        }
        return now.getTimeInMillis() + 3600000L;
    }

    private static int norm(int minuteOfDay) {
        return ((minuteOfDay % 1440) + 1440) % 1440;
    }
}

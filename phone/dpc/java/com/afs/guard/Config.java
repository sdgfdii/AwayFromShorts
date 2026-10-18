package com.afs.guard;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * 时间表配置。
 *
 * days 用位图存：bit 0 = 周一 …… bit 6 = 周日（跟 Calendar 对齐时会转）。
 * 放行窗口 = 选中的星期里 [start, end) 这段；其余时间一律屏蔽。
 * start > end 表示跨午夜，此时"选中的星期"指窗口**起始日**。
 */
public final class Config {

    private static final String FILE = "afs_guard";
    private static final String K_DAYS = "days";
    private static final String K_START = "start_min";
    private static final String K_END = "end_min";
    private static final String K_FORCE = "force_on";
    private static final String K_FIRST_SEEN = "first_seen";
    private static final String K_ARMED = "armed";

    /** 默认：每天 22:00–23:00 放行 */
    private static final int DEFAULT_DAYS = 0x7F;
    private static final int DEFAULT_START = 22 * 60;
    private static final int DEFAULT_END = 23 * 60;

    private Config() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /* ---------- 星期 ---------- */

    /** 位图：bit0=周一 …… bit6=周日 */
    public static int days(Context c) {
        return sp(c).getInt(K_DAYS, DEFAULT_DAYS);
    }

    public static void setDays(Context c, int mask) {
        sp(c).edit().putInt(K_DAYS, mask & 0x7F).apply();
    }

    public static boolean daySelected(int mask, int monBasedIndex) {
        return (mask & (1 << monBasedIndex)) != 0;
    }

    /** Calendar.DAY_OF_WEEK → 0=周一 …… 6=周日 */
    public static int monIndex(java.util.Calendar c) {
        int dow = c.get(java.util.Calendar.DAY_OF_WEEK);   // 1=周日 … 7=周六
        return (dow + 5) % 7;
    }

    public static final String[] DAY_NAMES = {"一", "二", "三", "四", "五", "六", "日"};

    public static String daysText(int mask) {
        if ((mask & 0x7F) == 0x7F) {
            return "每天";
        }
        if (mask == 0) {
            return "一天都没选（等于全天屏蔽）";
        }
        if (mask == 0x1F) {
            return "工作日";
        }
        if (mask == 0x60) {
            return "周末";
        }
        StringBuilder sb = new StringBuilder();
        boolean first = true;
        for (int i = 0; i < 7; i++) {
            if ((mask & (1 << i)) != 0) {
                if (!first) {
                    sb.append("、");
                }
                sb.append("周").append(DAY_NAMES[i]);
                first = false;
            }
        }
        return sb.toString();
    }

    /* ---------- 时间 ---------- */

    public static int startMin(Context c) {
        return sp(c).getInt(K_START, DEFAULT_START);
    }

    public static int endMin(Context c) {
        return sp(c).getInt(K_END, DEFAULT_END);
    }

    public static void setWindow(Context c, int startMin, int endMin) {
        sp(c).edit().putInt(K_START, startMin).putInt(K_END, endMin).apply();
    }

    /* ---------- 强制模式 ---------- */

    /**
     * 强制模式开关。没有持续时间 —— 开了就一直强制，直到在放行时段自己关掉。
     *
     * 为什么不做"关多久"：需求是"屏蔽时段内无法关闭"，
     * 如果带时间就会变成"到点自动解除"，那是两回事。
     */
    public static boolean forceOn(Context c) {
        return sp(c).getBoolean(K_FORCE, false);
    }

    public static void setForce(Context c, boolean on) {
        sp(c).edit().putBoolean(K_FORCE, on).apply();
    }

    /* ---------- 首次宽限 ---------- */

    /** 第一次进 App 后给这么久的配置宽限，之后再按锁定规则走。 */
    public static final long GRACE_MS = 10L * 60L * 1000L;

    /**
     * 首次打开的时间戳。第一次调用时写入并返回当前时刻。
     *
     * 为什么要宽限：装完第一次打开，人往往正好落在屏蔽时段里，
     * 如果一进来就锁，连星期和时段都设不了 —— 直接死锁。
     * 给 10 分钟把星期、时段、应用都配完，之后就开始锁。
     */
    public static long firstSeenAt(Context c) {
        long v = sp(c).getLong(K_FIRST_SEEN, 0L);
        if (v <= 0L) {
            v = System.currentTimeMillis();
            sp(c).edit().putLong(K_FIRST_SEEN, v).apply();
        }
        return v;
    }

    /** 点过「立即应用」= 用户确认过了，宽限立即结束，不再等 10 分钟。 */
    public static void arm(Context c) {
        sp(c).edit().putBoolean(K_ARMED, true).apply();
    }

    public static boolean inGrace(Context c) {
        if (sp(c).getBoolean(K_ARMED, false)) {
            return false;
        }
        long first = firstSeenAt(c);
        return System.currentTimeMillis() - first < GRACE_MS;
    }
}

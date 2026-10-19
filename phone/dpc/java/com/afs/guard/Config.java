package com.afs.guard;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * 全局配置只剩"首次宽限"。
 *
 * 每个应用自己的时段在 {@link RuleStore} 里。没有强制模式——
 * 到点自动冻结、到点自动放行，全是时间表说了算，没有任何要人手动管的开关。
 */
public final class Config {

    private static final String FILE = "afs_guard";
    private static final String K_FIRST_SEEN = "first_seen";
    private static final String K_ARMED = "armed";

    private Config() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /* ---------- 首次宽限 ---------- */

    /** 第一次进 App 后给这么久的配置宽限，之后再按锁定规则走。 */
    public static final long GRACE_MS = 10L * 60L * 1000L;

    /**
     * 首次打开的时间戳。第一次调用时写入并返回当前时刻。
     *
     * 为什么要宽限：装完第一次打开，人往往正好落在屏蔽时段里，
     * 如果一进来就锁，连时段都设不了 —— 直接死锁。
     * 给 10 分钟把应用和时段都配完，之后就开始锁。
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

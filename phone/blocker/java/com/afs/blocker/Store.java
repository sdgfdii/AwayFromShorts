package com.afs.blocker;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Set;

/** SharedPreferences 的一层薄封装。所有键集中在这里，别在别处硬编码字符串。 */
public final class Store {

    private static final String FILE = "afs_blocker";
    private static final String K_TARGETS = "targets";
    private static final String K_START_MIN = "start_min";
    private static final String K_END_MIN = "end_min";
    private static final String K_FORCE_UNTIL = "force_until";

    private Store() {
    }

    public static SharedPreferences sp(Context c) {
        return c.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /** 用户没选过就返回默认的抖音三件套。 */
    public static Set<String> targets(Context c) {
        Set<String> s = sp(c).getStringSet(K_TARGETS, null);
        if (s == null || s.isEmpty()) {
            Set<String> d = new LinkedHashSet<>();
            for (String p : Guard.DEFAULT_TARGETS) {
                d.add(p);
            }
            return d;
        }
        return new HashSet<>(s);      // 复制一份，避免调用方改动内部集合
    }

    public static int targetCount(Context c) {
        return targets(c).size();
    }

    public static void setTargets(Context c, Set<String> v) {
        sp(c).edit().putStringSet(K_TARGETS, new HashSet<>(v)).apply();
    }

    public static int startMin(Context c) {
        return sp(c).getInt(K_START_MIN, Guard.DEFAULT_START_MIN);
    }

    public static int endMin(Context c) {
        return sp(c).getInt(K_END_MIN, Guard.DEFAULT_END_MIN);
    }

    public static void setWindow(Context c, int startMin, int endMin) {
        sp(c).edit().putInt(K_START_MIN, startMin).putInt(K_END_MIN, endMin).apply();
    }

    /** 强制模式结束时刻（毫秒）。0 = 没开。 */
    public static long forceUntil(Context c) {
        return sp(c).getLong(K_FORCE_UNTIL, 0L);
    }

    public static boolean forceActive(Context c) {
        return forceUntil(c) > System.currentTimeMillis();
    }

    public static void setForceUntil(Context c, long millis) {
        sp(c).edit().putLong(K_FORCE_UNTIL, millis).apply();
    }

    /** 强制模式：从现在起 durationMs 内一律拦，且不可解除。 */
    public static void startForce(Context c, long durationMs) {
        setForceUntil(c, System.currentTimeMillis() + durationMs);
        markConfigured(c);
    }

    /**
     * 是否已经"确认"过一次配置。
     * 没确认过之前不锁设置 —— 否则装完就落在屏蔽时段的话，用户连选应用都点不了。
     */
    public static boolean isConfigured(Context c) {
        return sp(c).getBoolean("configured", false);
    }

    public static void markConfigured(Context c) {
        sp(c).edit().putBoolean("configured", true).apply();
    }
}

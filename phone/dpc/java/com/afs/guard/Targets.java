package com.afs.guard;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Set;

/** 要冻结哪些 App —— 存在 SharedPreferences 里，用户选的。 */
public final class Targets {

    private static final String FILE = "afs_guard";
    private static final String K_TARGETS = "targets";
    private static final String K_APPLIED = "applied";

    private Targets() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /** 没选过就返回默认的抖音三件套。 */
    public static Set<String> packages(Context c) {
        Set<String> s = sp(c).getStringSet(K_TARGETS, null);
        if (s == null || s.isEmpty()) {
            Set<String> d = new LinkedHashSet<>();
            for (String p : Guard.DEFAULT_TARGETS) {
                d.add(p);
            }
            return d;
        }
        return new HashSet<>(s);
    }

    public static int count(Context c) {
        return packages(c).size();
    }

    public static void setPackages(Context c, Set<String> v) {
        sp(c).edit().putStringSet(K_TARGETS, new HashSet<>(v)).apply();
    }

    /** 上一次真正应用过的列表 —— 用来把"被移出列表"的 App 解冻。 */
    public static Set<String> applied(Context c) {
        Set<String> s = sp(c).getStringSet(K_APPLIED, null);
        return s == null ? new HashSet<String>() : new HashSet<>(s);
    }

    public static void setApplied(Context c, Set<String> v) {
        sp(c).edit().putStringSet(K_APPLIED, new HashSet<>(v)).apply();
    }
}

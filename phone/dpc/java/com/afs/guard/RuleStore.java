package com.afs.guard;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONObject;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

/**
 * 每个应用各自的放行规则，按包名存在 SharedPreferences 里（一个 JSON）。
 *
 * 为什么不用 N 个 key：规则是整块读写的，拆成一堆 "rule.<pkg>.start"
 * 之后删应用容易漏字段，一个 JSON 更好维护。
 */
public final class RuleStore {

    private static final String FILE = "afs_guard";
    private static final String K_RULES = "rules";
    private static final String K_APPLIED = "applied";
    private static final String K_LAST = "last_rule";

    /** 新加的应用默认用这个：每天 21:00–23:00。 */
    public static final int FALLBACK_START = 21 * 60;
    public static final int FALLBACK_END = 23 * 60;

    /**
     * 新加应用后的可编辑窗口。
     *
     * 不加这个会很难用：默认规则是 21:00–23:00，你在上午加一个应用，
     * 它当场就被判成"在屏蔽时间里"，那张卡立刻变灰 —— 你连时段都设不了，
     * 得等到自己的 21 点。所以刚加的 10 分钟里允许改时段。
     * ★ 但**移除**不吃这个宽限（见 Guard.canRemove），否则删掉就等于绕过了。
     */
    public static final long NEW_GRACE_MS = 10L * 60L * 1000L;

    private RuleStore() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /* ---------- 读 ---------- */

    public static Map<String, Rule> all(Context c) {
        migrate(c);
        Map<String, Rule> m = new LinkedHashMap<>();
        String raw = sp(c).getString(K_RULES, "");
        try {
            JSONObject o = new JSONObject(raw.length() == 0 ? "{}" : raw);
            Iterator<String> it = o.keys();
            while (it.hasNext()) {
                String pkg = it.next();
                JSONObject r = o.optJSONObject(pkg);
                if (r == null) {
                    continue;
                }
                m.put(pkg, parseRule(r));
            }
        } catch (Throwable ignored) {
        }
        return m;
    }

    public static Set<String> packages(Context c) {
        return new LinkedHashSet<>(all(c).keySet());
    }

    public static int count(Context c) {
        return all(c).size();
    }

    /** 取某个应用的规则；没有就退回默认（不会写盘）。 */
    public static Rule get(Context c, String pkg) {
        Rule r = all(c).get(pkg);
        return r != null ? r : defaultRule(c);
    }

    /** 新加应用时使用的规则：上次改过的那个，没有就用兜底。 */
    public static Rule defaultRule(Context c) {
        String raw = sp(c).getString(K_LAST, "");
        try {
            JSONObject o = new JSONObject(raw);
            return new Rule(o.optInt("d", Rule.ALL_DAYS),
                    o.optInt("s", FALLBACK_START),
                    o.optInt("e", FALLBACK_END));
        } catch (Throwable ignored) {
            return new Rule(Rule.ALL_DAYS, FALLBACK_START, FALLBACK_END);
        }
    }

    /* ---------- 写 ---------- */

    public static void put(Context c, String pkg, Rule r) {
        Map<String, Rule> m = all(c);
        boolean fresh = !m.containsKey(pkg);
        m.put(pkg, r);
        save(c, m);
        if (fresh) {
            markAdded(c, pkg);
        }
        setLast(c, r);
    }

    /* ---------- 新加应用的时间戳 ---------- */

    public static void markAdded(Context c, String pkg) {
        try {
            JSONObject o = raw(c);
            JSONObject r = o.optJSONObject(pkg);
            if (r == null) {
                r = new JSONObject();
                o.put(pkg, r);
            }
            r.put("at", System.currentTimeMillis());
            sp(c).edit().putString(K_RULES, o.toString()).apply();
        } catch (Throwable ignored) {
        }
    }

    public static long addedAt(Context c, String pkg) {
        try {
            JSONObject r = raw(c).optJSONObject(pkg);
            return r == null ? 0L : r.optLong("at", 0L);
        } catch (Throwable ignored) {
            return 0L;
        }
    }

    /** 刚加进来还没过宽限期。 */
    public static boolean isFresh(Context c, String pkg) {
        long at = addedAt(c, pkg);
        return at > 0L && System.currentTimeMillis() - at < NEW_GRACE_MS;
    }

    /** 解析一条规则：v2 是 w=[[s,e],...]，v1 是 s/e 单段（老用户升级自动迁移）。 */
    private static Rule parseRule(JSONObject r) {
        int days = r.optInt("d", Rule.ALL_DAYS);
        org.json.JSONArray w = r.optJSONArray("w");
        if (w != null && w.length() > 0) {
            int[][] wins = new int[w.length()][2];
            int n = 0;
            for (int i = 0; i < w.length(); i++) {
                org.json.JSONArray seg = w.optJSONArray(i);
                if (seg != null && seg.length() >= 2) {
                    wins[n][0] = seg.optInt(0);
                    wins[n][1] = seg.optInt(1);
                    n++;
                }
            }
            if (n > 0) {
                int[][] trimmed = new int[n][2];
                System.arraycopy(wins, 0, trimmed, 0, n);
                return new Rule(days, trimmed);
            }
            return new Rule(days, new int[0][2]);   // 显式清空 = 整天冻结
        }
        return new Rule(days, r.optInt("s", FALLBACK_START), r.optInt("e", FALLBACK_END));
    }

    private static JSONObject raw(Context c) {
        String s = sp(c).getString(K_RULES, "");
        try {
            return new JSONObject(s.length() == 0 ? "{}" : s);
        } catch (Throwable t) {
            return new JSONObject();
        }
    }

    public static void remove(Context c, String pkg) {
        Map<String, Rule> m = all(c);
        m.remove(pkg);
        save(c, m);
    }

    private static void save(Context c, Map<String, Rule> m) {
        JSONObject old = raw(c);
        JSONObject o = new JSONObject();
        try {
            for (Map.Entry<String, Rule> e : m.entrySet()) {
                JSONObject r = new JSONObject();
                r.put("d", e.getValue().days);
                org.json.JSONArray w = new org.json.JSONArray();
                for (int i = 0; i < e.getValue().windowCount(); i++) {
                    org.json.JSONArray seg = new org.json.JSONArray();
                    seg.put(e.getValue().startAt(i));
                    seg.put(e.getValue().endAt(i));
                    w.put(seg);
                }
                r.put("w", w);
                // 新加应用的时间戳要留着，否则每次改时段都会重新给一次宽限
                JSONObject prev = old.optJSONObject(e.getKey());
                if (prev != null && prev.has("at")) {
                    r.put("at", prev.optLong("at", 0L));
                }
                o.put(e.getKey(), r);
            }
        } catch (Throwable ignored) {
        }
        sp(c).edit().putString(K_RULES, o.toString()).apply();
    }

    private static void setLast(Context c, Rule r) {
        try {
            JSONObject o = new JSONObject();
            o.put("d", r.days);
            org.json.JSONArray w = new org.json.JSONArray();
            for (int i = 0; i < r.windowCount(); i++) {
                org.json.JSONArray seg = new org.json.JSONArray();
                seg.put(r.startAt(i));
                seg.put(r.endAt(i));
                w.put(seg);
            }
            o.put("w", w);
            sp(c).edit().putString(K_LAST, o.toString()).apply();
        } catch (Throwable ignored) {
        }
    }

    /* ---------- 上一次真正应用过谁（用来把移出的应用解冻） ---------- */

    public static Set<String> applied(Context c) {
        Set<String> s = sp(c).getStringSet(K_APPLIED, null);
        return s == null ? new LinkedHashSet<String>() : new LinkedHashSet<>(s);
    }

    public static void setApplied(Context c, Set<String> v) {
        sp(c).edit().putStringSet(K_APPLIED, new LinkedHashSet<>(v)).apply();
    }

    /* ---------- 老配置迁移 ---------- */

    /**
     * 旧版只有一个全局时段（days / start_min / end_min + targets 列表）。
     * 第一次读到新存储时把它铺成"每个应用一条同样的规则"，
     * 用户打开 App 看到的就是原来的行为，不需要重新配。
     */
    private static void migrate(Context c) {
        SharedPreferences p = sp(c);
        if (p.contains(K_RULES)) {
            return;
        }
        int d = p.getInt("days", Rule.ALL_DAYS);
        int s = p.getInt("start_min", FALLBACK_START);
        int e = p.getInt("end_min", FALLBACK_END);
        Rule r = new Rule(d, s, e);

        Set<String> old = p.getStringSet("targets", null);
        Map<String, Rule> m = new LinkedHashMap<>();
        if (old != null && !old.isEmpty()) {
            for (String pkg : old) {
                m.put(pkg, r);
            }
        }
        if (m.isEmpty()) {
            for (String pkg : Guard.DEFAULT_TARGETS) {
                m.put(pkg, r);
            }
        }
        save(c, m);
    }
}

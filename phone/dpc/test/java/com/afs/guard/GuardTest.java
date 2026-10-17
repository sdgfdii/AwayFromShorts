package com.afs.guard;

import java.util.Calendar;

/**
 * 离线回归 —— 不连手机、不需要 Android 运行时。
 * 用「逐分钟暴力扫描」当标准答案，去对 nextFlipMillis 的跳跃算法。
 */
public final class GuardTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        int s = Guard.startMin();
        int e = Guard.endMin();
        boolean cross = Guard.isCrossDay();
        System.out.println("窗口 " + Guard.startMin() + "-" + Guard.endMin()
                + " 分钟 (" + hhmm(s) + " -> " + hhmm(e) + ")"
                + (cross ? " 跨午夜" : ""));

        // ---- 边界点 ----
        // 不论是否跨午夜：终点前一分钟一定在窗口内，起点前一分钟一定在窗口外
        int beforeEnd = (e + 1439) % 1440;
        int beforeStart = (s + 1439) % 1440;
        eq(Guard.inWindow(beforeEnd), true, hhmm(beforeEnd) + " 终点前一分钟（窗口内）");
        eq(Guard.inWindow(e), false, hhmm(e) + " 窗口终点（屏蔽）");
        eq(Guard.inWindow(s), true, hhmm(s) + " 窗口起点（放行）");
        eq(Guard.inWindow(beforeStart), false, hhmm(beforeStart) + " 起点前一分钟（屏蔽）");

        // ---- 每天 1440 分钟逐点对拍，连续 3 天 ----
        Calendar base = Calendar.getInstance();
        base.set(2026, Calendar.OCTOBER, 17, 0, 0, 0);
        base.set(Calendar.MILLISECOND, 0);

        int cases = 0;
        int mismatch = 0;
        for (int d = 0; d < 3; d++) {
            for (int m = 0; m < 1440; m++) {
                Calendar now = (Calendar) base.clone();
                now.add(Calendar.DAY_OF_YEAR, d);
                now.add(Calendar.MINUTE, m);
                long got = Guard.nextFlipMillis(now);
                long want = brute(now);
                cases++;
                if (got != want) {
                    mismatch++;
                    if (mismatch <= 5) {
                        System.out.println("  MISMATCH at " + Guard.stamp(now.getTimeInMillis())
                                + " got=" + Guard.stamp(got) + " want=" + Guard.stamp(want));
                    }
                }
            }
        }
        ok(mismatch == 0, "nextFlip 对拍 " + cases + " 个时间点，失配 " + mismatch);

        // ---- 翻转点本身必须真的翻转 ----
        int bad = 0;
        for (int d = 0; d < 3; d++) {
            for (int m = 0; m < 1440; m++) {
                Calendar now = (Calendar) base.clone();
                now.add(Calendar.DAY_OF_YEAR, d);
                now.add(Calendar.MINUTE, m);
                long flip = Guard.nextFlipMillis(now);
                Calendar f = Calendar.getInstance();
                f.setTimeInMillis(flip);
                Calendar before = Calendar.getInstance();
                before.setTimeInMillis(flip - 60000L);
                if (Guard.inWindow(f) == Guard.inWindow(before)) {
                    bad++;
                }
            }
        }
        ok(bad == 0, "翻转点前后状态确实不同（检查 " + cases + " 个点，异常 " + bad + "）");

        // ---- 时段覆盖：全天必须恰好有一段连续放行 ----
        int allowMin = 0;
        int runs = 0;
        boolean prev = Guard.inWindow(1439);
        for (int m = 0; m < 1440; m++) {
            boolean cur = Guard.inWindow(m);
            if (cur) {
                allowMin++;
            }
            if (cur != prev) {
                runs++;
            }
            prev = cur;
        }
        eq(runs, 2, "全天状态切换次数为 2（一进一出）");
        eq(allowMin, (e - s + 1440) % 1440 == 0 ? 1440 : (e - s + 1440) % 1440,
                "放行总分钟数 = 窗口长度");

        // ---- 展示格式 ----
        Calendar t = (Calendar) base.clone();
        t.add(Calendar.DAY_OF_YEAR, 1);
        t.add(Calendar.MINUTE, 20 * 60);
        String st = Guard.stamp(t.getTimeInMillis());
        ok(st.contains("20:00"), "stamp 输出含 20:00 → " + st);

        System.out.println();
        System.out.println("== " + pass + " PASS / " + fail + " FAIL ==");
        if (fail > 0) {
            System.exit(1);
        }
    }

    /** 标准答案：从 now 起逐分钟走，第一次状态变化的那一分钟。 */
    private static long brute(Calendar now) {
        Calendar t = (Calendar) now.clone();
        t.set(Calendar.SECOND, 0);
        t.set(Calendar.MILLISECOND, 0);
        boolean cur = Guard.inWindow(t);
        for (int i = 0; i < 48 * 60; i++) {
            t.add(Calendar.MINUTE, 1);
            if (Guard.inWindow(t) != cur) {
                return t.getTimeInMillis();
            }
        }
        return -1L;
    }

    private static String hhmm(int min) {
        int m = ((min % 1440) + 1440) % 1440;
        String h = String.valueOf(m / 60);
        String mm = String.valueOf(m % 60);
        return (h.length() < 2 ? "0" + h : h) + ":" + (mm.length() < 2 ? "0" + mm : mm);
    }

    private static void eq(int got, int want, String name) {
        ok(got == want, name + "（got=" + got + " want=" + want + "）");
    }

    private static void eq(boolean got, boolean want, String name) {
        ok(got == want, name + "（got=" + got + " want=" + want + "）");
    }

    private static void ok(boolean cond, String name) {
        if (cond) {
            pass++;
            System.out.println("  OK   " + name);
        } else {
            fail++;
            System.out.println("  FAIL " + name);
        }
    }
}

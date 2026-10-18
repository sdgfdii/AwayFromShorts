package com.afs.blocker;

import java.util.Calendar;

/**
 * 离线回归 —— 不连手机、不需要 Android 运行时。
 *
 * Guard 现在是纯参数化的（窗口从外面传进来），所以不用改常量重编第二份，
 * 直接在一个进程里把多套窗口各跑一遍。
 */
public final class GuardTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        // 默认窗口 + 跨午夜窗口
        runConfig(20 * 60, 23 * 60);
        runConfig(23 * 60, 20 * 60);

        forceTests();

        System.out.println();
        System.out.println("== " + pass + " PASS / " + fail + " FAIL ==");
        if (fail > 0) {
            System.exit(1);
        }
    }

    /* ==================== 窗口 ==================== */

    private static void runConfig(int s, int e) {
        boolean cross = s > e;
        System.out.println("---- 窗口 " + Guard.hhmm(s) + " -> " + Guard.hhmm(e)
                + (cross ? "（跨午夜）" : "") + " ----");

        int beforeEnd = (e + 1439) % 1440;
        int beforeStart = (s + 1439) % 1440;
        eq(Guard.inWindow(beforeEnd, s, e), true, Guard.hhmm(beforeEnd) + " 终点前一分钟（窗口内）");
        eq(Guard.inWindow(e, s, e), false, Guard.hhmm(e) + " 窗口终点（屏蔽）");
        eq(Guard.inWindow(s, s, e), true, Guard.hhmm(s) + " 窗口起点（放行）");
        eq(Guard.inWindow(beforeStart, s, e), false, Guard.hhmm(beforeStart) + " 起点前一分钟（屏蔽）");

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
                long got = Guard.nextFlipMillis(now, s, e);
                long want = brute(now, s, e);
                cases++;
                if (got != want) {
                    mismatch++;
                    if (mismatch <= 5) {
                        System.out.println("  MISMATCH at " + stamp(now.getTimeInMillis())
                                + " got=" + stamp(got) + " want=" + stamp(want));
                    }
                }
            }
        }
        ok(mismatch == 0, "nextFlip 对拍 " + cases + " 个时间点，失配 " + mismatch);

        int bad = 0;
        for (int d = 0; d < 3; d++) {
            for (int m = 0; m < 1440; m++) {
                Calendar now = (Calendar) base.clone();
                now.add(Calendar.DAY_OF_YEAR, d);
                now.add(Calendar.MINUTE, m);
                long flip = Guard.nextFlipMillis(now, s, e);
                Calendar f = Calendar.getInstance();
                f.setTimeInMillis(flip);
                Calendar before = Calendar.getInstance();
                before.setTimeInMillis(flip - 60000L);
                if (Guard.inWindow(Guard.minuteOfDay(f), s, e)
                        == Guard.inWindow(Guard.minuteOfDay(before), s, e)) {
                    bad++;
                }
            }
        }
        ok(bad == 0, "翻转点前后状态确实不同（检查 " + cases + " 个点，异常 " + bad + "）");

        int allowMin = 0;
        int runs = 0;
        boolean prev = Guard.inWindow(1439, s, e);
        for (int m = 0; m < 1440; m++) {
            boolean cur = Guard.inWindow(m, s, e);
            if (cur) {
                allowMin++;
            }
            if (cur != prev) {
                runs++;
            }
            prev = cur;
        }
        eq(runs, 2, "全天状态切换次数为 2（一进一出）");
        int wantMin = ((e - s) % 1440 + 1440) % 1440;
        eq(allowMin, wantMin, "放行总分钟数 = " + wantMin);

        // 拦截 = 不在窗口，且没有强制模式
        eq(Guard.isBlocked(720, 0L, 0L, s, e), !Guard.inWindow(720, s, e),
                "12:00 的拦截状态与窗口一致（无强制）");
    }

    /* ==================== 强制模式 ==================== */

    private static void forceTests() {
        System.out.println("---- 强制模式 ----");
        int s = 20 * 60;
        int e = 23 * 60;
        long now = 1_000_000L;

        // 屏蔽时段 + 强制：仍然拦
        eq(Guard.isBlocked(12 * 60, now, now + 3600_000L, s, e), true,
                "屏蔽时段里开强制 → 拦");

        // ★ 关键语义：放行时段里开强制，也必须拦
        eq(Guard.isBlocked(21 * 60, now, now + 3600_000L, s, e), true,
                "★ 放行时段里开强制 → 仍然拦（否则等于没开）");

        // 放行时段 + 强制已过期：放行
        eq(Guard.isBlocked(21 * 60, now, now - 1L, s, e), false,
                "放行时段 + 强制已过期 → 放行");

        // 过期后回到窗口逻辑
        eq(Guard.isBlocked(12 * 60, now, now - 1L, s, e), true,
                "强制过期后回到窗口逻辑（12:00 仍拦）");

        // 强制结束时刻等于现在 = 已过期
        eq(Guard.isBlocked(21 * 60, now, now, s, e), false,
                "forceUntil == now 视为已结束");

        // 锁定与拦截必须同步
        eq(Guard.isLocked(21 * 60, now, now + 1L, s, e),
                Guard.isBlocked(21 * 60, now, now + 1L, s, e),
                "isLocked 与 isBlocked 同步（放行时段 + 强制中）");

        // 文案
        ok(Guard.remainText(3600_000L).contains("1 小时"), "remainText 1h → " + Guard.remainText(3600_000L));
        ok(Guard.remainText(90 * 60_000L).contains("1 小时"), "remainText 90min → " + Guard.remainText(90 * 60_000L));
        ok(Guard.remainText(0).contains("0"), "remainText 0 → " + Guard.remainText(0));
    }

    /* ==================== 工具 ==================== */

    /** 标准答案：从 now 起逐分钟走，第一次状态变化的那一分钟。 */
    private static long brute(Calendar now, int s, int e) {
        Calendar t = (Calendar) now.clone();
        t.set(Calendar.SECOND, 0);
        t.set(Calendar.MILLISECOND, 0);
        boolean cur = Guard.inWindow(Guard.minuteOfDay(t), s, e);
        for (int i = 0; i < 48 * 60; i++) {
            t.add(Calendar.MINUTE, 1);
            if (Guard.inWindow(Guard.minuteOfDay(t), s, e) != cur) {
                return t.getTimeInMillis();
            }
        }
        return -1L;
    }

    private static String stamp(long millis) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(millis);
        return Guard.hhmm(Guard.minuteOfDay(c));
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

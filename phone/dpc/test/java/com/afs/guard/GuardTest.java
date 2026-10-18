package com.afs.guard;

import java.util.Calendar;

/**
 * 离线回归 —— 不连手机、不需要 Android 运行时。
 *
 * Guard 的时间判定现在是参数化的（星期掩码 + 起止分钟），一个进程里就能把
 * 多套配置都跑一遍，不用再靠 sed 改常量重编第二份。
 */
public final class GuardTest {

    private static int pass = 0;
    private static int fail = 0;

    public static void main(String[] args) {
        everyDay();
        crossMidnight();
        onlyMonday();
        weekendOnly();
        forceTests();
        textTests();

        System.out.println();
        System.out.println("== " + pass + " PASS / " + fail + " FAIL ==");
        if (fail > 0) {
            System.exit(1);
        }
    }

    /* ---------- 1. 每天 22:00–23:00 ---------- */

    private static void everyDay() {
        System.out.println("---- 每天 22:00–23:00 ----");
        int days = 0x7F;
        int s = 22 * 60;
        int e = 23 * 60;

        // 2026-10-19 是周一
        eq(blocked(days, s, e, 2026, 10, 19, 21, 59), true, "周一 21:59 屏蔽");
        eq(blocked(days, s, e, 2026, 10, 19, 22, 0), false, "周一 22:00 放行");
        eq(blocked(days, s, e, 2026, 10, 19, 22, 59), false, "周一 22:59 放行");
        eq(blocked(days, s, e, 2026, 10, 19, 23, 0), true, "周一 23:00 屏蔽");
        eq(blocked(days, s, e, 2026, 10, 25, 12, 0), true, "周日 12:00 屏蔽");

        int allowMin = 0;
        for (int m = 0; m < 1440; m++) {
            if (!blocked(days, s, e, 2026, 10, 19, m / 60, m % 60)) {
                allowMin++;
            }
        }
        eq(allowMin, 60, "每天放行恰好 60 分钟");

        flipProperty(days, s, e);
    }

    /* ---------- 2. 跨午夜 23:00–20:00 ---------- */

    private static void crossMidnight() {
        System.out.println("---- 每天 23:00–次日 20:00（跨午夜）----");
        int days = 0x7F;
        int s = 23 * 60;
        int e = 20 * 60;

        eq(blocked(days, s, e, 2026, 10, 19, 22, 59), true, "周一 22:59 屏蔽");
        eq(blocked(days, s, e, 2026, 10, 19, 23, 0), false, "周一 23:00 放行");
        eq(blocked(days, s, e, 2026, 10, 20, 3, 0), false, "周二 03:00 仍在放行（属于周一窗口）");
        eq(blocked(days, s, e, 2026, 10, 20, 19, 59), false, "周二 19:59 放行");
        eq(blocked(days, s, e, 2026, 10, 20, 20, 0), true, "周二 20:00 屏蔽");

        int allowMin = 0;
        for (int m = 0; m < 1440; m++) {
            if (!blocked(days, s, e, 2026, 10, 19, m / 60, m % 60)) {
                allowMin++;
            }
        }
        eq(allowMin, 21 * 60, "每天放行 21 小时（1260 分）");

        flipProperty(days, s, e);
    }

    /* ---------- 3. 只选周一 ---------- */

    private static void onlyMonday() {
        System.out.println("---- 只选周一 22:00–23:00 ----");
        int days = 1;
        int s = 22 * 60;
        int e = 23 * 60;

        eq(blocked(days, s, e, 2026, 10, 19, 22, 30), false, "周一 22:30 放行");
        eq(blocked(days, s, e, 2026, 10, 20, 22, 30), true, "周二 22:30 屏蔽（未选周二）");
        eq(blocked(days, s, e, 2026, 10, 25, 22, 30), true, "周日 22:30 屏蔽");
        eq(blocked(days, s, e, 2026, 10, 20, 12, 0), true, "周二中午 屏蔽");

        Calendar now = at(2026, 10, 19, 22, 30);
        long flip = Guard.nextFlipMillis(now, days, s, e);
        Calendar f = Calendar.getInstance();
        f.setTimeInMillis(flip);
        eq(Guard.hm(f.get(Calendar.HOUR_OF_DAY), f.get(Calendar.MINUTE)), "23:00",
                "周一 22:30 的下次翻转是当天 23:00");

        Calendar now2 = at(2026, 10, 19, 23, 30);
        long flip2 = Guard.nextFlipMillis(now2, days, s, e);
        Calendar f2 = Calendar.getInstance();
        f2.setTimeInMillis(flip2);
        eq(Guard.hm(f2.get(Calendar.HOUR_OF_DAY), f2.get(Calendar.MINUTE)), "22:00",
                "周一 23:30 的下次翻转是 22:00");
        eq(f2.get(Calendar.DAY_OF_MONTH), 26, "而且落在下周一（10/26）而不是本周二");
    }

    /* ---------- 4. 只选周末 ---------- */

    private static void weekendOnly() {
        System.out.println("---- 只选周六日 22:00–23:00 ----");
        int days = 0x60;
        int s = 22 * 60;
        int e = 23 * 60;

        eq(blocked(days, s, e, 2026, 10, 24, 22, 30), false, "周六 22:30 放行");
        eq(blocked(days, s, e, 2026, 10, 25, 22, 30), false, "周日 22:30 放行");
        eq(blocked(days, s, e, 2026, 10, 23, 22, 30), true, "周五 22:30 屏蔽");
    }

    /* ---------- 5. 强制模式 ---------- */

    private static void forceTests() {
        System.out.println("---- 强制模式（开关式，无持续时间）----");
        int days = 0x7F;
        int s = 22 * 60;
        int e = 23 * 60;

        Calendar inWin = at(2026, 10, 19, 22, 30);
        Calendar outWin = at(2026, 10, 19, 12, 0);

        eq(Guard.isBlocked(inWin, days, s, e, true), true,
                "★ 放行时段 + 强制 → 仍然屏蔽");
        eq(Guard.isBlocked(outWin, days, s, e, true), true,
                "屏蔽时段 + 强制 → 屏蔽");
        eq(Guard.isBlocked(inWin, days, s, e, false), false,
                "放行时段 + 未强制 → 放行");
        eq(Guard.isBlocked(outWin, days, s, e, false), true,
                "屏蔽时段 + 未强制 → 屏蔽");

        // 锁定只看时间表：强制模式下，放行时段仍然要能关掉自己
        ok(!Guard.isBlocked(inWin, days, s, e, false),
                "锁定判定用 inWindow：强制中但处在放行窗口 → 不锁（否则关不掉）");
    }

    /* ---------- 6. 文案 ---------- */

    private static void textTests() {
        System.out.println("---- 文案 ----");
        eq(Config.daysText(0x7F), "每天", "0x7F → 每天");
        eq(Config.daysText(0x1F), "工作日", "0x1F → 工作日");
        eq(Config.daysText(0x60), "周末", "0x60 → 周末");
        eq(Config.daysText(0x41), "周一、周日", "0x41 → 周一、周日");
        ok(Config.daysText(0).contains("全天屏蔽"), "0 → 提示全天屏蔽");
        ok(Guard.remainText(3600_000L).contains("1 小时"), "remainText 1h");
        eq(Guard.hm(22, 0), "22:00", "hm 格式化");
    }

    /* ---------- 工具 ---------- */

    private static void flipProperty(int days, int s, int e) {
        int bad = 0;
        int notFuture = 0;
        for (int d = 19; d <= 25; d++) {
            for (int m = 0; m < 1440; m += 7) {
                Calendar now = at(2026, 10, d, m / 60, m % 60);
                long flip = Guard.nextFlipMillis(now, days, s, e);
                if (flip <= now.getTimeInMillis()) {
                    notFuture++;
                }
                Calendar f = Calendar.getInstance();
                f.setTimeInMillis(flip);
                Calendar before = Calendar.getInstance();
                before.setTimeInMillis(flip - 60000L);
                if (Guard.isBlocked(f, days, s, e, false) == Guard.isBlocked(before, days, s, e, false)) {
                    bad++;
                }
            }
        }
        ok(bad == 0, "翻转点前后状态确实不同（异常 " + bad + "）");
        ok(notFuture == 0, "翻转点严格晚于当前时刻（异常 " + notFuture + "）");
    }

    private static boolean blocked(int days, int s, int e, int y, int mo, int d, int hh, int mm) {
        return Guard.isBlocked(at(y, mo, d, hh, mm), days, s, e, false);
    }

    private static Calendar at(int y, int mo, int d, int hh, int mm) {
        Calendar c = Calendar.getInstance();
        c.set(y, mo - 1, d, hh, mm, 0);
        c.set(Calendar.MILLISECOND, 0);
        return c;
    }

    private static void eq(int got, int want, String name) {
        ok(got == want, name + "（got=" + got + " want=" + want + "）");
    }

    private static void eq(boolean got, boolean want, String name) {
        ok(got == want, name + "（got=" + got + " want=" + want + "）");
    }

    private static void eq(String got, String want, String name) {
        ok(got != null && got.equals(want), name + "（got=" + got + " want=" + want + "）");
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

package com.afs.guard;

import java.util.Arrays;
import java.util.Calendar;

/**
 * 离线回归 —— 不连手机、不需要 Android 运行时。
 *
 * 判定已经完全参数化：每个应用一个 {@link Rule}（星期掩码 + 起止分钟），
 * 一个进程里就能把多套规则、多个应用一起跑，不用 sed 改常量重编第二份。
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
        multiApp();
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
        Rule r = new Rule(0x7F, 22 * 60, 23 * 60);

        eq(blocked(r, 2026, 10, 19, 21, 59), true, "周一 21:59 屏蔽");
        eq(blocked(r, 2026, 10, 19, 22, 0), false, "周一 22:00 放行");
        eq(blocked(r, 2026, 10, 19, 22, 59), false, "周一 22:59 放行");
        eq(blocked(r, 2026, 10, 19, 23, 0), true, "周一 23:00 屏蔽");
        eq(blocked(r, 2026, 10, 25, 12, 0), true, "周日 12:00 屏蔽");

        int allowMin = 0;
        for (int m = 0; m < 1440; m++) {
            if (r.inWindow(at(2026, 10, 19, m / 60, m % 60))) {
                allowMin++;
            }
        }
        eq(allowMin, 60, "每天放行恰好 60 分钟");

        flipProperty(r);
    }

    /* ---------- 2. 跨午夜 23:00–20:00 ---------- */

    private static void crossMidnight() {
        System.out.println("---- 每天 23:00–次日 20:00（跨午夜）----");
        Rule r = new Rule(0x7F, 23 * 60, 20 * 60);

        eq(blocked(r, 2026, 10, 19, 22, 59), true, "周一 22:59 屏蔽");
        eq(blocked(r, 2026, 10, 19, 23, 0), false, "周一 23:00 放行");
        eq(blocked(r, 2026, 10, 20, 3, 0), false, "周二 03:00 仍在放行（属于周一窗口）");
        eq(blocked(r, 2026, 10, 20, 19, 59), false, "周二 19:59 放行");
        eq(blocked(r, 2026, 10, 20, 20, 0), true, "周二 20:00 屏蔽");

        int allowMin = 0;
        for (int m = 0; m < 1440; m++) {
            if (r.inWindow(at(2026, 10, 19, m / 60, m % 60))) {
                allowMin++;
            }
        }
        eq(allowMin, 21 * 60, "每天放行 21 小时（1260 分）");

        flipProperty(r);
    }

    /* ---------- 3. 只选周一 ---------- */

    private static void onlyMonday() {
        System.out.println("---- 只选周一 22:00–23:00 ----");
        Rule r = new Rule(0x01, 22 * 60, 23 * 60);

        eq(blocked(r, 2026, 10, 19, 22, 30), false, "周一 22:30 放行");
        eq(blocked(r, 2026, 10, 20, 22, 30), true, "周二 22:30 屏蔽（未选周二）");
        eq(blocked(r, 2026, 10, 25, 22, 30), true, "周日 22:30 屏蔽");
        eq(blocked(r, 2026, 10, 20, 12, 0), true, "周二中午 屏蔽");

        Calendar f = cal(r.nextFlip(at(2026, 10, 19, 22, 30)));
        eq(Rule.hm(f.get(Calendar.HOUR_OF_DAY), f.get(Calendar.MINUTE)), "23:00",
                "周一 22:30 的下次翻转是当天 23:00");

        Calendar f2 = cal(r.nextFlip(at(2026, 10, 19, 23, 30)));
        eq(Rule.hm(f2.get(Calendar.HOUR_OF_DAY), f2.get(Calendar.MINUTE)), "22:00",
                "周一 23:30 的下次翻转是 22:00");
        eq(f2.get(Calendar.DAY_OF_MONTH), 26, "而且落在下周一（10/26）而不是本周二");
    }

    /* ---------- 4. 只选周末 ---------- */

    private static void weekendOnly() {
        System.out.println("---- 只选周六日 22:00–23:00 ----");
        Rule r = new Rule(0x60, 22 * 60, 23 * 60);

        eq(blocked(r, 2026, 10, 24, 22, 30), false, "周六 22:30 放行");
        eq(blocked(r, 2026, 10, 25, 22, 30), false, "周日 22:30 放行");
        eq(blocked(r, 2026, 10, 23, 22, 30), true, "周五 22:30 屏蔽");
    }

    /* ---------- 5. 强制模式 ---------- */

    private static void forceTests() {
        System.out.println("---- 强制模式（开关式，无持续时间）----");
        Rule r = new Rule(0x7F, 22 * 60, 23 * 60);
        Calendar inWin = at(2026, 10, 19, 22, 30);
        Calendar outWin = at(2026, 10, 19, 12, 0);

        eq(Guard.blocked(r, inWin, true), true, "★ 放行时段 + 强制 → 仍然屏蔽");
        eq(Guard.blocked(r, outWin, true), true, "屏蔽时段 + 强制 → 屏蔽");
        eq(Guard.blocked(r, inWin, false), false, "放行时段 + 未强制 → 放行");
        eq(Guard.blocked(r, outWin, false), true, "屏蔽时段 + 未强制 → 屏蔽");

        // 锁定只看窗口：强制开着时，放行窗口里仍要能把它关掉，否则永远出不来
        ok(r.inWindow(inWin), "锁定判定看窗口：强制中但处在放行窗口 → 不锁（否则关不掉）");
    }

    /* ---------- 6. 多个应用互不影响 ---------- */

    private static void multiApp() {
        System.out.println("---- 多应用：各自时段 / 取最早的翻转 ----");
        Rule douyin = new Rule(0x7F, 22 * 60, 23 * 60);   // 每天 22:00-23:00 能刷
        Rule wechat = new Rule(0x7F, 7 * 60, 22 * 60);    // 每天 07:00-22:00 能用

        eq(blocked(douyin, 2026, 10, 19, 12, 0), true, "中午：抖音冻结");
        eq(blocked(wechat, 2026, 10, 19, 12, 0), false, "中午：微信可用（同一时刻不同结论）");

        eq(blocked(douyin, 2026, 10, 19, 22, 30), false, "22:30：抖音放行");
        eq(blocked(wechat, 2026, 10, 19, 22, 30), true, "22:30：微信冻结");

        // 06:00 时：微信 07:00 开始放行，抖音要到 22:00 → 只能排最早的 07:00
        Calendar early = at(2026, 10, 19, 6, 0);
        Calendar f = cal(Guard.nextFlipOf(Arrays.asList(douyin, wechat), early));
        eq(Rule.hm(f.get(Calendar.HOUR_OF_DAY), f.get(Calendar.MINUTE)), "07:00",
                "★ 下次翻转取最早的（07:00，不是抖音的 22:00）");

        // 21:30 时：两个应用都在 22:00 换挡
        Calendar late = at(2026, 10, 19, 21, 30);
        Calendar f2 = cal(Guard.nextFlipOf(Arrays.asList(douyin, wechat), late));
        eq(Rule.hm(f2.get(Calendar.HOUR_OF_DAY), f2.get(Calendar.MINUTE)), "22:00",
                "21:30 的下次翻转是 22:00（两个应用同一时刻换挡）");

        // 空列表不能返回"过去的时间"，否则闹钟会立即空转
        long none = Guard.nextFlipOf(java.util.Collections.<Rule>emptyList(), noon());
        ok(none > noon().getTimeInMillis(), "没有应用时也要给出未来的时刻");
    }

    /* ---------- 7. 文案 ---------- */

    private static void textTests() {
        System.out.println("---- 文案 ----");
        eq(Rule.daysText(0x7F), "每天", "0x7F → 每天");
        eq(Rule.daysText(0x1F), "工作日", "0x1F → 工作日");
        eq(Rule.daysText(0x60), "周末", "0x60 → 周末");
        eq(Rule.daysText(0x41), "周一、周日", "0x41 → 周一、周日");
        ok(Rule.daysText(0).contains("一天都没选"), "0 → 提示一天都没选");
        eq(Rule.hm(22, 0), "22:00", "hm 格式化");
        eq(new Rule(0x7F, 23 * 60, 20 * 60).summary(), "每天 23:00-20:00（跨午夜）",
                "跨午夜要在文案里标出来");
    }

    /* ---------- 工具 ---------- */

    private static void flipProperty(Rule r) {
        int bad = 0;
        int notFuture = 0;
        for (int d = 19; d <= 25; d++) {
            for (int m = 0; m < 1440; m += 7) {
                Calendar now = at(2026, 10, d, m / 60, m % 60);
                long flip = r.nextFlip(now);
                if (flip <= now.getTimeInMillis()) {
                    notFuture++;
                }
                Calendar f = cal(flip);
                Calendar before = cal(flip - 60000L);
                if (r.inWindow(f) == r.inWindow(before)) {
                    bad++;
                }
            }
        }
        ok(bad == 0, "翻转点前后状态确实不同（异常 " + bad + "）");
        ok(notFuture == 0, "翻转点严格晚于当前时刻（异常 " + notFuture + "）");
    }

    private static boolean blocked(Rule r, int y, int mo, int d, int hh, int mm) {
        return Guard.blocked(r, at(y, mo, d, hh, mm), false);
    }

    private static Calendar noon() {
        return at(2026, 10, 19, 12, 0);
    }

    private static Calendar cal(long millis) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(millis);
        return c;
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

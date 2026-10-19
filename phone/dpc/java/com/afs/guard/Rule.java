package com.afs.guard;

import java.util.Calendar;

/**
 * 一个应用的放行规则：放行星期 + 放行时段。
 *
 * 纯 Java，不 import 任何 Android 类 —— 离线回归（test/run.sh）直接跑这一套。
 *
 * days 位图：bit 0 = 周一 …… bit 6 = 周日。
 * 放行 = 今天在选中的星期里 且 落在 [start, end)；其余时间屏蔽。
 * start > end 表示跨午夜，此时"选中的星期"指窗口**起始日**
 * （周一 23:00–次日 07:00 的凌晨那段算周一的）。
 */
public final class Rule {

    public static final int ALL_DAYS = 0x7F;
    public static final String[] DAY_NAMES = {"一", "二", "三", "四", "五", "六", "日"};

    public final int days;
    public final int start;   // 分钟，0..1439
    public final int end;

    public Rule(int days, int start, int end) {
        this.days = days & ALL_DAYS;
        this.start = norm(start);
        this.end = norm(end);
    }

    public Rule withDays(int d) {
        return new Rule(d, start, end);
    }

    public Rule withWindow(int s, int e) {
        return new Rule(days, s, e);
    }

    public boolean same(Rule o) {
        return o != null && o.days == days && o.start == start && o.end == end;
    }

    public boolean crossMidnight() {
        return start > end;
    }

    /* ---------- 纯函数 ---------- */

    public static int norm(int m) {
        return ((m % 1440) + 1440) % 1440;
    }

    public static boolean dayOn(int mask, int monBasedIndex) {
        return (mask & (1 << monBasedIndex)) != 0;
    }

    /** Calendar.DAY_OF_WEEK → 0=周一 …… 6=周日 */
    public static int monIndex(Calendar c) {
        return (c.get(Calendar.DAY_OF_WEEK) + 5) % 7;
    }

    /** 此刻是否在放行窗口里（不考虑强制模式）。 */
    public boolean inWindow(Calendar c) {
        int mod = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
        int today = monIndex(c);
        int yesterday = (today + 6) % 7;

        if (start == end) {
            // 起止相同：选中的星期全天放行，没选中的全天屏蔽
            return dayOn(days, today);
        }
        if (start < end) {
            return dayOn(days, today) && mod >= start && mod < end;
        }
        // 跨午夜：晚上那段算今天，凌晨那段算昨天
        boolean evening = dayOn(days, today) && mod >= start;
        boolean morning = dayOn(days, yesterday) && mod < end;
        return evening || morning;
    }

    /**
     * 下一次状态翻转的时刻（毫秒）。
     *
     * 逐分钟扫，最多扫 8 天。以前"跳到下一个边界"的算法在引入星期之后会算错
     * （只选周一时得跳过整整六天），逐分钟扫 11520 次是微秒级，没必要优化。
     */
    public long nextFlip(Calendar now) {
        Calendar t = (Calendar) now.clone();
        t.set(Calendar.SECOND, 0);
        t.set(Calendar.MILLISECOND, 0);
        boolean cur = inWindow(t);
        for (int i = 0; i < 8 * 1440 + 2; i++) {
            t.add(Calendar.MINUTE, 1);
            if (inWindow(t) != cur) {
                return t.getTimeInMillis();
            }
        }
        return now.getTimeInMillis() + 3600000L;
    }

    /* ---------- 文案 ---------- */

    public String windowText() {
        return hm(start / 60, start % 60) + "-" + hm(end / 60, end % 60);
    }

    public String summary() {
        return daysText(days) + " " + windowText() + (crossMidnight() ? "（跨午夜）" : "");
    }

    public static String daysText(int mask) {
        if ((mask & ALL_DAYS) == ALL_DAYS) {
            return "每天";
        }
        if (mask == 0) {
            return "一天都没选";
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
                    sb.append('、');
                }
                sb.append("周").append(DAY_NAMES[i]);
                first = false;
            }
        }
        return sb.toString();
    }

    public static String hm(int h, int m) {
        return pad2(h) + ":" + pad2(m);
    }

    private static String pad2(int v) {
        return v < 10 ? "0" + v : String.valueOf(v);
    }
}

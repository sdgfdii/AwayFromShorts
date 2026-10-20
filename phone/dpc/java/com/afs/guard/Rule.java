package com.afs.guard;

import java.util.Calendar;

/**
 * 一个应用的放行规则：放行星期 + 若干放行时段（支持多段）。
 *
 * 纯 Java，不 import 任何 Android 类 —— 离线回归（test/run.sh）直接跑这一套。
 *
 * days 位图：bit 0 = 周一 …… bit 6 = 周日。
 * 放行 = 今天（跨午夜的凌晨算昨天）在选中的星期里 且 落在任意一段 [start, end)。
 * start > end 表示该段跨午夜，"选中的星期"指该段**起始日**。
 * days == 0 或没有任何时段 = 全天屏蔽。
 */
public final class Rule {

    public static final int ALL_DAYS = 0x7F;
    public static final String[] DAY_NAMES = {"一", "二", "三", "四", "五", "六", "日"};

    public final int days;
    private final int[][] windows;   // 每段 {start, end}，已规范化，按 start 升序

    public Rule(int days, int[][] windows) {
        this.days = days & ALL_DAYS;
        this.windows = normalize(windows);
    }

    /** 单段便捷构造。 */
    public Rule(int days, int start, int end) {
        this(days, new int[][] { { start, end } });
    }

    private static int[][] normalize(int[][] in) {
        int[][] tmp = new int[in == null ? 0 : in.length][2];
        int n = 0;
        for (int i = 0; i < tmp.length; i++) {
            if (in[i] == null || in[i].length < 2) {
                continue;
            }
            tmp[n][0] = norm(in[i][0]);
            tmp[n][1] = norm(in[i][1]);
            n++;
        }
        int[][] out = new int[n][2];
        System.arraycopy(tmp, 0, out, 0, n);
        // 按 start 升序，展示与比较都稳定
        for (int i = 1; i < out.length; i++) {
            int[] cur = out[i];
            int j = i - 1;
            while (j >= 0 && out[j][0] > cur[0]) {
                out[j + 1] = out[j];
                j--;
            }
            out[j + 1] = cur;
        }
        return out;
    }

    public int windowCount() {
        return windows.length;
    }

    /** 第 i 段的起点（分钟）。 */
    public int startAt(int i) {
        return windows[i][0];
    }

    /** 第 i 段的终点（分钟）。 */
    public int endAt(int i) {
        return windows[i][1];
    }

    public int[][] windows() {
        // ★ 必须深拷贝内层行：arraycopy 只拷外层，行引用共享会让 withWindow 改穿原规则
        int[][] out = new int[windows.length][2];
        for (int i = 0; i < windows.length; i++) {
            out[i][0] = windows[i][0];
            out[i][1] = windows[i][1];
        }
        return out;
    }

    public Rule withDays(int d) {
        return new Rule(d, windows);
    }

    /** 改第 i 段的起止。 */
    public Rule withWindow(int i, int s, int e) {
        int[][] w = windows();
        w[i][0] = norm(s);
        w[i][1] = norm(e);
        return new Rule(days, w);
    }

    public Rule addWindow(int s, int e) {
        int[][] w = new int[windows.length + 1][2];
        for (int i = 0; i < windows.length; i++) {
            w[i][0] = windows[i][0];
            w[i][1] = windows[i][1];
        }
        w[windows.length][0] = norm(s);
        w[windows.length][1] = norm(e);
        return new Rule(days, w);
    }

    public Rule removeWindow(int i) {
        int[][] w = new int[windows.length - 1][2];
        int n = 0;
        for (int k = 0; k < windows.length; k++) {
            if (k == i) {
                continue;
            }
            w[n][0] = windows[k][0];
            w[n][1] = windows[k][1];
            n++;
        }
        return new Rule(days, w);
    }

    public boolean same(Rule o) {
        if (o == null || o.days != days || o.windowCount() != windowCount()) {
            return false;
        }
        for (int i = 0; i < windows.length; i++) {
            if (o.windows[i][0] != windows[i][0] || o.windows[i][1] != windows[i][1]) {
                return false;
            }
        }
        return true;
    }

    public boolean crossMidnightAt(int i) {
        return windows[i][0] > windows[i][1];
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

    /** 此刻是否在任一放行窗口里。 */
    public boolean inWindow(Calendar c) {
        int mod = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
        int today = monIndex(c);
        int yesterday = (today + 6) % 7;
        for (int i = 0; i < windows.length; i++) {
            int s = windows[i][0];
            int e = windows[i][1];
            if (s == e) {
                // 起止相同：选中的星期全天放行
                if (dayOn(days, today)) {
                    return true;
                }
            } else if (s < e) {
                if (dayOn(days, today) && mod >= s && mod < e) {
                    return true;
                }
            } else {
                // 跨午夜：晚上那段算今天，凌晨那段算昨天
                boolean evening = dayOn(days, today) && mod >= s;
                boolean morning = dayOn(days, yesterday) && mod < e;
                if (evening || morning) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * 下一次状态翻转的时刻（毫秒）。
     *
     * 逐分钟扫，最多扫 8 天。多段窗口下解析式"跳到下一边界"的算法容易算错
     * （段与段、日与日之间都要比较），逐分钟扫 11520 次是微秒级，没必要优化。
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
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < windows.length; i++) {
            if (i > 0) {
                sb.append('、');
            }
            sb.append(hm(windows[i][0] / 60, windows[i][0] % 60))
              .append('-')
              .append(hm(windows[i][1] / 60, windows[i][1] % 60));
        }
        return sb.length() == 0 ? "无时段（整天冻结）" : sb.toString();
    }

    public String summary() {
        boolean cross = false;
        for (int i = 0; i < windows.length; i++) {
            if (crossMidnightAt(i)) {
                cross = true;
                break;
            }
        }
        return daysText(days) + " " + windowText() + (cross ? "（含跨午夜）" : "");
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

package com.afs.guard;

import android.app.Activity;
import android.app.TimePickerDialog;
import android.content.Intent;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.TimePicker;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Map;
import java.util.Set;

/**
 * 面板：状态 + 每个应用各自的放行星期与时段 + 强制模式。
 *
 * 锁定是按应用算的：某个 App 正处在自己的屏蔽时间，就不能改它的时段、不能把它移出列表。
 * 否则冻结期间点一下「移除」再「立即应用」就绕过去了。
 * 全部应用都在屏蔽中时，整页切深色。
 */
public class MainActivity extends Activity {

    private static final int REQ_PICK = 21;

    private static final int BG = 0xFFF1F2F3;
    private static final int SURFACE = 0xFFFFFFFF;
    private static final int TEXT = 0xFF18191C;
    private static final int TEXT2 = 0xFF61666D;
    private static final int BRAND = 0xFF00AEEC;
    private static final int RED = 0xFFF85A54;
    private static final int GREEN = 0xFF20A162;

    // 全部屏蔽时整页切深色：是"变黑"，不是把控件调成半透明灰
    private static final int BG_DARK      = 0xFF0D0D0F;
    private static final int SURFACE_DARK  = 0xFF1A1A1D;
    private static final int TEXT_DARK     = 0xFFEDEDEF;
    private static final int TEXT2_DARK    = 0xFF9B9BA2;
    private static final int OFF_DARK      = 0xFF2A2A2E;
    private static final int OFF_LIGHT     = 0xFFE3E5E7;
    private static final int RED_DARK      = 0xFFFF7B72;
    private static final int GREEN_DARK    = 0xFF3DDC84;

    /** 每个应用一张卡。 */
    private static final class AppRow {
        String pkg;
        LinearLayout box;
        TextView name;
        TextView state;
        Button[] day = new Button[7];
        Button start;
        Button end;
        Button remove;
    }

    private TextView status;
    private TextView result;
    private TextView lockNote;
    private Button addBtn;
    private Button forceBtn;
    private Button applyBtn;

    private ScrollView scroll;
    private LinearLayout appContainer;
    private TextView title;
    private TextView sub;
    private TextView foot;

    private final java.util.List<AppRow> rows = new ArrayList<>();
    private final java.util.List<View> surfaces = new ArrayList<>();
    private final java.util.List<TextView> labels = new ArrayList<>();

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            render();
            handler.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, dp(22), pad, dp(28));
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        title = new TextView(this);
        title.setText("AwayFromShorts");
        title.setTextColor(TEXT);
        title.setTextSize(23);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title);

        sub = new TextView(this);
        sub.setText("设备所有者模式 · 每个应用各自的时段");
        sub.setTextColor(TEXT2);
        sub.setTextSize(13);
        sub.setPadding(0, dp(4), 0, dp(14));
        root.addView(sub);

        status = card(root, 13);
        lockNote = card(root, 12);
        lockNote.setTextColor(RED);

        root.addView(sectionLabel("应用与放行时段（点星期 / 时段直接改）"));
        appContainer = new LinearLayout(this);
        appContainer.setOrientation(LinearLayout.VERTICAL);
        root.addView(appContainer, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        addBtn = button(root, "＋ 添加应用", SURFACE, TEXT);
        addBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                startActivityForResult(new Intent(MainActivity.this, AppPickerActivity.class), REQ_PICK);
            }
        });

        forceBtn = button(root, "开启强制模式", RED, 0xFFFFFFFF);
        forceBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                boolean on = Config.forceOn(MainActivity.this);
                Config.setForce(MainActivity.this, !on);
                toast(on ? "强制模式已关闭" : "强制模式已开启：所有应用一律冻结");
                runApply();
            }
        });

        applyBtn = button(root, "立即应用", BRAND, 0xFFFFFFFF);
        applyBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                Config.arm(MainActivity.this);   // 确认过了，宽限立即结束
                runApply();
            }
        });

        result = card(root, 12);
        result.setTextColor(TEXT2);

        foot = new TextView(this);
        foot.setText("移除守卫只有一条路：\n"
                + "adb shell dpm remove-active-admin com.afs.guard/.AfsAdmin");
        foot.setTextColor(TEXT2);
        foot.setTextSize(12);
        foot.setPadding(0, dp(18), 0, 0);
        root.addView(foot);

        setContentView(scroll);

        buildRows();
        render();
        if (Guard.isOwner(this)) {
            runApply();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        render();
        handler.removeCallbacks(tick);
        handler.post(tick);
    }

    @Override
    protected void onPause() {
        super.onPause();
        handler.removeCallbacks(tick);
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != REQ_PICK || res != RESULT_OK || data == null) {
            return;
        }
        Set<String> cur = RuleStore.packages(this);
        ArrayList<String> picked = data.getStringArrayListExtra("picked");
        Set<String> want = new java.util.LinkedHashSet<>();
        if (picked != null) {
            want.addAll(picked);
        }

        // 新增：套用"上次用过的时段"
        for (String p : want) {
            if (!cur.contains(p)) {
                RuleStore.put(this, p, RuleStore.defaultRule(this));
            }
        }
        // 移除：只有它此刻不在自己的屏蔽时间里才允许，否则等于给了后门
        int refused = 0;
        for (String p : cur) {
            if (!want.contains(p)) {
                if (Guard.lockedNow(this, p)) {
                    refused++;
                } else {
                    RuleStore.remove(this, p);
                }
            }
        }
        if (refused > 0) {
            toast("有 " + refused + " 个应用正在屏蔽中，不能移出列表");
        }
        buildRows();
        runApply();
    }

    /* ==================== 列表 ==================== */

    private void buildRows() {
        appContainer.removeAllViews();
        rows.clear();
        for (Map.Entry<String, Rule> e : RuleStore.all(this).entrySet()) {
            rows.add(makeRow(e.getKey()));
        }
        if (rows.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("还没有应用。点下面的「添加应用」选一个。");
            empty.setTextColor(TEXT2);
            empty.setTextSize(13);
            empty.setPadding(dp(4), dp(10), 0, dp(10));
            labels.add(empty);
            appContainer.addView(empty);
        }
    }

    private AppRow makeRow(final String pkg) {
        final AppRow r = new AppRow();
        r.pkg = pkg;

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setBackgroundColor(SURFACE);
        box.setPadding(dp(12), dp(12), dp(12), dp(10));
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.bottomMargin = dp(8);
        appContainer.addView(box, blp);
        surfaces.add(box);
        r.box = box;

        /* 第一行：应用名 + 状态 */
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        r.name = new TextView(this);
        r.name.setTextSize(16);
        r.name.setTypeface(Typeface.DEFAULT_BOLD);
        r.name.setTextColor(TEXT);
        head.addView(r.name, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        r.state = new TextView(this);
        r.state.setTextSize(12);
        r.state.setGravity(Gravity.END);
        head.addView(r.state);
        box.addView(head, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        /* 第二行：星期 */
        LinearLayout dayRow = new LinearLayout(this);
        dayRow.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        dlp.topMargin = dp(8);
        for (int i = 0; i < 7; i++) {
            final int idx = i;
            Button b = new Button(this);
            b.setText(Rule.DAY_NAMES[i]);
            b.setTextSize(13);
            b.setAllCaps(false);
            b.setPadding(0, 0, 0, 0);
            b.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) {
                    Rule cur = RuleStore.get(MainActivity.this, pkg);
                    RuleStore.put(MainActivity.this, pkg, cur.withDays(cur.days ^ (1 << idx)));
                    runApply();
                }
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(38), 1f);
            lp.rightMargin = dp(3);
            dayRow.addView(b, lp);
            r.day[i] = b;
        }
        box.addView(dayRow, dlp);

        /* 第三行：起止时间 + 移除 */
        LinearLayout timeRow = new LinearLayout(this);
        timeRow.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.topMargin = dp(6);
        r.start = smallButton(timeRow, 0, 1f);
        r.start.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                pickTime(pkg, true);
            }
        });
        r.end = smallButton(timeRow, 0, 1f);
        r.end.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                pickTime(pkg, false);
            }
        });
        r.remove = new Button(this);
        r.remove.setText("移除");
        r.remove.setAllCaps(false);
        r.remove.setTextSize(12);
        r.remove.setPadding(0, 0, 0, 0);
        r.remove.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                RuleStore.remove(MainActivity.this, pkg);
                buildRows();
                runApply();
            }
        });
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(dp(68), dp(42));
        rlp.leftMargin = dp(4);
        timeRow.addView(r.remove, rlp);
        box.addView(timeRow, tlp);

        return r;
    }

    private Button smallButton(LinearLayout parent, int bg, float weight) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setTextSize(13);
        b.setGravity(Gravity.CENTER);
        b.setBackgroundColor(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(42), weight);
        lp.rightMargin = dp(4);
        parent.addView(b, lp);
        return b;
    }

    /* ==================== 渲染 ==================== */

    private void render() {
        boolean owner = Guard.isOwner(this);
        boolean dark = Guard.allBlocked(this);
        boolean grace = Config.inGrace(this);
        boolean forceOn = Config.forceOn(this);

        applyDark(dark);

        // 状态整体翻转的那一刻（某个应用到点 / 全部到点）顺手重落地一次，
        // 否则屏幕上会同时出现「冻结中」和上一次 apply 的旧结果。
        if (firstRender) {
            firstRender = false;
            lastAllBlocked = dark;
            if (!applying) {
                runApply();
            }
        } else if (dark != lastAllBlocked) {
            lastAllBlocked = dark;
            if (!applying) {
                runApply();
            }
        }

        status.setText(Guard.describe(this));
        status.setTextColor(owner ? (dark ? TEXT_DARK : TEXT) : (dark ? RED_DARK : RED));

        if (dark && !grace) {
            lockNote.setVisibility(View.VISIBLE);
            lockNote.setText("全部应用都在屏蔽中：这一页改不了，到点自动解锁。没有解除按钮。");
            lockNote.setTextColor(dark ? RED_DARK : RED);
        } else if (grace) {
            lockNote.setVisibility(View.VISIBLE);
            lockNote.setText("首次使用：现在可以随便配，点「立即应用」后按锁定规则走。");
            lockNote.setTextColor(dark ? RED_DARK : RED);
        } else {
            lockNote.setVisibility(View.GONE);
        }

        int text2 = dark ? TEXT2_DARK : TEXT2;
        int offBg = dark ? OFF_DARK : OFF_LIGHT;
        int offFg = dark ? 0xFF6E6E76 : 0xFF9A9AA0;

        for (AppRow row : rows) {
            Rule rule = RuleStore.get(this, row.pkg);
            boolean blocked = Guard.blockedNow(this, row.pkg);
            boolean locked = Guard.lockedNow(this, row.pkg);

            row.name.setText(labelOf(row.pkg));
            row.name.setTextColor(dark ? TEXT_DARK : TEXT);
            row.state.setText(blocked ? "冻结中" : "放行中");
            row.state.setTextColor(blocked ? (dark ? RED_DARK : RED) : (dark ? GREEN_DARK : GREEN));

            for (int i = 0; i < 7; i++) {
                boolean on = Rule.dayOn(rule.days, i);
                row.day[i].setTextColor(on ? 0xFFFFFFFF : (dark ? TEXT2_DARK : TEXT2));
                row.day[i].setBackgroundColor(on ? BRAND : offBg);
                row.day[i].setEnabled(!locked);
                row.day[i].setAlpha(locked ? 0.55f : 1f);
            }
            row.start.setText("起点 " + Rule.hm(rule.start / 60, rule.start % 60));
            row.end.setText("终点 " + Rule.hm(rule.end / 60, rule.end % 60));
            styleSecondary(row.start, locked);
            styleSecondary(row.end, locked);

            row.remove.setEnabled(!locked);
            row.remove.setTextColor(locked ? offFg : (dark ? TEXT2_DARK : TEXT2));
            row.remove.setBackgroundColor(locked ? offBg : (dark ? OFF_DARK : OFF_LIGHT));
            row.remove.setAlpha(locked ? 0.55f : 1f);

            row.box.setBackgroundColor(dark ? SURFACE_DARK : SURFACE);
        }

        // 添加/立即应用永远能用：它们改不了"某应用什么时候放行"，不算后门
        styleSecondary(addBtn, false);
        styleSecondary(applyBtn, false);

        boolean canForce = Guard.anyUnlocked(this) || grace || !forceOn;
        forceBtn.setEnabled(canForce);
        forceBtn.setText(forceOn ? "关闭强制模式（当前：强制中）" : "开启强制模式");
        forceBtn.setTextColor(canForce ? 0xFFFFFFFF : offFg);
        forceBtn.setBackgroundColor(canForce ? (forceOn ? 0xFFB0352F : RED) : offBg);
        forceBtn.setAlpha(canForce ? 1f : 0.55f);

        if (result.getText().length() == 0) {
            result.setText("尚未执行。");
        }
        result.setTextColor(text2);
    }

    private boolean darkState = false;
    private boolean themeApplied = false;

    /** 整页配色：全部屏蔽时是深色，否则浅色。 */
    private void applyDark(boolean d) {
        // render() 每秒跑一次，颜色没变就别重设，免得每秒 invalidate 造成闪烁
        if (themeApplied && d == darkState) {
            return;
        }
        themeApplied = true;
        darkState = d;
        scroll.setBackgroundColor(d ? BG_DARK : BG);
        // 状态栏颜色 + 图标明暗都要跟着切：
        // 深色底配浅色图标，浅色底配深色图标，否则图标会糊在背景里看不见
        try {
            getWindow().setStatusBarColor(d ? BG_DARK : BG);
            View v = getWindow().getDecorView();
            int flags = v.getSystemUiVisibility();
            if (d) {
                flags &= ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
            } else {
                flags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
            }
            v.setSystemUiVisibility(flags);
        } catch (Throwable ignored) {
        }
        for (View v : surfaces) {
            v.setBackgroundColor(d ? SURFACE_DARK : SURFACE);
        }
        for (TextView v : labels) {
            v.setTextColor(d ? TEXT2_DARK : TEXT2);
        }
        title.setTextColor(d ? TEXT_DARK : TEXT);
        sub.setTextColor(d ? TEXT2_DARK : TEXT2);
        foot.setTextColor(d ? TEXT2_DARK : TEXT2);
    }

    /** 次要按钮：锁定时是深色块 + 暗字，不是半透明。 */
    private void styleSecondary(Button b, boolean locked) {
        boolean dark = darkState;
        int offBg = dark ? OFF_DARK : OFF_LIGHT;
        int offFg = dark ? 0xFF6E6E76 : 0xFF9A9AA0;
        b.setEnabled(!locked);
        b.setTextColor(locked ? offFg : (dark ? TEXT_DARK : TEXT));
        b.setBackgroundColor(locked ? offBg : (dark ? SURFACE_DARK : SURFACE));
        b.setAlpha(locked ? 0.55f : 1f);
    }

    /* ==================== 行为 ==================== */

    private void pickTime(final String pkg, final boolean isStart) {
        Rule r = RuleStore.get(this, pkg);
        int cur = isStart ? r.start : r.end;
        new TimePickerDialog(this, new TimePickerDialog.OnTimeSetListener() {
            public void onTimeSet(TimePicker view, int h, int m) {
                Rule now = RuleStore.get(MainActivity.this, pkg);
                int s = isStart ? h * 60 + m : now.start;
                int e = isStart ? now.end : h * 60 + m;
                if (s == e) {
                    toast("起点和终点不能相同");
                    return;
                }
                RuleStore.put(MainActivity.this, pkg, now.withWindow(s, e));
                runApply();
            }
        }, cur / 60, cur % 60, true).show();
    }

    private void runApply() {
        final MainActivity self = this;
        applying = true;
        new Thread(new Runnable() {
            public void run() {
                final String msg = Guard.apply(self);
                new Handler(Looper.getMainLooper()).post(new Runnable() {
                    public void run() {
                        result.setText(msg);
                        applying = false;
                        render();
                    }
                });
            }
        }).start();
    }

    private boolean applying;
    private boolean lastAllBlocked;
    private boolean firstRender = true;

    /* ---------- 小工具 ---------- */

    private String labelOf(String pkg) {
        return Guard.labelOf(getPackageManager(), pkg);
    }

    private void toast(String t) {
        Toast.makeText(this, t, Toast.LENGTH_SHORT).show();
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private TextView sectionLabel(String t) {
        TextView v = new TextView(this);
        v.setText(t);
        v.setTextSize(12);
        v.setTextColor(TEXT2);
        v.setPadding(dp(2), dp(8), 0, dp(6));
        labels.add(v);
        return v;
    }

    private TextView card(LinearLayout parent, int size) {
        TextView tv = new TextView(this);
        tv.setTextColor(TEXT);
        tv.setTextSize(size);
        tv.setLineSpacing(dp(5), 1f);
        tv.setBackgroundColor(SURFACE);
        tv.setPadding(dp(14), dp(12), dp(14), dp(12));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(8);
        parent.addView(tv, lp);
        surfaces.add(tv);
        return tv;
    }

    private Button button(LinearLayout parent, String label, int bg, int fg) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(14);
        b.setTextColor(fg);
        b.setBackgroundColor(bg);
        b.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(48));
        lp.bottomMargin = dp(8);
        parent.addView(b, lp);
        return b;
    }
}

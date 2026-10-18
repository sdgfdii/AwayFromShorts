package com.afs.guard;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.TimePickerDialog;
import android.content.DialogInterface;
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

/**
 * 面板：状态 + 放行星期 + 放行时段 + 选择应用 + 强制模式。
 *
 * 屏蔽状态下这一页所有能改东西的控件全部变灰 —— 这就是"强制模式"。
 * 否则冻结期间点一下「选择应用」把抖音取消勾选、再点「立即应用」就解开了。
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

    // 屏蔽时段整体切深色：是"变黑"，不是把控件调成半透明灰
    private static final int BG_DARK      = 0xFF0D0D0F;
    private static final int SURFACE_DARK  = 0xFF1A1A1D;
    private static final int TEXT_DARK     = 0xFFEDEDEF;
    private static final int TEXT2_DARK    = 0xFF9B9BA2;
    private static final int OFF_DARK      = 0xFF2A2A2E;
    private static final int OFF_LIGHT     = 0xFFE3E5E7;
    private static final int RED_DARK      = 0xFFFF7B72;
    private static final int GREEN_DARK    = 0xFF3DDC84;

    private TextView status;
    private TextView result;
    private TextView lockNote;
    private Button pickBtn;
    private Button startBtn;
    private Button endBtn;
    private Button forceBtn;
    private final Button[] dayBtns = new Button[7];

    private ScrollView scroll;
    private LinearLayout dayRow;
    private TextView title;
    private TextView sub;
    private TextView foot;
    private Button applyBtn;
    private final java.util.List<TextView> cards = new java.util.ArrayList<TextView>();
    private final java.util.List<TextView> labels = new java.util.ArrayList<TextView>();

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
        sub.setText("设备所有者模式 · 到点冻结");
        sub.setTextColor(TEXT2);
        sub.setTextSize(13);
        sub.setPadding(0, dp(4), 0, dp(14));
        root.addView(sub);

        status = card(root, 13);
        lockNote = card(root, 12);
        lockNote.setTextColor(RED);
        result = card(root, 12);
        result.setTextColor(TEXT2);

        /* ---------- 放行星期 ---------- */
        root.addView(sectionLabel("放行星期（其余时间一律屏蔽）"));
        dayRow = new LinearLayout(this);
        dayRow.setOrientation(LinearLayout.HORIZONTAL);
        dayRow.setBackgroundColor(SURFACE);
        dayRow.setPadding(dp(8), dp(10), dp(8), dp(10));
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        dlp.bottomMargin = dp(10);
        for (int i = 0; i < 7; i++) {
            final int idx = i;
            Button b = new Button(this);
            b.setTextSize(14);
            b.setAllCaps(false);
            b.setPadding(0, 0, 0, 0);
            b.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) {
                    int mask = Config.days(MainActivity.this);
                    Config.setDays(MainActivity.this, mask ^ (1 << idx));
                    runApply();
                }
            });
            dayRow.addView(b, new LinearLayout.LayoutParams(0, dp(48), 1f));
            dayBtns[i] = b;
        }
        root.addView(dayRow, dlp);

        /* ---------- 放行时段 ---------- */
        root.addView(sectionLabel("放行时段（起点含、终点不含）"));
        LinearLayout timeRow = new LinearLayout(this);
        timeRow.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.bottomMargin = dp(10);
        startBtn = timeButton(timeRow, true);
        endBtn = timeButton(timeRow, false);
        root.addView(timeRow, tlp);

        /* ---------- 选择应用 ---------- */
        pickBtn = button(root, "选择应用", SURFACE, TEXT);
        pickBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                startActivityForResult(new Intent(MainActivity.this, AppPickerActivity.class), REQ_PICK);
            }
        });

        /* ---------- 强制模式 ---------- */
        forceBtn = button(root, "开启强制模式", RED, 0xFFFFFFFF);
        forceBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                boolean on = Config.forceOn(MainActivity.this);
                Config.setForce(MainActivity.this, !on);
                toast(on ? "强制模式已关闭" : "强制模式已开启：一律冻结，屏蔽时段内关不掉");
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

        foot = new TextView(this);
        foot.setText("移除守卫只有一条路：\n"
                + "adb shell dpm remove-active-admin com.afs.guard/.AfsAdmin");
        foot.setTextColor(TEXT2);
        foot.setTextSize(12);
        foot.setPadding(0, dp(18), 0, 0);
        root.addView(foot);

        setContentView(scroll);

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
        if (req == REQ_PICK) {
            runApply();
        }
    }

    /* ==================== 行为 ==================== */

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

    private Button timeButton(LinearLayout parent, final boolean isStart) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setTextSize(14);
        b.setTextColor(TEXT);
        b.setBackgroundColor(SURFACE);
        b.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                int cur = isStart ? Config.startMin(MainActivity.this) : Config.endMin(MainActivity.this);
                new TimePickerDialog(MainActivity.this, new TimePickerDialog.OnTimeSetListener() {
                    public void onTimeSet(TimePicker view, int h, int m) {
                        int picked = h * 60 + m;
                        int s = Config.startMin(MainActivity.this);
                        int e = Config.endMin(MainActivity.this);
                        if (isStart) {
                            s = picked;
                        } else {
                            e = picked;
                        }
                        if (s == e) {
                            toast("起点和终点不能相同");
                            return;
                        }
                        Config.setWindow(MainActivity.this, s, e);
                        runApply();
                    }
                }, cur / 60, cur % 60, true).show();
            }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(48), 1f);
        if (isStart) {
            lp.rightMargin = dp(8);
        }
        parent.addView(b, lp);
        return b;
    }

    /* ==================== 渲染 ==================== */

    private void render() {
        boolean owner = Guard.isOwner(this);
        boolean blocked = Guard.isBlockedNow(this);
        boolean locked = Guard.isLockedNow(this);
        boolean forceOn = Config.forceOn(this);
        int daysMask = Config.days(this);
        int sm = Config.startMin(this);
        int em = Config.endMin(this);

        // 翻转的那一刻（比如 21:00 到点）顺手把结果卡也刷新一遍。
        // 不这么做的话，屏幕上会同时出现「现在状态：屏蔽中」和「模式：放行」，
        // 因为结果卡里存的是上一次 apply 的文本。
        if (firstRender) {
            firstRender = false;
            lastBlocked = blocked;
            // 打开界面先按当前配置落地一次。覆盖安装会清掉包的闹钟，
            // 不这么做的话「装完打开看一眼」等于没生效，得手动点一次「立即应用」。
            if (!applying) {
                runApply();
            }
        } else if (blocked != lastBlocked) {
            lastBlocked = blocked;
            if (!applying) {
                runApply();
            }
        }

        // 屏蔽时段整页切深色。注意不是 setAlpha 那种"变灰"，
        // 是底色、卡片、按钮全部换成深色系，一眼就能看出现在是锁着的。
        applyDark(locked);

        int text2 = locked ? TEXT2_DARK : TEXT2;
        int offBg = locked ? OFF_DARK : OFF_LIGHT;
        int offFg = locked ? 0xFF6E6E76 : 0xFF9A9AA0;

        status.setText(Guard.describe(this));
        int st;
        if (!owner) {
            st = locked ? RED_DARK : RED;
        } else if (blocked) {
            st = locked ? RED_DARK : RED;
        } else {
            st = locked ? GREEN_DARK : GREEN;
        }
        status.setTextColor(st);

        if (locked) {
            lockNote.setVisibility(View.VISIBLE);
            lockNote.setText("锁定中：这一页的设置现在改不了，到点自动解锁。没有解除按钮。");
            lockNote.setTextColor(RED_DARK);
        } else if (blocked) {
            lockNote.setVisibility(View.VISIBLE);
            lockNote.setText("首次使用：配置还没确认，现在可以改。保存后按锁定规则走。");
            lockNote.setTextColor(RED);
        } else {
            lockNote.setVisibility(View.GONE);
        }

        result.setTextColor(text2);

        for (int i = 0; i < 7; i++) {
            boolean on = (daysMask & (1 << i)) != 0;
            dayBtns[i].setText(Config.DAY_NAMES[i]);
            dayBtns[i].setTextColor(on ? 0xFFFFFFFF : (locked ? TEXT2_DARK : TEXT2));
            dayBtns[i].setBackgroundColor(on ? BRAND : offBg);
            dayBtns[i].setEnabled(!locked);
            dayBtns[i].setAlpha(locked ? 0.55f : 1f);
        }

        startBtn.setText("起点 " + Guard.hm(sm / 60, sm % 60));
        endBtn.setText("终点 " + Guard.hm(em / 60, em % 60));
        styleSecondary(startBtn, locked, offBg, offFg);
        styleSecondary(endBtn, locked, offBg, offFg);
        pickBtn.setText("选择应用（已选 " + Targets.count(this) + " 个）");
        styleSecondary(pickBtn, locked, offBg, offFg);
        styleSecondary(applyBtn, locked, offBg, offFg);

        forceBtn.setEnabled(!locked);
        forceBtn.setText(forceOn ? "关闭强制模式（当前：强制中）" : "开启强制模式");
        if (locked) {
            forceBtn.setTextColor(offFg);
            forceBtn.setBackgroundColor(offBg);
            forceBtn.setAlpha(0.55f);
        } else {
            forceBtn.setTextColor(0xFFFFFFFF);
            forceBtn.setBackgroundColor(forceOn ? 0xFFB0352F : RED);
            forceBtn.setAlpha(1f);
        }

        if (result.getText().length() == 0) {
            result.setText("尚未执行。");
        }
    }

    private boolean applying;
    private boolean lastBlocked;
    private boolean firstRender = true;
    private boolean themeApplied = false;
    private boolean darkState = false;

    /** 整页配色：locked 为 true 时是深色，否则浅色。 */
    private void applyDark(boolean d) {
        // render() 每秒跑一次，颜色没变就别重设，免得每秒 invalidate 造成闪烁
        if (themeApplied && d == darkState) {
            return;
        }
        themeApplied = true;
        darkState = d;
        int surface = d ? SURFACE_DARK : SURFACE;
        scroll.setBackgroundColor(d ? BG_DARK : BG);
        // 状态栏颜色 + 图标明暗都要跟着切：
        // 深色底配浅色图标，浅色底配深色图标，否则图标会糊在背景里看不见
        try {
            getWindow().setStatusBarColor(d ? BG_DARK : BG);
            android.view.View v = getWindow().getDecorView();
            int flags = v.getSystemUiVisibility();
            if (d) {
                flags &= ~android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
            } else {
                flags |= android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
            }
            v.setSystemUiVisibility(flags);
        } catch (Throwable ignored) {
        }
        dayRow.setBackgroundColor(surface);
        for (TextView v : cards) {
            v.setBackgroundColor(surface);
        }
        for (TextView v : labels) {
            v.setTextColor(d ? TEXT2_DARK : TEXT2);
        }
        title.setTextColor(d ? TEXT_DARK : TEXT);
        sub.setTextColor(d ? TEXT2_DARK : TEXT2);
        foot.setTextColor(d ? TEXT2_DARK : TEXT2);
    }

    /** 次要按钮：锁定时是深色块 + 暗字，不是半透明。 */
    private void styleSecondary(Button b, boolean locked, int offBg, int offFg) {
        b.setEnabled(!locked);
        b.setTextColor(locked ? offFg : (darkSurface() ? TEXT_DARK : TEXT));
        b.setBackgroundColor(locked ? offBg : (darkSurface() ? SURFACE_DARK : SURFACE));
        b.setAlpha(locked ? 0.55f : 1f);
    }

    private boolean darkSurface() {
        return Guard.isLockedNow(this);
    }

    /* ---------- 小工具 ---------- */

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
        cards.add(tv);
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

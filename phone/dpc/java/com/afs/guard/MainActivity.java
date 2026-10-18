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

    private TextView status;
    private TextView result;
    private TextView lockNote;
    private Button pickBtn;
    private Button startBtn;
    private Button endBtn;
    private Button forceBtn;
    private final Button[] dayBtns = new Button[7];

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

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, dp(22), pad, dp(28));
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView title = new TextView(this);
        title.setText("AFS 守卫");
        title.setTextColor(TEXT);
        title.setTextSize(23);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title);

        TextView sub = new TextView(this);
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
        LinearLayout dayRow = new LinearLayout(this);
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
                pickForce();
            }
        });

        Button applyBtn = button(root, "立即应用", BRAND, 0xFFFFFFFF);
        applyBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                runApply();
            }
        });

        TextView foot = new TextView(this);
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
        new Thread(new Runnable() {
            public void run() {
                final String msg = Guard.apply(self);
                new Handler(Looper.getMainLooper()).post(new Runnable() {
                    public void run() {
                        result.setText(msg);
                        render();
                    }
                });
            }
        }).start();
    }

    private void pickForce() {
        final String[] items = {"1 小时", "3 小时", "6 小时", "12 小时"};
        final long[] ms = {1, 3, 6, 12};
        new AlertDialog.Builder(this)
                .setTitle("强制模式持续多久？")
                .setItems(items, new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int which) {
                        Config.startForce(MainActivity.this, ms[which] * 3600_000L);
                        toast("已开启，" + items[which] + " 内既不能解除，也不能改设置");
                        runApply();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
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
        long force = Config.forceUntil(this);
        boolean forceOn = force > System.currentTimeMillis();
        int daysMask = Config.days(this);
        int sm = Config.startMin(this);
        int em = Config.endMin(this);

        status.setText(Guard.describe(this));
        status.setTextColor(!owner ? RED : (blocked ? RED : GREEN));

        if (locked) {
            lockNote.setVisibility(View.VISIBLE);
            lockNote.setText("锁定中：这一页的设置现在改不了，到点自动解锁。没有解除按钮。");
        } else if (blocked) {
            lockNote.setVisibility(View.VISIBLE);
            lockNote.setText("首次使用：配置还没确认，现在可以改。保存后按锁定规则走。");
        } else {
            lockNote.setVisibility(View.GONE);
        }

        for (int i = 0; i < 7; i++) {
            boolean on = (daysMask & (1 << i)) != 0;
            dayBtns[i].setText(Config.DAY_NAMES[i]);
            dayBtns[i].setTextColor(on ? 0xFFFFFFFF : TEXT2);
            dayBtns[i].setBackgroundColor(on ? BRAND : 0xFFE3E5E7);
            dayBtns[i].setEnabled(!locked);
            dayBtns[i].setAlpha(locked ? 0.45f : 1f);
        }

        startBtn.setText("起点 " + Guard.hm(sm / 60, sm % 60));
        endBtn.setText("终点 " + Guard.hm(em / 60, em % 60));
        startBtn.setEnabled(!locked);
        endBtn.setEnabled(!locked);
        startBtn.setAlpha(locked ? 0.45f : 1f);
        endBtn.setAlpha(locked ? 0.45f : 1f);

        pickBtn.setText("选择应用（已选 " + Targets.count(this) + " 个）");
        pickBtn.setEnabled(!locked);
        pickBtn.setAlpha(locked ? 0.45f : 1f);

        forceBtn.setEnabled(!locked);
        forceBtn.setAlpha(locked ? 0.45f : 1f);
        forceBtn.setText(forceOn
                ? "强制模式剩余 " + Guard.remainText(force - System.currentTimeMillis())
                : "开启强制模式");
        forceBtn.setBackgroundColor(forceOn ? 0xFFB0352F : RED);

        if (result.getText().length() == 0) {
            result.setText("尚未执行。");
        }
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

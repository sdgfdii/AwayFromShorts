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

import java.util.ArrayList;
import java.util.Map;
import java.util.Set;

/**
 * 白名单管理页：一行一个应用，点开改它的时段。
 *
 * 单独一页是必须的 —— 主界面塞满卡片之后，应用一多就得一直往下滑，
 * 而这里本来就是"白名单"，平时不需要看，需要时才进来改。
 */
public class AppListActivity extends Activity {

    private static final int REQ_PICK = 22;

    private static final int BG = 0xFFF1F2F3;
    private static final int SURFACE = 0xFFFFFFFF;
    private static final int TEXT = 0xFF18191C;
    private static final int TEXT2 = 0xFF61666D;
    private static final int BRAND = 0xFF00AEEC;
    private static final int RED = 0xFFF85A54;
    private static final int GREEN = 0xFF20A162;
    private static final int LINE = 0xFFE3E5E7;

    private ScrollView scroll;
    private LinearLayout list;
    private TextView title;
    private TextView hint;
    private TextView empty;
    private Button addBtn;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final java.util.List<TextView> labels = new ArrayList<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(20), dp(16), dp(24));
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        title = new TextView(this);
        title.setText("白名单");
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(TEXT);
        root.addView(title);

        hint = new TextView(this);
        hint.setText("点一行改它的放行时段，长按从白名单移除。");
        hint.setTextSize(12);
        hint.setTextColor(TEXT2);
        hint.setPadding(0, dp(4), 0, dp(12));
        labels.add(hint);
        root.addView(hint);

        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        root.addView(list);

        empty = new TextView(this);
        empty.setText("白名单是空的。点下面的「添加应用」选一个。");
        empty.setTextSize(13);
        empty.setTextColor(TEXT2);
        empty.setPadding(dp(2), dp(12), 0, dp(12));
        empty.setVisibility(View.GONE);
        labels.add(empty);
        root.addView(empty);

        addBtn = new Button(this);
        addBtn.setText("＋ 添加应用");
        addBtn.setAllCaps(false);
        addBtn.setTextSize(14);
        addBtn.setTextColor(BRAND);
        addBtn.setBackgroundColor(SURFACE);
        addBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                startActivityForResult(new Intent(AppListActivity.this, AppPickerActivity.class), REQ_PICK);
            }
        });
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(48));
        alp.topMargin = dp(12);
        root.addView(addBtn, alp);

        setContentView(scroll);
        // 这页固定浅色，状态栏跟着走，否则顶部会留一条系统灰
        try {
            getWindow().setStatusBarColor(BG);
            View v = getWindow().getDecorView();
            v.setSystemUiVisibility(v.getSystemUiVisibility()
                    | View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
        } catch (Throwable ignored) {
        }
        rebuild();
    }

    @Override
    protected void onResume() {
        super.onResume();
        rebuild();
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
        for (String p : want) {
            if (!cur.contains(p)) {
                RuleStore.put(this, p, RuleStore.defaultRule(this));
            }
        }
        int refused = 0;
        for (String p : cur) {
            if (!want.contains(p)) {
                if (Guard.canRemove(this, p)) {
                    RuleStore.remove(this, p);
                } else {
                    refused++;
                }
            }
        }
        if (refused > 0) {
            toast(refused + " 个应用正在屏蔽中，不能移出白名单");
        }
        rebuild();
        applyInBackground();
    }

    /* ==================== 列表 ==================== */

    private void rebuild() {
        list.removeAllViews();
        Map<String, Rule> all = RuleStore.all(this);
        empty.setVisibility(all.isEmpty() ? View.VISIBLE : View.GONE);

        for (Map.Entry<String, Rule> e : all.entrySet()) {
            list.addView(makeRow(e.getKey(), e.getValue()));
        }
    }

    private View makeRow(final String pkg, Rule rule) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setBackgroundColor(SURFACE);
        row.setPadding(dp(14), dp(10), dp(14), dp(10));

        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);

        String label = Guard.labelOf(getPackageManager(), pkg);
        boolean installed = !label.equals(pkg);

        TextView name = new TextView(this);
        name.setText(label);
        name.setTextSize(15);
        name.setSingleLine(true);
        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        name.setTextColor(TEXT);
        left.addView(name);

        TextView sub = new TextView(this);
        sub.setText(rule.summary());
        sub.setTextSize(12);
        sub.setTextColor(TEXT2);
        sub.setPadding(0, dp(2), 0, 0);
        left.addView(sub);

        row.addView(left, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView state = new TextView(this);
        state.setTextSize(12);
        if (!installed) {
            state.setText("未安装");
            state.setTextColor(TEXT2);
        } else if (Guard.blockedNow(this, pkg)) {
            state.setText("冻结中");
            state.setTextColor(RED);
        } else {
            state.setText("放行中");
            state.setTextColor(GREEN);
        }
        state.setPadding(dp(8), 0, 0, 0);
        row.addView(state);

        row.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                edit(pkg);
            }
        });
        row.setOnLongClickListener(new View.OnLongClickListener() {
            public boolean onLongClick(View v) {
                confirmRemove(pkg);
                return true;
            }
        });

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(1);
        row.setLayoutParams(lp);
        return row;
    }

    /* ==================== 编辑一个应用的时段 ==================== */

    private void edit(final String pkg) {
        if (Guard.lockedNow(this, pkg)) {
            toast("它正在自己的屏蔽时间里，等它的放行时段才能改");
            return;
        }

        final Rule cur = RuleStore.get(this, pkg);

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), 0);

        final TextView daysText = new TextView(this);
        daysText.setTextSize(12);
        daysText.setTextColor(TEXT2);
        daysText.setText("放行星期（没选中的日子整天冻结）");
        box.addView(daysText);

        final LinearLayout dayRow = new LinearLayout(this);
        dayRow.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        dlp.topMargin = dp(6);
        final int[] mask = { cur.days };
        final Button[] days = new Button[7];
        for (int i = 0; i < 7; i++) {
            final int idx = i;
            Button b = new Button(this);
            b.setText(Rule.DAY_NAMES[i]);
            b.setTextSize(13);
            b.setAllCaps(false);
            b.setPadding(0, 0, 0, 0);
            b.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) {
                    mask[0] ^= (1 << idx);
                    for (int k = 0; k < 7; k++) {
                        boolean on = Rule.dayOn(mask[0], k);
                        days[k].setTextColor(on ? 0xFFFFFFFF : TEXT2);
                        days[k].setBackgroundColor(on ? BRAND : LINE);
                    }
                    daysText.setText(Rule.daysText(mask[0]));
                }
            });
            boolean on = Rule.dayOn(mask[0], i);
            b.setTextColor(on ? 0xFFFFFFFF : TEXT2);
            b.setBackgroundColor(on ? BRAND : LINE);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(40), 1f);
            lp.rightMargin = dp(3);
            dayRow.addView(b, lp);
            days[i] = b;
        }
        box.addView(dayRow, dlp);

        final int[] win = { cur.start, cur.end };
        final TextView winText = new TextView(this);
        winText.setTextSize(13);
        winText.setTextColor(TEXT);
        winText.setPadding(0, dp(14), 0, dp(6));
        winText.setText("放行时段　" + Rule.hm(win[0] / 60, win[0] % 60)
                + " - " + Rule.hm(win[1] / 60, win[1] % 60));
        box.addView(winText);

        LinearLayout timeRow = new LinearLayout(this);
        timeRow.setOrientation(LinearLayout.HORIZONTAL);
        Button startBtn = new Button(this);
        startBtn.setText("改起点");
        startBtn.setAllCaps(false);
        startBtn.setTextSize(13);
        startBtn.setBackgroundColor(LINE);
        startBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                new TimePickerDialog(AppListActivity.this, new TimePickerDialog.OnTimeSetListener() {
                    public void onTimeSet(TimePicker view, int h, int m) {
                        win[0] = h * 60 + m;
                        if (win[0] == win[1]) {
                            toast("起点和终点不能相同");
                            return;
                        }
                        winText.setText("放行时段　" + Rule.hm(win[0] / 60, win[0] % 60)
                                + " - " + Rule.hm(win[1] / 60, win[1] % 60));
                    }
                }, win[0] / 60, win[0] % 60, true).show();
            }
        });
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, dp(42), 1f);
        blp.rightMargin = dp(6);
        timeRow.addView(startBtn, blp);

        Button endBtn = new Button(this);
        endBtn.setText("改终点");
        endBtn.setAllCaps(false);
        endBtn.setTextSize(13);
        endBtn.setBackgroundColor(LINE);
        endBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                new TimePickerDialog(AppListActivity.this, new TimePickerDialog.OnTimeSetListener() {
                    public void onTimeSet(TimePicker view, int h, int m) {
                        win[1] = h * 60 + m;
                        if (win[0] == win[1]) {
                            toast("起点和终点不能相同");
                            return;
                        }
                        winText.setText("放行时段　" + Rule.hm(win[0] / 60, win[0] % 60)
                                + " - " + Rule.hm(win[1] / 60, win[1] % 60));
                    }
                }, win[1] / 60, win[1] % 60, true).show();
            }
        });
        timeRow.addView(endBtn, new LinearLayout.LayoutParams(0, dp(42), 1f));
        box.addView(timeRow);

        new AlertDialog.Builder(this)
                .setTitle(Guard.labelOf(getPackageManager(), pkg))
                .setView(box)
                .setPositiveButton("保存", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int which) {
                        if (mask[0] == 0) {
                            toast("一天都没选 = 整天冻结，已保存");
                        }
                        RuleStore.put(AppListActivity.this, pkg, new Rule(mask[0], win[0], win[1]));
                        rebuild();
                        applyInBackground();
                    }
                })
                .setNegativeButton("取消", null)
                .setNeutralButton("移除", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int which) {
                        if (!Guard.canRemove(AppListActivity.this, pkg)) {
                            toast("它正在屏蔽中，等它的放行时段才能移除");
                            return;
                        }
                        RuleStore.remove(AppListActivity.this, pkg);
                        rebuild();
                        applyInBackground();
                    }
                })
                .show();
    }

    private void confirmRemove(final String pkg) {
        if (!Guard.canRemove(this, pkg)) {
            toast("它正在屏蔽中，等它的放行时段才能移除");
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle("移出白名单")
                .setMessage(Guard.labelOf(getPackageManager(), pkg) + " 将不再被管理（立刻解冻）。")
                .setPositiveButton("移除", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int which) {
                        RuleStore.remove(AppListActivity.this, pkg);
                        rebuild();
                        applyInBackground();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void applyInBackground() {
        new Thread(new Runnable() {
            public void run() {
                Guard.apply(AppListActivity.this);
            }
        }).start();
    }

    private void toast(String t) {
        Toast.makeText(this, t, Toast.LENGTH_SHORT).show();
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}

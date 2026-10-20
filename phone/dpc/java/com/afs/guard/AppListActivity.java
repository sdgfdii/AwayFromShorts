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
 * 黑名单管理页：一行一个应用，点开改它的时段。
 *
 * 单独一页是必须的 —— 主界面塞满卡片之后，应用一多就得一直往下滑，
 * 而这里本来就是"黑名单"，平时不需要看，需要时才进来改。
 *
 * 配色跟首页一致：全部应用都在屏蔽中时整页切深色，有应用放行时切回浅色。
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

    // 全部屏蔽时整页切深色（跟首页同一套）
    private static final int BG_DARK      = 0xFF0D0D0F;
    private static final int SURFACE_DARK  = 0xFF1A1A1D;
    private static final int TEXT_DARK     = 0xFFEDEDEF;
    private static final int TEXT2_DARK    = 0xFF9B9BA2;
    private static final int OFF_DARK      = 0xFF2A2A2E;
    private static final int OFF_LIGHT     = 0xFFE3E5E7;
    private static final int RED_DARK      = 0xFFFF7B72;
    private static final int GREEN_DARK    = 0xFF3DDC84;

    /** 每一行的句柄，tick 只更新状态文字，不整页重建（保住滚动位置）。 */
    private static final class Row {
        String pkg;
        LinearLayout box;
        TextView name;
        TextView state;
    }

    private ScrollView scroll;
    private LinearLayout list;
    private TextView title;
    private TextView hint;
    private TextView empty;
    private Button addBtn;
    private Button pkgBtn;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final java.util.List<Row> rows = new ArrayList<>();
    private final java.util.List<View> surfaces = new ArrayList<>();
    private final java.util.List<TextView> labels = new ArrayList<>();

    private boolean darkState = false;
    private boolean themeApplied = false;

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            refreshStates();
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
        root.setPadding(dp(16), dp(20), dp(16), dp(24));
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        title = new TextView(this);
        title.setText("黑名单");
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(TEXT);
        root.addView(title);

        hint = new TextView(this);
        hint.setText("点一行改它的放行时段，长按从黑名单移除。");
        hint.setTextSize(12);
        hint.setTextColor(TEXT2);
        hint.setPadding(0, dp(4), 0, dp(12));
        labels.add(hint);
        root.addView(hint);

        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        root.addView(list);

        empty = new TextView(this);
        empty.setText("黑名单是空的。点下面的「添加应用」选一个。");
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
                if (!canAdd()) {
                    toast("全部应用都在屏蔽中，等某一应用进入自己的放行时段再加");
                    return;
                }
                startActivityForResult(new Intent(AppListActivity.this, AppPickerActivity.class), REQ_PICK);
            }
        });
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(48));
        alp.topMargin = dp(12);
        root.addView(addBtn, alp);

        // 按包名加：还没装的应用也能先进黑名单，装上之后自动被管
        pkgBtn = new Button(this);
        pkgBtn.setText("＋ 按包名添加");
        pkgBtn.setAllCaps(false);
        pkgBtn.setTextSize(14);
        pkgBtn.setTextColor(TEXT2);
        pkgBtn.setBackgroundColor(SURFACE);
        pkgBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                if (!canAdd()) {
                    toast("全部应用都在屏蔽中，等某一应用进入自己的放行时段再加");
                    return;
                }
                promptPackage();
            }
        });
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(48));
        plp.topMargin = dp(6);
        root.addView(pkgBtn, plp);

        setContentView(scroll);
        rebuild();
    }

    @Override
    protected void onResume() {
        super.onResume();
        rebuild();
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
            toast(refused + " 个应用正在屏蔽中，不能移出黑名单");
        }
        rebuild();
        applyInBackground();
    }

    /* ==================== 列表 ==================== */

    private void rebuild() {
        applyDark(true);   // 黑名单页固定深色，不跟随屏蔽状态
        surfaces.clear();
        rows.clear();
        labels.clear();   // hint/empty 的颜色在 refreshStates 里单独刷，不会漏

        list.removeAllViews();
        Map<String, Rule> all = RuleStore.all(this);
        empty.setVisibility(all.isEmpty() ? View.VISIBLE : View.GONE);

        for (Map.Entry<String, Rule> e : all.entrySet()) {
            Row r = makeRow(e.getKey());
            rows.add(r);
            list.addView(r.box);
        }
        refreshStates();
    }

    private Row makeRow(final String pkg) {
        Row r = new Row();
        r.pkg = pkg;

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.HORIZONTAL);
        box.setGravity(Gravity.CENTER_VERTICAL);
        box.setPadding(dp(14), dp(10), dp(14), dp(10));

        LinearLayout left = new LinearLayout(this);
        left.setOrientation(LinearLayout.VERTICAL);

        String label = Guard.labelOf(getPackageManager(), pkg);
        boolean installed = !label.equals(pkg);

        r.name = new TextView(this);
        r.name.setText(label);
        r.name.setTextSize(15);
        r.name.setSingleLine(true);
        r.name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        left.addView(r.name);

        TextView sub = new TextView(this);
        sub.setText(RuleStore.get(this, pkg).summary());
        sub.setTextSize(12);
        sub.setTextColor(TEXT2);
        sub.setPadding(0, dp(2), 0, 0);
        labels.add(sub);
        left.addView(sub);

        box.addView(left, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        r.state = new TextView(this);
        r.state.setTextSize(12);
        r.state.setPadding(dp(8), 0, 0, 0);
        box.addView(r.state);

        r.box = box;
        box.setBackgroundColor(SURFACE_DARK);   // 固定深色：首帧就别露白底

        box.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                edit(pkg);
            }
        });
        box.setOnLongClickListener(new View.OnLongClickListener() {
            public boolean onLongClick(View v) {
                confirmRemove(pkg);
                return true;
            }
        });
        return r;
    }

    /* ==================== 主题与状态刷新 ==================== */

    private boolean canAdd() {
        return Config.inGrace(this) || Guard.anyUnlocked(this) || RuleStore.count(this) == 0;
    }

    /** 每秒跑：刷每行状态 + 刷按钮可用性。主题固定深色。 */
    private void refreshStates() {
        boolean dark = true;   // 黑名单页固定深色
        applyDark(dark);

        int text2 = dark ? TEXT2_DARK : TEXT2;
        int red = dark ? RED_DARK : RED;
        int green = dark ? GREEN_DARK : GREEN;
        int surface = dark ? SURFACE_DARK : SURFACE;

        boolean installed, blocked;
        for (Row r : rows) {
            String label = Guard.labelOf(getPackageManager(), r.pkg);
            installed = !label.equals(r.pkg);
            blocked = Guard.blockedNow(this, r.pkg);

            r.name.setText(label);
            r.name.setTextColor(dark ? TEXT_DARK : TEXT);
            if (!installed) {
                r.state.setText("未安装");
                r.state.setTextColor(text2);
            } else if (blocked) {
                r.state.setText("冻结中");
                r.state.setTextColor(red);
            } else {
                r.state.setText("放行中");
                r.state.setTextColor(green);
            }
            r.box.setBackgroundColor(surface);
        }

        boolean can = canAdd();
        addBtn.setEnabled(can);
        addBtn.setTextColor(can ? BRAND : 0xFF9A9AA0);
        addBtn.setBackgroundColor(can ? surface : (dark ? OFF_DARK : OFF_LIGHT));
        addBtn.setAlpha(can ? 1f : 0.55f);
        pkgBtn.setEnabled(can);
        pkgBtn.setTextColor(can ? text2 : 0xFF9A9AA0);
        pkgBtn.setBackgroundColor(can ? surface : (dark ? OFF_DARK : OFF_LIGHT));
        pkgBtn.setAlpha(can ? 1f : 0.55f);

        hint.setText(can
                ? "点一行改它的放行时段，长按从黑名单移除。"
                : "全部应用都在屏蔽中：黑名单现在改不了，等某一应用进入自己的放行时段。");
        hint.setTextColor(text2);
        empty.setTextColor(text2);
    }

    private void applyDark(boolean d) {
        // 每秒跑一次，颜色没变就别重设，免得闪烁
        if (themeApplied && d == darkState) {
            return;
        }
        themeApplied = true;
        darkState = d;
        scroll.setBackgroundColor(d ? BG_DARK : BG);
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
        title.setTextColor(d ? TEXT_DARK : TEXT);
        for (View v : surfaces) {
            v.setBackgroundColor(d ? SURFACE_DARK : SURFACE);
        }
        for (TextView v : labels) {
            v.setTextColor(d ? TEXT2_DARK : TEXT2);
        }
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
                    daysText.setText("放行星期 " + Rule.daysText(mask[0]));
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

        // ---- 多段时段 ----
        final java.util.List<int[]> wins = new java.util.ArrayList<int[]>();
        for (int i = 0; i < cur.windowCount(); i++) {
            wins.add(new int[] { cur.startAt(i), cur.endAt(i) });
        }
        final TextView winText = new TextView(this);
        winText.setTextSize(13);
        winText.setTextColor(TEXT);
        winText.setPadding(0, dp(14), 0, dp(4));
        box.addView(winText);

        final LinearLayout winBox = new LinearLayout(this);
        winBox.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        wlp.topMargin = dp(4);
        box.addView(winBox, wlp);

        final class Refresher implements Runnable {
            public void run() {
                final Refresher self = Refresher.this;
                winBox.removeAllViews();
                if (wins.isEmpty()) {
                    TextView none = new TextView(AppListActivity.this);
                    none.setText("没有任何时段 = 整天冻结");
                    none.setTextSize(12);
                    none.setTextColor(TEXT2);
                    winBox.addView(none);
                }
                for (int i = 0; i < wins.size(); i++) {
                    final int idx = i;
                    LinearLayout row = new LinearLayout(AppListActivity.this);
                    row.setOrientation(LinearLayout.HORIZONTAL);
                    row.setGravity(Gravity.CENTER_VERTICAL);
                    TextView tv = new TextView(AppListActivity.this);
                    tv.setText((i + 1) + ".　" + Rule.hm(wins.get(i)[0] / 60, wins.get(i)[0] % 60)
                            + " - " + Rule.hm(wins.get(i)[1] / 60, wins.get(i)[1] % 60));
                    tv.setTextSize(14);
                    tv.setTextColor(TEXT);
                    row.addView(tv, new LinearLayout.LayoutParams(0,
                            ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
                    Button chg = new Button(AppListActivity.this);
                    chg.setText("改");
                    chg.setTextSize(12);
                    chg.setAllCaps(false);
                    chg.setOnClickListener(new View.OnClickListener() {
                        public void onClick(View v) {
                            pickWindow(wins, idx, new Runnable() { public void run() {
                                winText.setText("放行时段　" + joinWins(wins));
                                self.run();
                            } });
                        }
                    });
                    row.addView(chg, new LinearLayout.LayoutParams(dp(56), dp(38)));
                    Button del = new Button(AppListActivity.this);
                    del.setText("删");
                    del.setTextSize(12);
                    del.setAllCaps(false);
                    del.setOnClickListener(new View.OnClickListener() {
                        public void onClick(View v) {
                            wins.remove(idx);
                            self.run();
                        }
                    });
                    LinearLayout.LayoutParams dlp2 = new LinearLayout.LayoutParams(dp(56), dp(38));
                    dlp2.leftMargin = dp(4);
                    row.addView(del, dlp2);
                    winBox.addView(row, new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
                }
                Button add = new Button(AppListActivity.this);
                add.setText("＋ 加一段");
                add.setTextSize(12);
                add.setAllCaps(false);
                add.setOnClickListener(new View.OnClickListener() {
                    public void onClick(View v) {
                        pickWindow(wins, -1, new Runnable() { public void run() {
                            winText.setText("放行时段　" + joinWins(wins));
                            self.run();
                        } });
                    }
                });
                LinearLayout.LayoutParams alp2 = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, dp(38));
                alp2.topMargin = dp(6);
                winBox.addView(add, alp2);
                winText.setText("放行时段　" + joinWins(wins));
            }
        }
        Refresher refresher = new Refresher();
        refresher.run();

        new AlertDialog.Builder(this)
                .setTitle(Guard.labelOf(getPackageManager(), pkg))
                .setView(box)
                .setPositiveButton("保存", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int which) {
                        int[][] w = new int[wins.size()][2];
                        for (int i = 0; i < wins.size(); i++) {
                            w[i][0] = wins.get(i)[0];
                            w[i][1] = wins.get(i)[1];
                        }
                        if (mask[0] == 0) {
                            toast("一天都没选 = 整天冻结，已保存");
                        }
                        RuleStore.put(AppListActivity.this, pkg, new Rule(mask[0], w));
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

    /** 时段列表拼成一行文案。 */
    private static String joinWins(java.util.List<int[]> wins) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < wins.size(); i++) {
            if (i > 0) {
                sb.append('、');
            }
            sb.append(Rule.hm(wins.get(i)[0] / 60, wins.get(i)[0] % 60))
              .append('-')
              .append(Rule.hm(wins.get(i)[1] / 60, wins.get(i)[1] % 60));
        }
        return sb.length() == 0 ? "无" : sb.toString();
    }

    /**
     * 选一段起止时间：先弹起点再弹终点，确认后写回。
     * idx >= 0 是改第 idx 段；-1 是追加新段。
     */
    private void pickWindow(final java.util.List<int[]> wins, final int idx, final Runnable done) {
        int defStart = idx >= 0 ? wins.get(idx)[0] : 21 * 60;
        new TimePickerDialog(this, new TimePickerDialog.OnTimeSetListener() {
            public void onTimeSet(TimePicker view, int h, int m) {
                final int s = h * 60 + m;
                int defEnd = idx >= 0 ? wins.get(idx)[1] : 23 * 60;
                new TimePickerDialog(AppListActivity.this, new TimePickerDialog.OnTimeSetListener() {
                    public void onTimeSet(TimePicker view, int h2, int m2) {
                        int e = h2 * 60 + m2;
                        if (s == e) {
                            toast("起点和终点不能相同");
                            return;
                        }
                        int[] seg = { s, e };
                        if (idx >= 0) {
                            wins.set(idx, seg);
                        } else {
                            wins.add(seg);
                        }
                        done.run();
                    }
                }, defEnd / 60, defEnd % 60, true).show();
            }
        }, defStart / 60, defStart % 60, true).show();
    }

    /** 手动输入包名 —— 主要给"还没装"的应用用，装上后自动被管。 */
    private void promptPackage() {
        final android.widget.EditText input = new android.widget.EditText(this);
        input.setHint("com.example.app");
        input.setSingleLine(true);
        input.setPadding(dp(20), dp(10), dp(20), dp(10));

        LinearLayout wrap = new LinearLayout(this);
        wrap.setOrientation(LinearLayout.VERTICAL);
        wrap.setPadding(dp(8), dp(4), dp(8), 0);
        wrap.addView(input, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        new AlertDialog.Builder(this)
                .setTitle("按包名添加到黑名单")
                .setMessage("应用还没装也可以先加：装上之后它会被自动冻结。\n包名必须完全一致，填错了这条规则不会匹配任何东西。")
                .setView(wrap)
                .setPositiveButton("添加", new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int which) {
                        String pkg = input.getText().toString().trim();
                        if (pkg.length() == 0) {
                            return;
                        }
                        if (RuleStore.packages(AppListActivity.this).contains(pkg)) {
                            toast("它已经在黑名单里");
                            return;
                        }
                        RuleStore.put(AppListActivity.this, pkg, RuleStore.defaultRule(AppListActivity.this));
                        rebuild();
                        applyInBackground();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void confirmRemove(final String pkg) {
        if (!Guard.canRemove(this, pkg)) {
            toast("它正在屏蔽中，等它的放行时段才能移除");
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle("移出黑名单")
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

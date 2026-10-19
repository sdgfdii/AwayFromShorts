package com.afs.guard;

import android.app.Activity;
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
import android.widget.Toast;

/**
 * 主界面：只看状态，不进列表。
 *
 * 应用一多，把每个应用都铺在首页就得一直往下滑 —— 那本来是个"黑名单"，
 * 平时不需要看。所以这里只留状态、强制模式和两个动作，
 * 黑名单和每条时段都在 {@link AppListActivity} 里，一行一个。
 */
public class MainActivity extends Activity {

    private static final int BG = 0xFFF1F2F3;
    private static final int SURFACE = 0xFFFFFFFF;
    private static final int TEXT = 0xFF18191C;
    private static final int TEXT2 = 0xFF61666D;
    private static final int BRAND = 0xFF00AEEC;
    private static final int RED = 0xFFF85A54;

    // 全部屏蔽时整页切深色：是"变黑"，不是把控件调成半透明灰
    private static final int BG_DARK      = 0xFF0D0D0F;
    private static final int SURFACE_DARK  = 0xFF1A1A1D;
    private static final int TEXT_DARK     = 0xFFEDEDEF;
    private static final int TEXT2_DARK    = 0xFF9B9BA2;
    private static final int OFF_DARK      = 0xFF2A2A2E;
    private static final int OFF_LIGHT     = 0xFFE3E5E7;
    private static final int RED_DARK      = 0xFFFF7B72;
    private static final int GREEN_DARK    = 0xFF3DDC84;

    private ScrollView scroll;
    private TextView title;
    private TextView sub;
    private TextView status;
    private TextView lockNote;
    private TextView result;
    private TextView foot;
    private Button appsBtn;
    private Button applyBtn;

    private final java.util.List<View> surfaces = new java.util.ArrayList<>();
    private final java.util.List<TextView> labels = new java.util.ArrayList<>();

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
        root.setPadding(dp(16), dp(22), dp(16), dp(28));
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        title = new TextView(this);
        title.setText("AwayFromShorts");
        title.setTextSize(23);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(TEXT);
        root.addView(title);

        sub = new TextView(this);
        sub.setText("设备所有者模式 · 每个应用各自的时段");
        sub.setTextSize(13);
        sub.setTextColor(TEXT2);
        sub.setPadding(0, dp(4), 0, dp(14));
        root.addView(sub);

        status = card(root, 13);
        lockNote = card(root, 12);
        lockNote.setTextColor(RED);

        appsBtn = button(root, "黑名单", SURFACE, TEXT);
        appsBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                startActivity(new Intent(MainActivity.this, AppListActivity.class));
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
        foot.setTextSize(12);
        foot.setTextColor(TEXT2);
        foot.setPadding(0, dp(18), 0, 0);
        root.addView(foot);

        setContentView(scroll);
        render();
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

    /* ==================== 渲染 ==================== */

    private void render() {
        boolean owner = Guard.isOwner(this);
        boolean dark = Guard.allBlocked(this);
        boolean grace = Config.inGrace(this);
        int total = RuleStore.count(this);

        applyDark(dark);

        // 状态整体翻转的那一刻顺手重落地一次，否则结果卡会停在旧文本上
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
            lockNote.setText("全部应用都在屏蔽中：现在改不了，到点自动解锁。没有解除按钮。");
            lockNote.setTextColor(dark ? RED_DARK : RED);
        } else if (grace) {
            lockNote.setVisibility(View.VISIBLE);
            lockNote.setText("首次使用：现在可以随便配，点「立即应用」后按锁定规则走。");
            lockNote.setTextColor(dark ? RED_DARK : RED);
        } else {
            lockNote.setVisibility(View.GONE);
        }

        appsBtn.setText("黑名单 · " + total + " 个应用");
        styleSecondary(appsBtn, false);
        styleSecondary(applyBtn, false);

        result.setTextColor(dark ? TEXT2_DARK : TEXT2);
        if (result.getText().length() == 0) {
            result.setText("尚未执行。");
        }
    }

    private boolean darkState = false;
    private boolean themeApplied = false;

    /** 整页配色：全部屏蔽时是深色，否则浅色。 */
    private void applyDark(boolean d) {
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

    private void toast(String t) {
        Toast.makeText(this, t, Toast.LENGTH_SHORT).show();
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
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

package com.afs.guard;

import android.app.Activity;
import android.graphics.Color;
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

/**
 * 面板：只读状态 + 一个「立即应用」。
 * 故意不做「关闭守卫」按钮 —— 那正是这类工具失效的地方。
 */
public class MainActivity extends Activity {

    private static final int BG = 0xFFF1F2F3;
    private static final int SURFACE = 0xFFFFFFFF;
    private static final int TEXT = 0xFF18191C;
    private static final int TEXT2 = 0xFF61666D;
    private static final int BRAND = 0xFF00AEEC;
    private static final int RED = 0xFFF85A54;

    private TextView status;
    private TextView result;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(18);
        root.setPadding(pad, dp(28), pad, dp(28));
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView title = new TextView(this);
        title.setText("AFS 守卫");
        title.setTextColor(TEXT);
        title.setTextSize(23);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("设备所有者模式 · 抖音定时冻结");
        sub.setTextColor(TEXT2);
        sub.setTextSize(13);
        sub.setPadding(0, dp(4), 0, dp(18));
        root.addView(sub);

        status = card(root);
        result = card(root);
        result.setTextColor(TEXT2);

        Button applyBtn = button(root, "立即应用", BRAND, 0xFFFFFFFF);
        applyBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                runApply();
            }
        });

        Button refreshBtn = button(root, "刷新状态", SURFACE, TEXT);
        refreshBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                render();
            }
        });

        TextView foot = new TextView(this);
        foot.setText("这个页面没有「关闭」按钮。\n"
                + "要移除守卫只有一条路：\n"
                + "adb shell dpm remove-active-admin com.afs.guard/.AfsAdmin");
        foot.setTextColor(TEXT2);
        foot.setTextSize(12);
        foot.setPadding(0, dp(20), 0, 0);
        root.addView(foot);

        setContentView(scroll);

        render();
        if (Guard.isOwner(this)) {
            runApply();
        }
    }

    private void runApply() {
        final MainActivity self = this;
        new Thread(new Runnable() {
            public void run() {
                final String msg = Guard.apply(self);
                new Handler(Looper.getMainLooper()).post(new Runnable() {
                    public void run() {
                        result.setTextColor(TEXT2);
                        result.setText(msg);
                        render();
                    }
                });
            }
        }).start();
    }

    private void render() {
        status.setText(Guard.describe(this));
        if (result.getText().length() == 0) {
            result.setText("尚未执行。点上面「立即应用」。");
        }
    }

    /* ---------- 小工具 ---------- */

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    private TextView card(LinearLayout parent) {
        TextView tv = new TextView(this);
        tv.setTextColor(TEXT);
        tv.setTextSize(13);
        tv.setLineSpacing(dp(5), 1f);
        tv.setBackgroundColor(SURFACE);
        tv.setPadding(dp(16), dp(14), dp(16), dp(14));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(10);
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
                ViewGroup.LayoutParams.MATCH_PARENT, dp(46));
        lp.bottomMargin = dp(10);
        parent.addView(b, lp);
        return b;
    }
}

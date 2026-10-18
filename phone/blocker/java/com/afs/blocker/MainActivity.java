package com.afs.blocker;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 极简界面：只显示状态 + 一个跳转按钮。
 * 故意不做「关闭」按钮 —— 想关得自己进系统设置，多三道手续。
 */
public class MainActivity extends Activity {

    private TextView status;
    private TextView clock;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(24), dp(32), dp(24), dp(24));
        root.setBackgroundColor(Color.parseColor("#f1f2f3"));

        TextView title = new TextView(this);
        title.setText("AFS 守卫 · 无障碍版");
        title.setTextSize(22);
        title.setTextColor(Color.parseColor("#18191c"));
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("不需要 Device Owner、不需要 Shizuku、不需要连电脑。\n重启后自动恢复。");
        sub.setTextSize(13);
        sub.setTextColor(Color.parseColor("#61666d"));
        sub.setPadding(0, dp(8), 0, dp(24));
        root.addView(sub);

        status = new TextView(this);
        status.setTextSize(16);
        status.setPadding(0, 0, 0, dp(8));
        root.addView(status);

        clock = new TextView(this);
        clock.setTextSize(13);
        clock.setTextColor(Color.parseColor("#61666d"));
        clock.setPadding(0, 0, 0, dp(24));
        root.addView(clock);

        Button open = new Button(this);
        open.setText("打开无障碍设置");
        open.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
                } catch (Throwable t) {
                    try {
                        startActivity(new Intent(Settings.ACTION_SETTINGS));
                    } catch (Throwable ignored) {
                    }
                }
            }
        });
        root.addView(open, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView hint = new TextView(this);
        hint.setText("在列表里找到「AFS 守卫」并打开。\n"
                + "ColorOS 可能提示「受限设置」，允许即可。\n\n"
                + "开启后：北京时间 " + Guard.windowText() + " 以外，抖音一进前台就被送回桌面。");
        hint.setTextSize(13);
        hint.setTextColor(Color.parseColor("#61666d"));
        hint.setPadding(0, dp(24), 0, 0);
        root.addView(hint);

        TextView targets = new TextView(this);
        targets.setText("\n管这三个包：\ncom.ss.android.ugc.aweme（抖音）\n"
                + "com.ss.android.ugc.aweme.lite（极速版）\n"
                + "com.ss.android.ugc.live（火山版）");
        targets.setTextSize(12);
        targets.setTextColor(Color.parseColor("#9499a0"));
        targets.setGravity(Gravity.START);
        root.addView(targets);

        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        boolean on = isEnabled();
        status.setText(on ? "无障碍服务：已开启" : "无障碍服务：未开启");
        status.setTextColor(Color.parseColor(on ? "#2e7d32" : "#c62828"));
        clock.setText("当前：" + (Guard.allowNow() ? "放行时段" : "屏蔽时段")
                + "　放行窗口 " + Guard.windowText());
    }

    private boolean isEnabled() {
        try {
            String s = Settings.Secure.getString(getContentResolver(),
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
            if (s == null) {
                return false;
            }
            for (String part : s.split(":")) {
                String p = part.trim().toLowerCase();
                if (p.startsWith(getPackageName().toLowerCase()) && p.contains("blockerservice")) {
                    return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}

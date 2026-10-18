package com.afs.blocker;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.TimePickerDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.TimePicker;
import android.widget.Toast;

import java.util.Calendar;

/**
 * 主界面。三块：状态 / 管哪些应用 / 放行时段 / 强制模式。
 *
 * 「锁定」= 现在处于拦截状态（强制模式中 或 不在放行时段）。
 * 锁定期间这一页所有能改东西的控件都变灰 —— 没有任何"解除"入口，只能等到点。
 */
public class MainActivity extends Activity {

    private static final int REQ_PICK = 21;

    private TextView bigStatus;
    private TextView subStatus;
    private TextView accStatus;
    private TextView shizukuStatus;
    private TextView targetsRow;
    private TextView windowRow;
    private Button accBtn;
    private Button pickBtn;
    private Button windowBtn;
    private Button forceBtn;
    private TextView lockNote;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            refresh();
            handler.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);

        Heal.schedule(this);
        try {
            rikka.shizuku.Shizuku.addRequestPermissionResultListener(permListener);
            // 不主动要一次 binder，pingBinder() 永远是 false（Shizuku 只会推给正在跑的进程）
            ShizukuBridge.ensureBinder(this);
        } catch (Throwable ignored) {
        }

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.parseColor("#f1f2f3"));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(20), dp(16), dp(24));
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("AFS 守卫");
        title.setTextSize(22);
        title.setTextColor(Color.parseColor("#18191c"));
        root.addView(title);

        TextView sub = new TextView(this);
        sub.setText("选好应用和时段，剩下的交给它。");
        sub.setTextSize(13);
        sub.setTextColor(Color.parseColor("#61666d"));
        sub.setPadding(0, dp(4), 0, dp(16));
        root.addView(sub);

        // ---------- 状态卡 ----------
        LinearLayout card = card();

        bigStatus = new TextView(this);
        bigStatus.setTextSize(26);
        card.addView(bigStatus);

        subStatus = new TextView(this);
        subStatus.setTextSize(13);
        subStatus.setTextColor(Color.parseColor("#61666d"));
        subStatus.setPadding(0, dp(6), 0, 0);
        card.addView(subStatus);

        lockNote = new TextView(this);
        lockNote.setTextSize(12);
        lockNote.setTextColor(Color.parseColor("#f85a54"));
        lockNote.setPadding(0, dp(10), 0, 0);
        card.addView(lockNote);

        root.addView(card);

        // ---------- 无障碍 ----------
        LinearLayout accCard = card();
        TextView accTitle = label("无障碍服务");
        accCard.addView(accTitle);

        accStatus = new TextView(this);
        accStatus.setTextSize(13);
        accStatus.setTextColor(Color.parseColor("#61666d"));
        accStatus.setPadding(0, dp(4), 0, dp(8));
        accCard.addView(accStatus);

        shizukuStatus = new TextView(this);
        shizukuStatus.setTextSize(13);
        shizukuStatus.setTextColor(Color.parseColor("#61666d"));
        shizukuStatus.setPadding(0, 0, 0, dp(12));
        accCard.addView(shizukuStatus);

        accBtn = new Button(this);
        accBtn.setText("打开无障碍设置");
        accBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                openAccessibilitySettings();
            }
        });
        accCard.addView(accBtn);
        root.addView(accCard);

        // ---------- 管哪些应用 ----------
        LinearLayout pickCard = card();
        pickCard.addView(label("管哪些应用"));

        targetsRow = new TextView(this);
        targetsRow.setTextSize(13);
        targetsRow.setTextColor(Color.parseColor("#61666d"));
        targetsRow.setPadding(0, dp(4), 0, dp(12));
        pickCard.addView(targetsRow);

        pickBtn = new Button(this);
        pickBtn.setText("选择应用");
        pickBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                startActivityForResult(new Intent(MainActivity.this, AppPickerActivity.class), REQ_PICK);
            }
        });
        pickCard.addView(pickBtn);
        root.addView(pickCard);

        // ---------- 放行时段 ----------
        LinearLayout winCard = card();
        winCard.addView(label("放行时段"));

        windowRow = new TextView(this);
        windowRow.setTextSize(13);
        windowRow.setTextColor(Color.parseColor("#61666d"));
        windowRow.setPadding(0, dp(4), 0, dp(12));
        winCard.addView(windowRow);

        windowBtn = new Button(this);
        windowBtn.setText("修改时段");
        windowBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                pickWindow();
            }
        });
        winCard.addView(windowBtn);
        root.addView(winCard);

        // ---------- 强制模式 ----------
        LinearLayout forceCard = card();
        forceCard.addView(label("强制模式"));

        TextView forceDesc = new TextView(this);
        forceDesc.setTextSize(13);
        forceDesc.setTextColor(Color.parseColor("#61666d"));
        forceDesc.setPadding(0, dp(4), 0, dp(12));
        forceDesc.setText("开启后这段时间一律不许用，且不可提前解除。");
        forceCard.addView(forceDesc);

        forceBtn = new Button(this);
        forceBtn.setText("开启强制模式");
        forceBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                pickForce();
            }
        });
        forceCard.addView(forceBtn);
        root.addView(forceCard);

        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
        handler.removeCallbacks(tick);
        handler.post(tick);
    }

    @Override
    protected void onPause() {
        super.onPause();
        handler.removeCallbacks(tick);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        try {
            rikka.shizuku.Shizuku.removeRequestPermissionResultListener(permListener);
        } catch (Throwable ignored) {
        }
    }

    private static final int SHIZUKU_REQ = 100;

    private final rikka.shizuku.Shizuku.OnRequestPermissionResultListener permListener =
            new rikka.shizuku.Shizuku.OnRequestPermissionResultListener() {
                @Override
                public void onRequestPermissionResult(int requestCode, int grantResult) {
                    refresh();
                }
            };

    private void requestShizuku() {
        try {
            ShizukuBridge.ensureBinder(this);
            if (!rikka.shizuku.Shizuku.pingBinder()) {
                return;
            }
            if (rikka.shizuku.Shizuku.checkSelfPermission()
                    == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                return;
            }
            rikka.shizuku.Shizuku.requestPermission(SHIZUKU_REQ);
        } catch (Throwable ignored) {
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        refresh();
    }

    /* ==================== 渲染 ==================== */

    private void refresh() {
        long now = System.currentTimeMillis();
        int mod = Guard.minuteOfDay(Calendar.getInstance());
        int s = Store.startMin(this);
        int e = Store.endMin(this);
        long force = Store.forceUntil(this);

        boolean blocked = Guard.isBlocked(mod, now, force, s, e);
        boolean forceOn = force > now;
        // 没配置过就不锁：否则装完正好落在屏蔽时段，连"选择应用"都点不动
        boolean locked = blocked && Store.isConfigured(this);

        if (blocked) {
            bigStatus.setText("拦截中");
            bigStatus.setTextColor(Color.parseColor("#f85a54"));
        } else {
            bigStatus.setText("放行中");
            bigStatus.setTextColor(Color.parseColor("#2ac864"));
        }

        if (forceOn) {
            subStatus.setText("强制模式剩余 " + Guard.remainText(force - now) + "，不可提前解除");
        } else if (blocked) {
            subStatus.setText("屏蔽时段，放行 " + Guard.windowText(s, e));
        } else {
            subStatus.setText("到达 " + Guard.hhmm(e) + " 后自动恢复拦截");
        }

        if (locked) {
            lockNote.setText("锁定中：这一页的设置现在改不了，到点自动解锁。没有解除按钮。");
        } else if (blocked) {
            lockNote.setText("首次使用：配置还没确认，现在可以改。保存后会按锁定规则走。");
        } else {
            lockNote.setText("");
        }

        accStatus.setText(isAccessibilityEnabled()
                ? "已开启。关掉它，拦截立即失效。"
                : "未开启。没有它，App 不会拦。");

        try {
            if (!rikka.shizuku.Shizuku.pingBinder()) {
                shizukuStatus.setText("强化杀进程：Shizuku 未运行 —— 现在只能退到桌面，进程杀不掉");
                shizukuStatus.setTextColor(Color.parseColor("#f85a54"));
            } else if (rikka.shizuku.Shizuku.checkSelfPermission()
                    == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                shizukuStatus.setText("强化杀进程：已接通 Shizuku，退到桌面后直接 force-stop");
                shizukuStatus.setTextColor(Color.parseColor("#2ac864"));
            } else {
                shizukuStatus.setText("强化杀进程：等你在 Shizuku 弹窗里点「允许」");
                shizukuStatus.setTextColor(Color.parseColor("#ff7f24"));
                requestShizuku();
            }
        } catch (Throwable t) {
            shizukuStatus.setText("强化杀进程：Shizuku 不可用");
            shizukuStatus.setTextColor(Color.parseColor("#9499a0"));
        }

        targetsRow.setText("已选 " + Store.targetCount(this) + " 个应用");
        windowRow.setText(Guard.windowText(s, e));

        pickBtn.setEnabled(!locked);
        windowBtn.setEnabled(!locked);
        forceBtn.setEnabled(!locked);
        forceBtn.setText(forceOn ? "强制模式进行中" : "开启强制模式");
    }

    private boolean isAccessibilityEnabled() {
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

    /* ==================== 交互 ==================== */

    private void openAccessibilitySettings() {
        try {
            startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
        } catch (Throwable t) {
            try {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            } catch (Throwable ignored) {
            }
        }
    }

    private void pickWindow() {
        final int s = Store.startMin(this);
        final int e = Store.endMin(this);

        new TimePickerDialog(this, new TimePickerDialog.OnTimeSetListener() {
            @Override
            public void onTimeSet(TimePicker view, int h, int m) {
                final int ns = h * 60 + m;
                new TimePickerDialog(MainActivity.this, new TimePickerDialog.OnTimeSetListener() {
                    @Override
                    public void onTimeSet(TimePicker v2, int h2, int m2) {
                        int ne = h2 * 60 + m2;
                        if (ne == ns) {
                            toast("起点和终点不能相同（那是全天放行）");
                            return;
                        }
                        Store.setWindow(MainActivity.this, ns, ne);
                        Store.markConfigured(MainActivity.this);
                        refresh();
                    }
                }, e / 60, e % 60, true).show();
            }
        }, s / 60, s % 60, true).show();
    }

    private void pickForce() {
        final String[] items = new String[] {"1 小时", "3 小时", "6 小时", "12 小时"};
        final long[] ms = new long[] {1, 3, 6, 12};
        new AlertDialog.Builder(this)
                .setTitle("强制模式持续多久？")
                .setItems(items, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        Store.startForce(MainActivity.this, ms[which] * 3600_000L);
                        toast("已开启，接下来的 " + items[which] + " 不可解除");
                        refresh();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    /* ==================== 小工具 ==================== */

    private LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setBackgroundColor(Color.WHITE);
        c.setPadding(dp(16), dp(16), dp(16), dp(16));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(12);
        c.setLayoutParams(lp);
        return c;
    }

    private TextView label(String t) {
        TextView v = new TextView(this);
        v.setText(t);
        v.setTextSize(15);
        v.setTextColor(Color.parseColor("#18191c"));
        v.setGravity(Gravity.START);
        return v;
    }

    private void toast(String t) {
        Toast.makeText(this, t, Toast.LENGTH_SHORT).show();
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}

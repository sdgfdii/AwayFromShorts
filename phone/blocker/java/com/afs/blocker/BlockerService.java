package com.afs.blocker;

import android.accessibilityservice.AccessibilityService;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.widget.Toast;

import java.util.Calendar;
import java.util.Set;

/**
 * 唯一的执行者。
 *
 * 触发条件：窗口切到被管 App（TYPE_WINDOW_STATE_CHANGED），且现在处于拦截状态。
 * 动作：performGlobalAction(GLOBAL_ACTION_HOME) 把用户送回桌面。
 *
 * 拦截状态由 Guard.isBlocked 决定：强制模式中 或 不在放行时段。
 * 要管哪些 App 由 Store.targets 决定（用户在「选择应用」里勾的）。
 */
public class BlockerService extends AccessibilityService {

    private static final String TAG = "AfsBlocker";

    private final Handler handler = new Handler(Looper.getMainLooper());

    /** 最近一次切到前台的包名（只信这个，不读屏幕内容） */
    private String lastPkg;

    private long lastKickAt;
    private long lastToastAt;
    private int kickCount;

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            // 处理"人一直停在被管 App 里，跨过边界"的情况：事件不会再来了，只能定时查
            check();
            handler.postDelayed(this, Guard.TICK_MS);
        }
    };

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        Log.i(TAG, "service connected, window="
                + Guard.windowText(Store.startMin(this), Store.endMin(this))
                + " targets=" + Store.targetCount(this));
        handler.removeCallbacks(tick);
        handler.post(tick);
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null) {
            return;
        }
        if (event.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            return;
        }
        CharSequence pkg = event.getPackageName();
        if (pkg != null) {
            lastPkg = pkg.toString();
        }
        check();
    }

    private void check() {
        String pkg = lastPkg;
        if (pkg == null) {
            return;
        }
        Set<String> targets = Store.targets(this);
        if (!targets.contains(pkg)) {
            return;
        }
        long now = System.currentTimeMillis();
        int mod = Guard.minuteOfDay(Calendar.getInstance());
        if (!Guard.isBlocked(mod, now, Store.forceUntil(this),
                Store.startMin(this), Store.endMin(this))) {
            return;
        }
        kick(pkg);
    }

    private void kick(String pkg) {
        long now = System.currentTimeMillis();
        if (now - lastKickAt < Guard.KICK_COOLDOWN_MS) {
            return;
        }
        lastKickAt = now;
        kickCount++;
        // 踢成功就把 lastPkg 清掉：否则 3 秒一次的巡检会一直对着一个已经不在前台的包反复按 Home，
        // 表现为在桌面上每 3 秒被按一次 Home（打开抽屉 / 最近任务也会被顶掉）。
        boolean ok = performGlobalAction(GLOBAL_ACTION_HOME);
        if (ok) {
            lastPkg = null;
        }
        Log.i(TAG, "kicked " + pkg + " (#" + kickCount + ")");
        if (now - lastToastAt > 10000L) {
            lastToastAt = now;
            try {
                String why = Store.forceActive(this) ? "强制模式" : "屏蔽时段";
                Toast.makeText(this, why + "：现在不能刷（放行 "
                                + Guard.windowText(Store.startMin(this), Store.endMin(this)) + "）",
                        Toast.LENGTH_SHORT).show();
            } catch (Throwable ignored) {
            }
        }
    }

    @Override
    public void onInterrupt() {
        Log.w(TAG, "service interrupted");
    }

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        handler.removeCallbacks(tick);
        return super.onUnbind(intent);
    }
}

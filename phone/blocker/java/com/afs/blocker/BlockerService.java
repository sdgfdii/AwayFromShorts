package com.afs.blocker;

import android.accessibilityservice.AccessibilityService;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.widget.Toast;

/**
 * 唯一的执行者。
 *
 * 触发条件：窗口切到目标 App（TYPE_WINDOW_STATE_CHANGED）且当前不在放行时段。
 * 动作：performGlobalAction(GLOBAL_ACTION_HOME) 把用户送回桌面。
 *
 * 为什么这条能扛住重启：无障碍服务由 system_server 绑定，用户在设置里开启一次之后，
 * 系统开机会自动把它拉起来 —— 不需要 Shizuku、不需要 adb、不需要连电脑。
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
            // 处理"人一直停在被管 App 里，跨过 23:00 边界"的情况：事件不会再来了，只能定时查
            check();
            handler.postDelayed(this, Guard.TICK_MS);
        }
    };

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        Log.i(TAG, "service connected, window=" + Guard.windowText());
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
        if (pkg == null || !Guard.isTarget(pkg)) {
            return;
        }
        if (Guard.allowNow()) {
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
        // 表现为在桌面上每 3 秒被按一次 Home（打开抽屉/最近任务也会被顶掉）。
        boolean ok = performGlobalAction(GLOBAL_ACTION_HOME);
        if (ok) {
            lastPkg = null;
        }
        Log.i(TAG, "kicked " + pkg + " (#" + kickCount + ")");
        if (now - lastToastAt > 10000L) {
            lastToastAt = now;
            try {
                Toast.makeText(this, "现在是屏蔽时段（放行 " + Guard.windowText() + "）",
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

package com.afs.guard;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

/**
 * 常驻守护：每 30 秒把状态落一遍。
 *
 * 为什么必须有它：ColorOS 会把 AlarmManager 的闹钟整体往后推（实测 setAlarmClock 排的点
 * 被 adjustment 推迟到 2 天 23 小时之后，连支付宝的闹钟一样被推），于是"到点自动冻结/放行"
 * 完全失效，只有用户手动打开 App 那一刻才冻得上。
 *
 * 前台服务 + 常驻通知是这台机器上唯一稳定的节拍源；闹钟继续保留当快路径（能响就更快）。
 * 冻结本身是 Device Owner 的 setPackagesSuspended，不依赖进程活着 —— 进程被杀最多是
 * 晚几十秒才切换，重新拉起后会立刻纠正。
 */
public class GuardService extends Service {

    private static final String CHANNEL = "afs_guard";
    private static final int NOTI_ID = 1001;
    private static final long TICK_MS = 30_000L;
    private static final String WAKELOCK_TAG = "afs:guard";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private PowerManager.WakeLock wakeLock;

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            try {
                Guard.apply(GuardService.this);   // 内部只有状态变化时才调 setPackagesSuspended
            } catch (Throwable t) {
                Log.e(Guard.TAG, "tick failed", t);
            }
            handler.postDelayed(this, TICK_MS);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        startForeground(NOTI_ID, buildNotification());
        acquireWakeLock();
        handler.post(tick);
        Log.i(Guard.TAG, "service started");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 被系统杀掉后自动拉起；onCreate 里已经挂了 tick，这里只需保证不重复挂
        handler.removeCallbacks(tick);
        handler.post(tick);
        // 上一条 START_STICKY 的实例可能没走 onDestroy，锁要补上
        acquireWakeLock();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(tick);
        releaseWakeLock();
        Log.w(Guard.TAG, "service destroyed");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    /**
     * 常驻 Partial Wakelock：灭屏后 CPU 不睡，30 秒的 Handler 节拍才跑得准。
     *
     * 只有前台服务不够 —— ColorOS 灭屏进 Doze 后 Handler 的 postDelayed 直接被冻住
     * （实测灭屏 70 秒才 tick 一次），到点切不切换全看运气。持有 PARTIAL_WAKE_LOCK
     * 期间 CPU 保持唤醒，tick 能按时跑。
     *
     * 代价是耗电：锁不设超时，服务活着就一直持着。这是"准时"换"电量"，
     * 用户明确选了这条路。要退回省电就只能靠闹钟（会被 ROM 推后）。
     *
     * 另外 deploy.sh 会把本包塞进 Doze 白名单（dumpsys deviceidle whitelist），
     * 那一步是前提 —— 光有 wakelock 挡不住系统级 Doze。
     */
    private void acquireWakeLock() {
        try {
            if (wakeLock == null) {
                PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                if (pm == null) {
                    Log.e(Guard.TAG, "wakelock: no PowerManager");
                    return;
                }
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG);
                wakeLock.setReferenceCounted(false);
            }
            if (!wakeLock.isHeld()) {
                wakeLock.acquire();
                Log.i(Guard.TAG, "wakelock acquired");
            }
        } catch (Throwable t) {
            Log.e(Guard.TAG, "wakelock acquire failed", t);
        }
    }

    private void releaseWakeLock() {
        try {
            if (wakeLock != null && wakeLock.isHeld()) {
                wakeLock.release();
                Log.i(Guard.TAG, "wakelock released");
            }
        } catch (Throwable t) {
            Log.e(Guard.TAG, "wakelock release failed", t);
        }
    }

    private Notification buildNotification() {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (nm != null) {
                NotificationChannel ch = new NotificationChannel(
                        CHANNEL, "时间表守护", NotificationManager.IMPORTANCE_MIN);
                ch.setShowBadge(false);
                ch.setSound(null, null);
                nm.createNotificationChannel(ch);
            }
            b = new Notification.Builder(this, CHANNEL);
        } else {
            b = new Notification.Builder(this);
        }
        b.setContentTitle("按时间表工作")
         .setContentText("到点自动冻结 / 放行（CPU 常驻，略耗电）")
         .setSmallIcon(android.R.drawable.ic_lock_lock)
         .setOngoing(true);
        return b.build();
    }
}

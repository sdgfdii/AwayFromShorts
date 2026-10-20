package com.afs.guard;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
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

    private final Handler handler = new Handler(Looper.getMainLooper());

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
        handler.post(tick);
        Log.i(Guard.TAG, "service started");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 被系统杀掉后自动拉起；onCreate 里已经挂了 tick，这里只需保证不重复挂
        handler.removeCallbacks(tick);
        handler.post(tick);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(tick);
        Log.w(Guard.TAG, "service destroyed");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
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
         .setContentText("到点自动冻结 / 放行，不用手动打开")
         .setSmallIcon(android.R.drawable.ic_lock_lock)
         .setOngoing(true);
        return b.build();
    }
}

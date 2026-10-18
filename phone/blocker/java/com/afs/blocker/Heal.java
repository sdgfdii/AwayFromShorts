package com.afs.blocker;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;

/**
 * 自愈：系统（ColorOS）会把无障碍开关清掉，普通 App 没权限改，但 Shizuku 以 shell 身份有。
 *
 * 每 2 分钟查一次，发现开关没了就写回去：
 *   1) appops set ... ACCESS_RESTRICTED_SETTINGS allow   （侧载应用的"受限设置"）
 *   2) settings put secure enabled_accessibility_services <我们的服务>
 *   3) settings put secure accessibility_enabled 1
 *
 * 只在 Shizuku 活着的时候有效（重启后 Shizuku 掉线 → 自愈也无法工作）。
 */
final class Heal {

    private static final String TAG = "AfsBlocker";
    static final String ACTION = "com.afs.blocker.HEAL";
    static final long INTERVAL_MS = 120000L;

    private Heal() {
    }

    /** 我们的无障碍服务是否在系统登记着。 */
    static boolean serviceEnabled(Context ctx) {
        try {
            String s = Settings.Secure.getString(ctx.getContentResolver(),
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
            if (s == null) {
                return false;
            }
            String me = ctx.getPackageName().toLowerCase();
            for (String part : s.split(":")) {
                String p = part.trim().toLowerCase();
                if (p.startsWith(me) && p.contains("blockerservice")) {
                    return true;
                }
            }
        } catch (Throwable ignored) {
        }
        return false;
    }

    /** 登记一次巡检。重复调用只是覆盖同一条，不会叠加。 */
    static void schedule(Context ctx) {
        try {
            AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am == null) {
                return;
            }
            Intent i = new Intent(ctx, HealReceiver.class).setAction(ACTION);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            PendingIntent pi = PendingIntent.getBroadcast(ctx, 1001, i, flags);
            am.setInexactRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + INTERVAL_MS, INTERVAL_MS, pi);
        } catch (Throwable t) {
            Log.w(TAG, "schedule heal failed: " + t);
        }
    }

    /** 执行一次自愈。返回 true 表示真的写回去了。 */
    static boolean healOnce(Context ctx) {
        try {
            if (serviceEnabled(ctx)) {
                return false;
            }
            ShizukuBridge.ensureBinder(ctx);
            if (!rikka.shizuku.Shizuku.pingBinder()) {
                return false;
            }
            if (rikka.shizuku.Shizuku.checkSelfPermission()
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                return false;
            }
            String svc = ctx.getPackageName() + "/" + BlockerService.class.getName();
            String cmd = "appops set " + ctx.getPackageName() + " ACCESS_RESTRICTED_SETTINGS allow; "
                    + "settings put secure enabled_accessibility_services " + svc + "; "
                    + "settings put secure accessibility_enabled 1; echo H";
            rikka.shizuku.ShizukuRemoteProcess rp = rikka.shizuku.Shizuku.newProcess(
                    new String[] {"/system/bin/sh", "-c", cmd}, null, null);
            java.io.InputStream in = rp.getInputStream();
            byte[] buf = new byte[64];
            int n = in.read(buf);
            String out = n > 0 ? new String(buf, 0, n) : "";
            rp.waitFor();
            boolean ok = serviceEnabled(ctx);
            Log.i(TAG, "heal ran, now=" + ok + " out=" + out.trim());
            return ok;
        } catch (Throwable t) {
            Log.w(TAG, "heal failed: " + t);
            return false;
        }
    }
}

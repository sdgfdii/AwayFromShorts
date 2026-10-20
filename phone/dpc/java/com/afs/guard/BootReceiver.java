package com.afs.guard;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * 开机 / 重装后重新落一遍状态并重排闹钟。
 *
 * ★ 这条链路必须通：pm install -r 和重启都会清掉 AlarmManager 里的闹钟，
 * 以前 receiver 写的是 exported=false，系统广播进不来 —— 结果闹钟永远不排，
 * 只有用户手动打开 App 那一刻才冻得上。
 */
public class BootReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context ctx, Intent intent) {
        String action = intent == null ? "null" : intent.getAction();
        Log.i(Guard.TAG, "BootReceiver: " + action);
        Guard.apply(ctx);
        Guard.schedule(ctx);
        Guard.ensureService(ctx);
    }
}

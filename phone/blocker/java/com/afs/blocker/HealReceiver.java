package com.afs.blocker;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** 定时自愈的落地点。开机也顺便把巡检链重新挂上。 */
public class HealReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(final Context ctx, Intent intent) {
        Heal.schedule(ctx);   // 不管什么原因被叫醒，先把下一次挂上
        final PendingResult pr = goAsync();
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    Heal.healOnce(ctx);
                } catch (Throwable ignored) {
                } finally {
                    pr.finish();
                }
            }
        }, "afs-heal").start();
    }
}

package com.afs.guard;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** 到点翻转状态，然后立刻排下一次。 */
public class AlarmReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context ctx, Intent intent) {
        Guard.apply(ctx);
        Guard.schedule(ctx);
    }
}

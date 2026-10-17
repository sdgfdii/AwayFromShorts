package com.afs.guard;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** 开机 / 重装后重新落一遍状态。冻结态本身是持久的，这一步只是纠正时钟漂移。 */
public class BootReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context ctx, Intent intent) {
        Guard.apply(ctx);
        Guard.schedule(ctx);
    }
}

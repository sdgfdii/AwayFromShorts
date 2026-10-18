package com.afs.blocker;

import android.content.Context;
import android.net.Uri;
import android.os.Bundle;
import android.os.IBinder;
import android.util.Log;

/**
 * Shizuku v12 的 binder 必须由应用主动去自己的 Provider 要一次，
 * 否则 Shizuku.pingBinder() 永远是 false（binder 只推给"已经在跑并且请求过"的进程）。
 *
 * 官方的 requestBinderForNonProviderProcess 在某些机型上不生效，所以这里直接
 * 调 Provider 的 getBinder 拿到 IBinder，再塞回 Shizuku.onBinderReceived()。
 */
final class ShizukuBridge {

    private static final String TAG = "AfsBlocker";

    private ShizukuBridge() {
    }

    static void ensureBinder(Context ctx) {
        try {
            if (rikka.shizuku.Shizuku.pingBinder()) {
                return;
            }
            Uri uri = Uri.parse("content://" + ctx.getPackageName() + ".shizuku");
            Bundle b = ctx.getContentResolver().call(
                    uri, rikka.shizuku.ShizukuProvider.METHOD_GET_BINDER, null, null);
            if (b == null) {
                return;
            }
            IBinder binder = b.getBinder(rikka.shizuku.ShizukuProvider.METHOD_SEND_BINDER);
            if (binder != null) {
                rikka.shizuku.Shizuku.onBinderReceived(binder, ctx.getPackageName());
                Log.i(TAG, "shizuku binder injected");
            }
        } catch (Throwable t) {
            Log.w(TAG, "ensureBinder failed: " + t);
        }
    }
}

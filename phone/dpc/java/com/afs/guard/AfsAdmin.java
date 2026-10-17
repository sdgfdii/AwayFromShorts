package com.afs.guard;

import android.app.admin.DeviceAdminReceiver;
import android.content.Context;
import android.content.Intent;

/** 只为拿到 Device Owner 身份。真正的逻辑全在 Guard 里。 */
public class AfsAdmin extends DeviceAdminReceiver {

    @Override
    public void onEnabled(Context ctx, Intent intent) {
        Guard.apply(ctx);
        Guard.schedule(ctx);
    }

    @Override
    public void onDisabled(Context ctx, Intent intent) {
        // 设备所有者不可能被正常停用；这里留着只为兜底日志
    }

    @Override
    public CharSequence onDisableRequested(Context ctx, Intent intent) {
        return "无法在此处停用。设备所有者只能通过 adb 移除：\n"
                + "adb shell dpm remove-active-admin com.afs.guard/.AfsAdmin";
    }

    @Override
    public void onProfileProvisioningComplete(Context ctx, Intent intent) {
        Guard.apply(ctx);
        Guard.schedule(ctx);
    }
}

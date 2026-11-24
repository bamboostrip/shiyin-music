package com.ryanheise.audioservice;

import android.content.Context;
import android.content.Intent;

public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";
    // LOCAL PATCH (shiyin): 通知栏自定义按钮点按（Android 12 及以下）的显式广播，
    // 由 AudioService.createCustomNotificationAction 构造、这里转交会话回调。
    public static final String ACTION_NOTIFICATION_CUSTOM_ACTION = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_CUSTOM_ACTION";
    public static final String EXTRA_CUSTOM_ACTION = "com.ryanheise.audioservice.extra.CUSTOM_ACTION";
    public static final String EXTRA_CUSTOM_ACTION_EXTRAS = "com.ryanheise.audioservice.extra.CUSTOM_ACTION_EXTRAS";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent != null
                && ACTION_NOTIFICATION_DELETE.equals(intent.getAction())
                && AudioService.instance != null) {
            AudioService.instance.handleDeleteNotification();
            return;
        }
        // LOCAL PATCH (shiyin): 服务不在（通知残留时进程被回收后点按）就当没
        // 点过：不启动服务、不落到 super.onReceive 的媒体键处理。
        if (intent != null
                && ACTION_NOTIFICATION_CUSTOM_ACTION.equals(intent.getAction())) {
            if (AudioService.instance != null) {
                AudioService.instance.handleCustomActionNotification(
                        intent.getStringExtra(EXTRA_CUSTOM_ACTION),
                        intent.getBundleExtra(EXTRA_CUSTOM_ACTION_EXTRAS));
            }
            return;
        }
        super.onReceive(context, intent);
    }
}

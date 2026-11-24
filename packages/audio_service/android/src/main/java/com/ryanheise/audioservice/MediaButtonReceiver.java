package com.ryanheise.audioservice;

import android.content.Context;
import android.content.Intent;
import android.util.Log;

public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";
    // LOCAL PATCH (shiyin): 通知栏自定义按钮点按（Android 12 及以下）的显式广播，
    // 由 AudioService.createCustomNotificationAction 构造、这里转交会话回调。
    public static final String ACTION_NOTIFICATION_CUSTOM_ACTION = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_CUSTOM_ACTION";
    public static final String EXTRA_CUSTOM_ACTION = "com.ryanheise.audioservice.extra.CUSTOM_ACTION";
    public static final String EXTRA_CUSTOM_ACTION_EXTRAS = "com.ryanheise.audioservice.extra.CUSTOM_ACTION_EXTRAS";
    // LOCAL PATCH (shiyin): 防伪造令牌。receiver 必须 exported=true（系统媒体键），
    // 显式广播任何 App 都能发；令牌只存在本进程，外部无法伪造。
    public static final String EXTRA_CUSTOM_ACTION_TOKEN = "com.ryanheise.audioservice.extra.CUSTOM_ACTION_TOKEN";

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
            final String token = intent.getStringExtra(EXTRA_CUSTOM_ACTION_TOKEN);
            // 只有 AudioService 自己构造的 PendingIntent 才带正确令牌；外部
            // App 显式广播猜不到，直接丢弃。旧版本残留通知无令牌也一并丢弃。
            if (AudioService.instance != null
                    && AudioService.CUSTOM_ACTION_TOKEN.equals(token)) {
                try {
                    AudioService.instance.handleCustomActionNotification(
                            intent.getStringExtra(EXTRA_CUSTOM_ACTION),
                            intent.getBundleExtra(EXTRA_CUSTOM_ACTION_EXTRAS));
                } catch (Exception e) {
                    // 广播 extras 是外部输入；解析失败不能打崩主线程。
                    Log.w("MediaButtonReceiver", "自定义按钮广播处理失败", e);
                }
            }
            return;
        }
        super.onReceive(context, intent);
    }
}

package com.ryanheise.audioservice;

import android.content.Context;
import android.content.Intent;

public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";
    // 自研补丁：自定义动作按钮点击直达（不经媒体会话 keycode 路由）。
    public static final String ACTION_CUSTOM = "com.ryanheise.audioservice.intent.action.ACTION_CUSTOM";
    public static final String EXTRA_CUSTOM_NAME = "com.ryanheise.audioservice.extra.CUSTOM_ACTION_NAME";
    public static final String EXTRA_CUSTOM_EXTRAS = "com.ryanheise.audioservice.extra.CUSTOM_ACTION_EXTRAS";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent != null
                && ACTION_NOTIFICATION_DELETE.equals(intent.getAction())
                && AudioService.instance != null) {
            AudioService.instance.handleDeleteNotification();
            return;
        }
        if (intent != null
                && ACTION_CUSTOM.equals(intent.getAction())
                && AudioService.instance != null) {
            AudioService.instance.handleCustomAction(
                    intent.getStringExtra(EXTRA_CUSTOM_NAME),
                    intent.getBundleExtra(EXTRA_CUSTOM_EXTRAS));
            return;
        }
        super.onReceive(context, intent);
    }
}
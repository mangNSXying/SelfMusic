package com.shamiko.selfmusic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 静音暂停 / 断连暂停的原生信号源（settings.md §3.2，仅 Android）。
 *
 * 为什么自持监听而不用 audio_session：后者的 becoming-noisy 接收器只在
 * just_audio 因音频焦点接管而请求焦点时才注册（AndroidAudioManager.java
 * 的 registerNoisyReceiver 位于 requestAudioFocus 分支内）——音频焦点关闭时
 * 「断连暂停」会彻底失效，恰是用户最需要它的情形。故这里独立注册。
 *
 * 通道契约（Dart 侧 lib/services/playback_guard.dart）：
 * - MethodChannel `com.shamiko.selfmusic/audio_guard`
 *     `getMediaVolume()` → Int?（STREAM_MUSIC 当前档位；读取不到为 null）
 * - EventChannel `com.shamiko.selfmusic/audio_guard/events`（仅在 Dart 订阅时注册）
 *     `{type:"volume", value:Int}`  媒体音量变化
 *     `{type:"outputLost"}`         当前输出设备断开（ACTION_AUDIO_BECOMING_NOISY）
 *
 * becoming-noisy 由系统在**当前活跃输出**设备被移除时广播（耳机拔出、蓝牙音箱
 * 掉线、USB DAC 拔出等）；用户主动从蓝牙切到扬声器不触发（设备仍在连），
 * 与「断连暂停」的预期语义一致。
 */
class AudioGuard(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private companion object {
        const val METHOD_CHANNEL = "com.shamiko.selfmusic/audio_guard"
        const val EVENT_CHANNEL = "com.shamiko.selfmusic/audio_guard/events"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    /** 上次上报的音量档位（去重；ContentObserver 会对任意系统设置变化触发）。 */
    private var lastVolume = Int.MIN_VALUE

    /**
     * 媒体音量监听：注册在 Settings.System.CONTENT_URI 上（仅公共 API；
     * `AudioManager.VOLUME_CHANGED_ACTION` 及其 extra 为隐藏 API，不可用）。
     * 任意系统设置变化时回读 STREAM_MUSIC 并去重上报。
     */
    private val volumeObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            emitVolumeIfChanged()
        }
    }

    /** 由 MainActivity.configureFlutterEngine 调用。 */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getMediaVolume" -> result.success(currentVolume())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
        // 订阅即注册（Dart 侧仅在开关开启时订阅，关闭即注销）。
        try {
            context.contentResolver.registerContentObserver(
                Settings.System.CONTENT_URI, true, volumeObserver)
        } catch (_: Exception) {
        }
        lastVolume = Int.MIN_VALUE
        emitVolumeIfChanged()
        registerNoisyReceiver()
    }

    override fun onCancel(arguments: Any?) {
        unregisterNoisyReceiver()
        try {
            context.contentResolver.unregisterContentObserver(volumeObserver)
        } catch (_: Exception) {
        }
        eventSink = null
    }

    private fun audioManager(): AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private fun currentVolume(): Int? =
        audioManager()?.getStreamVolume(AudioManager.STREAM_MUSIC)

    private fun emitVolumeIfChanged() {
        val v = currentVolume() ?: return
        if (v == lastVolume) return
        lastVolume = v
        eventSink?.success(mapOf("type" to "volume", "value" to v))
    }

    private fun registerNoisyReceiver() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    eventSink?.success(mapOf("type" to "outputLost"))
                }
            }
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        // 系统广播：RECEIVER_NOT_EXPORTED 安全且可正常收到（Android 14 要求显式标注）。
        ContextCompat.registerReceiver(
            context, r, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        receiver = r
    }

    private fun unregisterNoisyReceiver() {
        val r = receiver ?: return
        receiver = null
        try {
            context.unregisterReceiver(r)
        } catch (_: IllegalArgumentException) {
        }
    }
}

package com.shamiko.selfmusic

import android.content.Context
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 触感反馈（设置→界面→交互，仅 Android，settings.md §3.7）。
 *
 * 通道契约（Dart 侧 lib/services/haptics.dart，与鸿蒙端同名）：
 * - MethodChannel `com.shamiko.selfmusic/vibration`
 *     `hasVibrator()` → Boolean
 *     `vibrate(durationMs:Int, amplitude:Int?)` → Boolean（是否已触发）
 *     `cancel()` → null
 *
 * 直连 Vibrator 而不是 View.performHapticFeedback：需要可控时长/振幅，
 * 保证各 OEM 上按键反馈一致。VIBRATE 是 normal 权限，安装即授予；
 * 系统「触感反馈」总开关关闭时整体跳过。
 */
class VibrationController(context: Context) : MethodChannel.MethodCallHandler {

    private val appContext = context.applicationContext

    private companion object {
        const val CHANNEL = "com.shamiko.selfmusic/vibration"
    }

    /** 由 MainActivity.configureFlutterEngine 调用。 */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasVibrator" -> result.success(vibrator()?.hasVibrator() == true)
            "vibrate" -> {
                val durationMs = call.argument<Int>("durationMs") ?: 0
                if (durationMs <= 0) {
                    result.success(false)
                    return
                }
                result.success(vibrate(durationMs, call.argument<Int>("amplitude")))
            }
            "cancel" -> {
                try {
                    vibrator()?.cancel()
                } catch (_: Exception) {
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (appContext.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            appContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    private fun vibrate(durationMs: Int, amplitude: Int?): Boolean {
        val v = vibrator() ?: return false
        if (!v.hasVibrator()) return false
        if (!systemHapticsEnabled()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val attributes = VibrationAttributes.createForUsage(
                    VibrationAttributes.USAGE_TOUCH)
                v.vibrate(effect(v, durationMs, amplitude), attributes)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(effect(v, durationMs, amplitude))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(durationMs.toLong())
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun effect(v: Vibrator, durationMs: Int, amplitude: Int?): VibrationEffect {
        val amp = if (v.hasAmplitudeControl() && amplitude != null) {
            amplitude.coerceIn(1, 255)
        } else {
            VibrationEffect.DEFAULT_AMPLITUDE
        }
        return VibrationEffect.createOneShot(durationMs.toLong(), amp)
    }

    /** 系统设置 → 声音与振动 → 触感反馈（部分 OEM 不维护该键，读取失败按开启处理）。 */
    private fun systemHapticsEnabled(): Boolean = try {
        Settings.System.getInt(
            appContext.contentResolver,
            Settings.System.HAPTIC_FEEDBACK_ENABLED,
            1,
        ) != 0
    } catch (_: Exception) {
        true
    }
}

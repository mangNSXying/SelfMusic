package com.shamiko.selfmusic

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * 应用级均衡器（settings.md §3.2）。
 *
 * just_audio 通过 EventChannel 上报 ExoPlayer 的 audioSessionId，本类把效果
 * 挂到该 session：
 * - Android 9+ 优先 DynamicsProcessing 的 10 段 pre-EQ；
 * - 设备不支持/创建失败时回退系统 Equalizer（常见 5 段，按设备中心频率映射）；
 * - 两者都不可用时返回 unsupported，UI 降级提示。
 *
 * 通道契约（Dart 侧 lib/services/equalizer/android_equalizer_backend.dart）：
 *   attach{sessionId, enabled, frequencies, gains, preampDb} -> capabilities
 *   update{sessionId, enabled, gains, preampDb} -> capabilities
 *   detach{} -> null
 */
class EqualizerController : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "com.shamiko.selfmusic/equalizer"
        private const val MIN_DB = -12.0f
        private const val MAX_DB = 12.0f
        private const val MIN_PREAMP_DB = -12.0f
        private const val MAX_PREAMP_DB = 0.0f
        private const val MAX_FREQUENCY = 20000.0

        @Volatile
        private var instance: EqualizerController? = null

        /// 进程级单例：Activity 重建/退后台时保持 AudioEffect 引用，
        /// 避免 GC finalizer 释放效果导致后台播放 EQ 失效。
        @JvmStatic
        fun shared(): EqualizerController =
            instance ?: synchronized(this) {
                instance ?: EqualizerController().also { instance = it }
            }
    }

    private var channel: MethodChannel? = null
    private var dynamics: DynamicsProcessing? = null
    private var equalizer: Equalizer? = null
    private var sessionId: Int = 0
    private var enabled = false
    private var frequencies: List<Double> = emptyList()
    private var gains: List<Double> = emptyList()
    private var preampDb = 0.0

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "attach" -> {
                val sid = (call.argument<Number>("sessionId"))?.toInt() ?: 0
                val freqs = readDoubles(call.argument<List<*>>("frequencies"))
                val levels = readDoubles(call.argument<List<*>>("gains"))
                val preamp = (call.argument<Number>("preampDb"))?.toDouble() ?: 0.0
                val on = call.argument<Boolean>("enabled") ?: false
                result.success(attach(sid, on, freqs, levels, preamp))
            }
            "update" -> {
                val levels = readDoubles(call.argument<List<*>>("gains"))
                val preamp = (call.argument<Number>("preampDb"))?.toDouble() ?: 0.0
                val on = call.argument<Boolean>("enabled") ?: false
                result.success(update(on, levels, preamp))
            }
            "detach" -> {
                detach()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun readDoubles(raw: List<*>?): List<Double> =
        raw.orEmpty().mapNotNull { (it as? Number)?.toDouble() }

    private fun attach(
        sid: Int,
        on: Boolean,
        freqs: List<Double>,
        levels: List<Double>,
        preamp: Double,
    ): Map<String, Any?> {
        if (sid <= 0) return unsupported("无效的音频会话")
        releaseEffects()
        sessionId = sid
        enabled = on
        frequencies = freqs.ifEmpty {
            // Dart 侧总会传标准 10 段；兜底防止空参数导致除零。
            listOf(31.5, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)
        }
        gains = normalizeGains(levels, frequencies.size)
        preampDb = preamp.coerceIn(MIN_PREAMP_DB.toDouble(), MAX_PREAMP_DB.toDouble())

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val dp = createDynamics()
            if (dp != null) {
                dynamics = dp
                return capabilities(
                    "dynamics",
                    frequencies,
                    MIN_DB.toDouble(),
                    MAX_DB.toDouble(),
                    null,
                )
            }
        }

        val eq = createEqualizer()
        if (eq != null) {
            equalizer = eq
            return equalizerCapabilities(eq)
        }

        return unsupported("设备不支持音频均衡器效果")
    }

    @SuppressLint("NewApi")
    private fun update(on: Boolean, levels: List<Double>, preamp: Double): Map<String, Any?> {
        enabled = on
        gains = normalizeGains(levels, frequencies.size)
        preampDb = preamp.coerceIn(MIN_PREAMP_DB.toDouble(), MAX_PREAMP_DB.toDouble())
        try {
            val dp = dynamics
            if (dp != null) {
                applyDynamicsGains(dp)
                dp.setInputGainAllChannelsTo(preampDb.toFloat())
                dp.enabled = enabled
                return capabilities(
                    "dynamics",
                    frequencies,
                    MIN_DB.toDouble(),
                    MAX_DB.toDouble(),
                    null,
                )
            }
            val eq = equalizer
            if (eq != null) {
                applyEqualizerGains(eq)
                eq.enabled = enabled
                return equalizerCapabilities(eq)
            }
        } catch (_: Throwable) {
            // 效果被系统回收/控制权丢失：释放后按当前参数重建一次。
            val sid = sessionId
            releaseEffects()
            if (sid > 0) {
                return attach(sid, enabled, frequencies, gains, preampDb)
            }
        }
        return unsupported("均衡器尚未挂载")
    }

    private fun normalizeGains(levels: List<Double>, count: Int): List<Double> =
        List(count) { i ->
            (levels.getOrNull(i) ?: 0.0)
                .coerceIn(MIN_DB.toDouble(), MAX_DB.toDouble())
        }

    @TargetApi(Build.VERSION_CODES.P)
    private fun createDynamics(): DynamicsProcessing? {
        var dp: DynamicsProcessing? = null
        return try {
            val bandCount = frequencies.size.coerceAtLeast(1)
            val builder = DynamicsProcessing.Config.Builder(
                DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                2,
                true,
                bandCount,
                false,
                0,
                false,
                0,
                false,
            )
            val config = builder.build()
            val cutoffs = cutoffFrequencies(frequencies)
            for (i in 0 until bandCount) {
                config.setPreEqBandAllChannelsTo(
                    i,
                    DynamicsProcessing.EqBand(
                        true,
                        cutoffs[i].toFloat(),
                        gains.getOrElse(i) { 0.0 }.toFloat(),
                    ),
                )
            }
            config.setInputGainAllChannelsTo(preampDb.toFloat())
            dp = DynamicsProcessing(0, sessionId, config)
            dp.enabled = enabled
            dp
        } catch (_: Throwable) {
            try {
                dp?.release()
            } catch (_: Throwable) {
            }
            null
        }
    }

    private fun createEqualizer(): Equalizer? {
        var eq: Equalizer? = null
        return try {
            eq = Equalizer(0, sessionId)
            applyEqualizerGains(eq)
            eq.enabled = enabled
            eq
        } catch (_: Throwable) {
            try {
                eq?.release()
            } catch (_: Throwable) {
            }
            null
        }
    }

    @SuppressLint("NewApi")
    private fun applyDynamicsGains(dp: DynamicsProcessing) {
        val cutoffs = cutoffFrequencies(frequencies)
        for (i in frequencies.indices) {
            dp.setPreEqBandAllChannelsTo(
                i,
                DynamicsProcessing.EqBand(
                    true,
                    cutoffs[i].toFloat(),
                    gains.getOrElse(i) { 0.0 }.toFloat(),
                ),
            )
        }
    }

    private fun applyEqualizerGains(eq: Equalizer) {
        val count = eq.numberOfBands.toInt()
        val range = eq.bandLevelRange
        val minMb = if (range.isNotEmpty()) range[0].toInt() else -1500
        val maxMb = if (range.size > 1) range[1].toInt() else 1500
        for (band in 0 until count) {
            val centerHz = eq.getCenterFreq(band.toShort()) / 1000.0
            val db = canonicalGainAt(centerHz)
            val mb = (db * 1000.0).toInt().coerceIn(minMb, maxMb)
            eq.setBandLevel(band.toShort(), mb.toShort())
        }
    }

    /** 把 10 段标准增益按对数频率插值到设备 Equalizer 的中心频率。 */
    private fun canonicalGainAt(frequency: Double): Double {
        if (frequencies.isEmpty() || gains.isEmpty()) return 0.0
        if (frequency <= frequencies.first()) return gains.first()
        if (frequency >= frequencies.last()) return gains.last()
        for (i in 0 until frequencies.size - 1) {
            val f0 = frequencies[i]
            val f1 = frequencies[i + 1]
            if (frequency > f1) continue
            val t = (log10(frequency) - log10(f0)) / (log10(f1) - log10(f0))
            return gains[i] + (gains[i + 1] - gains[i]) * t
        }
        return gains.last()
    }

    /** DynamicsProcessing EqBand cutoff 是频段上沿；用相邻中心频率几何平均。 */
    private fun cutoffFrequencies(freqs: List<Double>): List<Double> {
        if (freqs.isEmpty()) return listOf(MAX_FREQUENCY)
        return List(freqs.size) { i ->
            if (i >= freqs.size - 1) MAX_FREQUENCY
            else sqrt(freqs[i] * freqs[i + 1])
        }
    }

    private fun equalizerCapabilities(eq: Equalizer): Map<String, Any?> {
        val count = eq.numberOfBands.toInt()
        val centers = List(count) { i -> eq.getCenterFreq(i.toShort()) / 1000.0 }
        val range = eq.bandLevelRange
        val minDb = if (range.isNotEmpty()) range[0] / 1000.0 else -15.0
        val maxDb = if (range.size > 1) range[1] / 1000.0 else 15.0
        return capabilities(
            "equalizer",
            centers,
            minDb,
            maxDb,
            "当前设备仅支持 $count 段，10 段设置已自动映射",
        )
    }

    private fun capabilities(
        type: String,
        freqs: List<Double>,
        minDb: Double,
        maxDb: Double,
        note: String?,
    ): Map<String, Any?> = mapOf(
        "kind" to type,
        "bandCount" to freqs.size,
        "frequencies" to freqs,
        "minDb" to minDb,
        "maxDb" to maxDb,
        "note" to note,
    )

    private fun unsupported(note: String): Map<String, Any?> = mapOf(
        "kind" to "unsupported",
        "bandCount" to 0,
        "frequencies" to emptyList<Double>(),
        "minDb" to MIN_DB.toDouble(),
        "maxDb" to MAX_DB.toDouble(),
        "note" to note,
    )

    private fun detach() {
        releaseEffects()
        sessionId = 0
        frequencies = emptyList()
        gains = emptyList()
        preampDb = 0.0
        enabled = false
    }

    private fun releaseEffects() {
        try {
            dynamics?.release()
        } catch (_: Throwable) {
        }
        dynamics = null
        try {
            equalizer?.release()
        } catch (_: Throwable) {
        }
        equalizer = null
    }
}

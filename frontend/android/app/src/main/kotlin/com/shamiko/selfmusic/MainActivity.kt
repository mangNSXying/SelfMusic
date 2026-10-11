package com.shamiko.selfmusic

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service 要求启动 Activity 为其子类（否则 AudioService.init 会因引擎不匹配抛
// IllegalStateException → main() 中止 → 白屏）。见 audio_service README「Custom Android activity」。
//
// 另提供「播放页常亮」的蓝牙查询通道（已配对设备 / 当前连接的音频设备），
// Android 12+ 需 BLUETOOTH_CONNECT 运行时权限。
class MainActivity : AudioServiceActivity() {

    private val channelName = "com.shamiko.selfmusic/bluetooth"
    private val appChannelName = "com.shamiko.selfmusic/app"

    // 静音/断连暂停的原生信号源（settings.md §3.2，selfmusic/audio_guard 通道）。
    private val audioGuard: AudioGuard by lazy { AudioGuard(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioGuard.register(flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasConnectPermission" -> result.success(hasConnectPermission())
                    "listBondedDevices" -> result.success(listBondedDevices())
                    "connectedDevices" -> result.success(connectedDeviceAddresses())
                    else -> result.notImplemented()
                }
            }
// 返回手势转后台：moveTaskToBack 与 home 键等效，Activity 不
// 销毁、audio_service 前台服务不受影响（侧滑返回曾直接退出应用，
// 无法后台播放，2026-09-29 用户反馈）。
//（API 37 起 Activity.moveTaskToBackground 已移除，统一用 moveTaskToBack。）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveToBackground" -> result.success(moveTaskToBack(true))
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasConnectPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    /** 已配对设备（名称+地址）；无权限/蓝牙关闭时返回空表。 */
    private fun listBondedDevices(): List<Map<String, String>> {
        if (!hasConnectPermission()) return emptyList()
        val adapter = getSystemService(BluetoothManager::class.java)?.adapter
            ?: return emptyList()
        if (!adapter.isEnabled) return emptyList()
        return adapter.bondedDevices.mapNotNull { d ->
            val name = d.name ?: return@mapNotNull null
            mapOf("name" to name, "address" to d.address)
        }
    }

    /** 当前已连接的音频类设备地址（A2DP/耳机/助听器/LE Audio）。 */
    private fun connectedDeviceAddresses(): List<String> {
        if (!hasConnectPermission()) return emptyList()
        val bm = getSystemService(BluetoothManager::class.java) ?: return emptyList()
        val out = LinkedHashSet<String>()
        val profiles = arrayListOf(
            BluetoothProfile.A2DP,
            BluetoothProfile.HEADSET,
            BluetoothProfile.HEARING_AID,
        )
        // LE Audio（API 33+）：新一代 TWS/耳机只挂在 LE_AUDIO profile 上。漏掉它，
        // 限定这些设备常亮时会永远判为「未连接」，于是只有「不限定」才生效。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            profiles.add(BluetoothProfile.LE_AUDIO)
        }
        for (profile in profiles) {
            try {
                bm.getConnectedDevices(profile).forEach { out.add(it.address) }
            } catch (_: Exception) {
                // 部分设备/系统不支持该 profile，跳过。
            }
        }
        return out.toList()
    }
}

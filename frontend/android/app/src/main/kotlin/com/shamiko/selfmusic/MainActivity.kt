package com.shamiko.selfmusic

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service 要求启动 Activity 为其子类（否则 AudioService.init 会因引擎不匹配抛
// IllegalStateException → main() 中止 → 白屏）。见 audio_service README「Custom Android activity」。
class MainActivity : AudioServiceActivity()

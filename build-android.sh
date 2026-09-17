#!/usr/bin/env bash
# 打轻量级 Android 安装包（release + 按 ABI 拆分）。
# 产物：frontend/build/app/outputs/flutter-apk/app-<abi>-release.apk
# 真机（arm64）装 app-arm64-v8a-release.apk，约 22MB。
# 注意：flutter run / app-debug.apk 是 debug 包，含 JIT 快照与全部 ABI，约 200MB，勿用于分发。
set -e
cd "$(dirname "$0")/frontend"
flutter build apk --release --split-per-abi "$@"
ls -lh build/app/outputs/flutter-apk/*-release.apk

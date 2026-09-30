@echo off
cd frontend
call flutter-ohos build hap --release --target-arch=arm64 --target-arch=armv7 --target-arch=x86

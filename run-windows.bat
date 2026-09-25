@echo off
rem 运行 Windows 桌面版（连接局域网后端）。
rem FLUTTER_BIN 指向本机 Flutter（默认用双线隔离 wrapper，可按需改成你的 flutter 路径）。
set "FLUTTER_BIN=D:\Users\shamiko\Documents\Flutter\bin\flutter-win.bat"
cd /d "%~dp0frontend"
call "%FLUTTER_BIN%" run -d windows --dart-define=API_BASE_URL=http://192.168.3.25:18089 %*

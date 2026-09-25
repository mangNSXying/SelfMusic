@echo off
rem Run the Windows desktop build (LAN backend).
rem FLUTTER_BIN points to the dual-SDK isolated wrapper; change it to
rem your own flutter path if needed.
set "FLUTTER_BIN=D:\Users\shamiko\Documents\Flutter\bin\flutter-win.bat"
rem permission_handler_windows needs nuget.exe (it fetches CppWinRT headers).
rem Keep nuget.exe next to the wrapper and prepend its folder to PATH, so
rem CMake find_program() picks it up instead of hanging in its own
rem FetchContent downloader.
for %%i in ("%FLUTTER_BIN%") do set "FLUTTER_DIR=%%~dpi"
set "PATH=%FLUTTER_DIR%;%PATH%"
rem Keep nuget's HTTP cache on the toolchain drive, not in C:\Users\...\AppData.
set "NUGET_HTTP_CACHE_PATH=%FLUTTER_DIR%NuGetHttpCache"
cd /d "%~dp0frontend"
call "%FLUTTER_BIN%" run -d windows --dart-define=API_BASE_URL=http://192.168.3.25:18089 %*

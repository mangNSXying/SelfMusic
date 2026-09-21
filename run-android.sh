# adb pair ip:port
# adb connect ip:port
cd frontend && flutter run -d 192.168.3.62:41805 --dart-define=API_BASE_URL=http://192.168.3.25:18089 --dart-define=BUILD_STAMP="$(date +%F_%T)"

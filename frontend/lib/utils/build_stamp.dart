/// 构建标识（`--dart-define=BUILD_STAMP=...` 注入；run-android.sh / build-android.sh 自动带上）。
///
/// 用于在「信息」页一眼确认手机上跑的是哪次构建（本地源码调试时为空）。
const String kBuildStamp = String.fromEnvironment('BUILD_STAMP');

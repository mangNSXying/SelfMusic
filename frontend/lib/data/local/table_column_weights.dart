import 'package:flutter/foundation.dart';

/// 表格列宽变更广播。
///
/// `AppSettings.settingsSet` 本身不通知监听者；各页面各自持有一份列宽状态，
/// 手调后需要跨页面同步（歌单/喜欢/歌曲/源页同时保活时尤其明显），所以在
/// 写入列宽设置时统一 bump 一次。
class TableColumnWeightsRevision extends ChangeNotifier {
  TableColumnWeightsRevision._();

  static final TableColumnWeightsRevision instance =
      TableColumnWeightsRevision._();

  int value = 0;

  void bump() {
    value++;
    notifyListeners();
  }
}

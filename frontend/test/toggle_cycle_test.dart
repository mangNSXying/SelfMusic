import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/collection_sort.dart';
import 'package:selfmusic/utils/toggle_cycle.dart';
import 'package:selfmusic/widgets/song_table.dart';

void main() {
  test('二态环：true → false → true', () {
    expect(nextInCycle(true, const [true, false]), isFalse);
    expect(nextInCycle(false, const [true, false]), isTrue);
  });

  test('排序三态环：升 → 降 → 默认 → 升', () {
    expect(CollectionSort.charAsc.nextOnClick(CollectionSort.charAsc),
        CollectionSort.charDesc);
    expect(CollectionSort.charAsc.nextOnClick(CollectionSort.charDesc),
        CollectionSort.defaultOrder);
    expect(CollectionSort.charAsc.nextOnClick(CollectionSort.defaultOrder),
        CollectionSort.charAsc);
  });

  test('排序三态环：换字段从升序开始', () {
    expect(CollectionSort.playCountAsc.nextOnClick(CollectionSort.charDesc),
        CollectionSort.playCountAsc);
    expect(CollectionSort.playCountAsc.nextOnClick(CollectionSort.artistAsc),
        CollectionSort.playCountAsc);
  });

  test('表头 nextSort 与排序菜单共用同一环', () {
    for (final asc in [
      CollectionSort.charAsc,
      CollectionSort.artistAsc,
      CollectionSort.albumAsc,
      CollectionSort.durationAsc,
    ]) {
      expect(SongTableHeader.nextSort(asc, asc), asc.flipped);
      expect(SongTableHeader.nextSort(asc.flipped, asc),
          CollectionSort.defaultOrder);
      expect(
          SongTableHeader.nextSort(CollectionSort.defaultOrder, asc), asc);
    }
  });
}

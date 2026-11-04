import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/off_thread.dart';
import 'package:selfmusic/utils/zh_variant.dart';

OpenccConverter _conv(Map<String, String> entries) =>
    OpenccConverter.fromEntries(entries);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OpenCC 词库解析', () {
    test('跳过注释/空行，多值取第一个', () {
      final m = parseOpenccEntries(
        '# Open Chinese Convert (OpenCC) Dictionary\n'
        '\n'
        '週\t周\n'
        '乾\t干 乾\n'
        '頭髮\t头发\n',
      );
      expect(m['週'], '周');
      expect(m['乾'], '干');
      expect(m['頭髮'], '头发');
      expect(m.containsKey('# Open Chinese Convert (OpenCC) Dictionary'), isFalse);
    });
  });

  group('转换器', () {
    final t2s = _conv({
      '週': '周',
      '傑': '杰',
      '倫': '伦',
      '藝': '艺',
      '術': '术',
      '髮': '发',
      '乾': '干',
      '頭髮': '头发',
      '藝術': '艺术',
      '乾隆': '乾隆',
    });
    final s2t = _conv({
      '周': '周',
      '杰': '傑',
      '伦': '倫',
      '艺': '藝',
      '术': '術',
      '发': '發',
      '干': '乾',
      '头发': '頭髮',
      '艺术': '藝術',
      '干杯': '乾杯',
    });

    test('繁转简：词组优先于单字', () {
      expect(t2s.convert('周傑倫'), '周杰伦');
      expect(t2s.convert('頭髮'), '头发');
      expect(t2s.convert('藝術'), '艺术');
      // 词组保护：乾隆 不拆成 干隆。
      expect(t2s.convert('乾隆'), '乾隆');
      expect(t2s.convert('乾杯'), '干杯');
    });

    test('简转繁：词组优先于单字', () {
      expect(s2t.convert('头发'), '頭髮');
      expect(s2t.convert('干杯'), '乾杯');
      expect(s2t.convert('周杰伦'), '周傑倫');
    });

    test('非中文原样保留', () {
      expect(t2s.convert('Hello 2026!'), 'Hello 2026!');
      expect(t2s.convert('さくら カタカナ'), 'さくら カタカナ');
      expect(t2s.convert(''), '');
    });

    test('未命中的中文原样保留', () {
      expect(t2s.convert('雨天'), '雨天');
    });
  });

  group('全局状态', () {
    tearDown(debugResetZhForTest);

    test('原文模式：词库未预热时按原字面', () {
      expect(zhVariant, ZhVariant.original);
      expect(zhDisplay('周傑倫'), '周傑倫');
      expect(zhSearchFold('周傑倫'), '周傑倫');
      expect(zhQueryVariants('周傑倫'), ['周傑倫']);
    });

    test('原文模式：显示保持原文，搜索仍可折叠', () {
      debugInstallZhConvertersForTest(
        t2s: _conv({'傑': '杰', '倫': '伦', '週': '周'}),
        s2t: _conv({'杰': '傑', '伦': '倫', '周': '周'}),
        variant: ZhVariant.original,
      );
      expect(zhDisplay('周傑倫'), '周傑倫');
      expect(zhSearchFold('周傑倫'), '周杰伦');
      expect(zhQueryVariants('周杰伦'), containsAll(['周杰伦', '周傑倫']));
    });

    test('简体：展示与搜索折叠、查询变体', () {
      final t2s = _conv({'傑': '杰', '倫': '伦', '週': '周'});
      final s2t = _conv({'杰': '傑', '伦': '倫', '周': '周'});
      debugInstallZhConvertersForTest(t2s: t2s, s2t: s2t);

      expect(zhVariant, ZhVariant.simplified);
      expect(zhDisplay('周傑倫'), '周杰伦');
      expect(zhDisplay('Hello'), 'Hello');
      expect(zhSearchFold('周傑倫'), '周杰伦');
      expect(zhSearchFold('周杰伦'), '周杰伦');
      expect(zhQueryVariants(' 周杰伦 '), containsAll(['周杰伦', '周傑倫']));
      expect(zhQueryVariants('   '), isEmpty);
    });

    test('繁体：展示转繁体', () {
      final t2s = _conv({'傑': '杰', '倫': '伦'});
      final s2t = _conv({'杰': '傑', '伦': '倫'});
      debugInstallZhConvertersForTest(
          t2s: t2s, s2t: s2t, variant: ZhVariant.traditional);

      expect(zhDisplay('周杰伦'), '周傑倫');
      // 搜索仍统一折叠为简体。
      expect(zhSearchFold('周傑倫'), '周杰伦');
    });

    test('切换后缓存失效', () {
      final t2s = _conv({'傑': '杰', '倫': '伦'});
      debugInstallZhConvertersForTest(
          t2s: t2s, s2t: t2s, variant: ZhVariant.simplified);
      expect(zhDisplay('周傑倫'), '周杰伦');
      expect(zhVariantRevision, greaterThan(0));

      debugResetZhForTest();
      expect(zhDisplay('周傑倫'), '周傑倫');
    });
  });

  group('内置 OpenCC 1.4.2 词库', () {
    tearDown(debugResetZhForTest);

    test('预热搜索词库：原文模式也可跨简繁搜索', () async {
      debugResetZhForTest();
      expect(await ensureZhSearchEngine(), isTrue);
      expect(zhVariant, ZhVariant.original);
      // 显示仍是原文，搜索已折叠。
      expect(zhDisplay('周傑倫'), '周傑倫');
      expect(zhSearchFold('周傑倫'), '周杰伦');
      // OpenCC 专名保护：周杰伦 的繁体规范写法是「周杰倫」（杰不换傑）。
      expect(zhQueryVariants('周杰伦'), contains('周杰倫'));
      // 已加载不重复解析。
      expect(await ensureZhSearchEngine(), isFalse);

      // 切到简体再切回原文：词库保留，搜索继续生效。
      expect(await applyZhVariant(ZhVariant.simplified), isTrue);
      expect(await applyZhVariant(ZhVariant.original), isTrue);
      expect(zhSearchFold('周傑倫'), '周杰伦');
    });

    test('资源加载与真实转换（后台 isolate 解析）', () async {
      // 强制走真实 Isolate.run，验证「解析结果（自定义对象）跨 isolate 回传」
      // 在真机上同样成立；测试环境默认内联。
      forceOffThreadIsolateInTests = true;
      addTearDown(() => forceOffThreadIsolateInTests = false);
      expect(await applyZhVariant(ZhVariant.simplified), isTrue);
      expect(zhDisplay('周杰倫'), '周杰伦');
      expect(zhDisplay('藝術'), '艺术');
      expect(zhDisplay('頭髮'), '头发');
      expect(zhDisplay('傷心'), '伤心');
      expect(zhDisplay('ABC 123'), 'ABC 123');
      expect(zhDisplay('さくら'), 'さくら');

      expect(await applyZhVariant(ZhVariant.traditional), isTrue);
      expect(zhDisplay('头发'), '頭髮');
      expect(zhDisplay('干杯'), '乾杯');
      // OpenCC 对「周杰伦」有专名保护：繁体规范写法是「周杰倫」（杰不换傑）。
      expect(zhDisplay('周杰伦'), '周杰倫');

      // 跨字形搜索：简体查询也能命中繁体存储。
      debugResetZhForTest();
      expect(await applyZhVariant(ZhVariant.simplified), isTrue);
      expect(zhSearchFold('周傑倫'), zhSearchFold('周杰伦'));
      expect(zhQueryVariants('周杰伦'), contains('周杰倫'));
    });
  });
}

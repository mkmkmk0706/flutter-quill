// 서식이 다른 두 구간의 경계에 커서를 두고 입력할 때의 서식.
//
// collectStyle(index, 0) 은 경계에서 **뒤쪽** 런의 서식을 돌려준다. 그대로 쓰면
// 평문 뒤에 굵은 글이 이어지는 문서에서 그 사이에 입력한 글자가 굵게 나온다.
// 편집기 통념대로 **앞 글자**를 물려받아야 한다.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TextSelection sel(int o) => TextSelection.collapsed(offset: o);
  dynamic boldAt(QuillController c, int i) =>
      c.document.collectStyle(i, 1).attributes['bold']?.value;

  /// "가나"(평문) + "다라"(굵게) 를 만든다.
  QuillController buildDoc() {
    final c = QuillController.basic();
    c.replaceText(0, 0, '가나', sel(2));
    c.formatText(2, 0, Attribute.bold);
    c.replaceText(2, 0, '다라', sel(4));
    return c;
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    group('$platform', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test('BD-T1: 평문|굵게 경계에 커서를 두고 입력하면 앞(평문)을 따른다', () {
        final c = buildDoc();
        expect(boldAt(c, 1), isNull, reason: '전제: 나 는 평문');
        expect(boldAt(c, 2), true, reason: '전제: 다 는 굵게');

        c.updateSelection(sel(2), ChangeSource.local); // 경계에 커서
        c.replaceText(2, 0, '사', sel(3));

        expect(c.document.toPlainText(), '가나사다라\n');
        expect(boldAt(c, 2), isNull, reason: '경계 입력이 뒤쪽(굵게)을 물려받았다');
        c.dispose();
      });

      test('BD-T2: 굵은 구간 안쪽에 커서를 두고 입력하면 굵게 유지', () {
        final c = buildDoc();
        c.updateSelection(sel(3), ChangeSource.local); // 다|라 사이
        c.replaceText(3, 0, '사', sel(4));
        expect(boldAt(c, 3), true, reason: '굵은 구간 안쪽은 굵게여야 한다');
        c.dispose();
      });

      test('BD-T3: 평문 구간 안쪽에 커서를 두고 입력하면 평문 유지', () {
        final c = buildDoc();
        c.updateSelection(sel(1), ChangeSource.local); // 가|나 사이
        c.replaceText(1, 0, '사', sel(2));
        expect(boldAt(c, 1), isNull);
        c.dispose();
      });
    });
  }
}

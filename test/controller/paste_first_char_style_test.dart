// 붙여넣기 시 첫 글자에 현재 toggledStyle 이 찍히는 문제.
//
// 붙여넣기는 replaceText(index, len, Delta) 로 들어오는데,
// retain 루프의 `number = data is String ? data.length : 1` 때문에
// Delta 붙여넣기가 "1글자"로 취급되어 첫 글자에만 현재 서식이 적용된다.

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TextSelection sel(int o) => TextSelection.collapsed(offset: o);
  dynamic boldAt(QuillController c, int i) =>
      c.document.collectStyle(i, 1).attributes['bold']?.value;

  test('PASTE-1: bold 켠 상태에서 평문을 붙여넣으면 첫 글자에 bold 가 안 붙어야 한다', () {
    final c = QuillController.basic();
    c.replaceText(0, 0, 'abc', sel(3));
    c.formatText(3, 0, Attribute.bold); // 툴바 Bold ON (아직 타이핑 안 함)

    // 외부에서 평문 "XYZ" 붙여넣기
    c.replaceText(3, 0, Delta()..insert('XYZ'), sel(6));
    debugPrint('[P] doc=${c.document.toDelta().toJson()}');

    expect(c.document.toPlainText(), 'abcXYZ\n');
    expect(boldAt(c, 3), isNull, reason: '붙여넣은 첫 글자 X 에 bold 가 찍혔다');
    expect(boldAt(c, 4), isNull);
    expect(boldAt(c, 5), isNull);
    c.dispose();
  });

  test('PASTE-2: 붙여넣는 Delta 자체의 서식은 그대로 유지되어야 한다', () {
    final c = QuillController.basic();
    c.replaceText(0, 0, 'abc', sel(3));
    c.replaceText(3, 0, Delta()..insert('XY', {'bold': true})..insert('Z'), sel(6));
    debugPrint('[P2] doc=${c.document.toDelta().toJson()}');
    expect(boldAt(c, 3), true);
    expect(boldAt(c, 4), true);
    expect(boldAt(c, 5), isNull);
    c.dispose();
  });
}

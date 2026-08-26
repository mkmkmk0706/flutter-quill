// 백스페이스로 서식 구간을 지나 평문 구간까지 지운 뒤 재입력할 때의 서식 검증.
//
// 실제 에디터에서 백스페이스는 IME 가 아니라 quill 기본 액션
// (QuillEditorDeleteTextAction) 이 처리한다. 그 액션은 삭제 "전" 문맥 서식을 계산해
// 삭제 "후" forceToggledStyle 로 알려준다. 아래 [backspace] 가 그 동작을 그대로 옮긴 것이다.

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TextSelection sel(int offset) => TextSelection.collapsed(offset: offset);

  dynamic boldAt(QuillController c, int index) =>
      c.document.collectStyle(index, 1).attributes[Attribute.bold.key]?.value;

  /// QuillEditorDeleteTextAction(backward) 재현
  void backspace(QuillController c) {
    final selection = c.selection;
    final start = selection.start + (selection.isCollapsed ? 0 : 1);

    var target = c.document.collectStyle(start, 0);
    if (start > 0) {
      final style = c.document.collectStyle(start - 1, 0);
      for (final key in style.attributes.keys) {
        if (Attribute.inlineKeys.contains(key)) {
          if (!target.containsKey(key)) {
            target = target.put(Attribute(key, AttributeScope.inline, null));
          }
        }
      }
    }

    c.replaceText(start - 1, 1, '', sel(start - 1));
    c.forceToggledStyle(target);
  }

  group('백스페이스 후 재입력 서식', () {
    late QuillController c;
    setUp(() => c = QuillController.basic());
    tearDown(() => c.dispose());

    // BS-T1. 오늘 보고된 증상
    //   "abc" 평문 → bold ON → "def" → 백스페이스 4번("cdef" 삭제) → 숫자 입력
    //   기대: 커서가 평문 구간이므로 숫자에 bold 가 붙지 않는다.
    test('BS-T1: bold 구간 지나 평문까지 백스페이스 → 재입력 시 bold 없음', () {
      c.replaceText(0, 0, 'abc', sel(3));

      // 툴바 bold ON + 앱의 afterButtonPressed(toggleInlineStyle)
      c.formatText(3, 0, Attribute.bold);
      c.toggleInlineStyle(3, c.getSelectionStyle());

      c.replaceText(3, 0, 'd', sel(4));
      c.replaceText(4, 0, 'e', sel(5));
      c.replaceText(5, 0, 'f', sel(6));

      expect(c.document.toPlainText(), 'abcdef\n');
      expect(boldAt(c, 3), true, reason: 'd 는 bold 여야 한다');
      expect(boldAt(c, 5), true, reason: 'f 는 bold 여야 한다');

      // "cdef" 삭제
      for (var i = 0; i < 4; i++) {
        backspace(c);
      }
      expect(c.document.toPlainText(), 'ab\n');

      // 숫자 3개 입력
      c.replaceText(2, 0, '1', sel(3));
      c.replaceText(3, 0, '2', sel(4));
      c.replaceText(4, 0, '3', sel(5));

      expect(c.document.toPlainText(), 'ab123\n');
      for (final i in [2, 3, 4]) {
        expect(boldAt(c, i), isNull,
            reason: 'index $i: 삭제된 글자의 bold 가 되살아났다');
      }
    });

    // BS-T2. 서식 구간 안에서만 지웠다 다시 쓰면 서식이 유지되어야 한다 (기존 동작 보호)
    test('BS-T2: bold 구간 안에서만 백스페이스 → 재입력 시 bold 유지', () {
      c.replaceText(0, 0, 'abc', sel(3));
      c.formatText(3, 0, Attribute.bold);
      c.toggleInlineStyle(3, c.getSelectionStyle());
      c.replaceText(3, 0, 'd', sel(4));
      c.replaceText(4, 0, 'e', sel(5));
      c.replaceText(5, 0, 'f', sel(6));

      // "ef" 만 삭제 (bold 구간 내부, d 는 남음)
      backspace(c);
      backspace(c);
      expect(c.document.toPlainText(), 'abcd\n');

      c.replaceText(4, 0, 'x', sel(5));
      expect(boldAt(c, 4), true, reason: 'bold 구간 뒤 재입력은 bold 를 유지해야 한다');
    });
  });
}

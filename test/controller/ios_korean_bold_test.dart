// iOS 한글 IME: "가" → Bold → "나" 입력 시 "나"에 bold 가 적용되는가.
//
// 시퀀스는 실기기 로그(iPhone, iOS 18.2)에서 그대로 옮겼다. iOS 한글 IME 는 글자를
// 이어 넣지 않고, 입력마다 **단어 전체를 선택(sel 0..1)해 지우고 통째로 다시 넣는다.**
// 그 선택 이벤트는 사용자가 캐럿을 옮긴 것이 아니라 IME 가 교체할 범위를 잡은 것이다.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TextSelection sel(int o) => TextSelection.collapsed(offset: o);
  TextSelection range(int b, int e) => TextSelection(baseOffset: b, extentOffset: e);
  dynamic boldAt(QuillController c, int i) =>
      c.document.collectStyle(i, 1).attributes['bold']?.value;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('IOS-KR: 가 → Bold → 나 (실기기 로그 시퀀스)', () {
    final c = QuillController.basic();

    // "가" 입력 (IME 가 한 번에 커밋)
    c.replaceText(0, 0, '가', sel(1));

    // 툴바 Bold + 앱의 afterButtonPressed
    c.formatText(1, 0, Attribute.bold);
    c.toggleInlineStyle(1, c.getSelectionStyle());

    // ── IME 사이클 1: "가" 를 선택 → 삭제 → "간" 삽입
    c.updateSelection(range(0, 1), ChangeSource.local);
    c.replaceText(0, 1, '', sel(0));
    c.replaceText(0, 0, '간', sel(1));
    debugPrint('[KR] 사이클1 후 doc=${c.document.toDelta().toJson()} '
        'toggled=${c.toggledStyle} pending=${c.pendingInlineStyle}');

    // ── IME 사이클 2: "간" 을 선택 → 삭제 → "가나" 삽입
    c.updateSelection(range(0, 1), ChangeSource.local);
    c.replaceText(0, 1, '', sel(0));
    c.replaceText(0, 0, '가나', sel(2));
    debugPrint('[KR] 사이클2 후 doc=${c.document.toDelta().toJson()} '
        'toggled=${c.toggledStyle} pending=${c.pendingInlineStyle}');

    expect(c.document.toPlainText(), '가나\n');
    expect(boldAt(c, 0), isNull, reason: '가 는 Bold 누르기 전 글자라 평문이어야 한다');
    expect(boldAt(c, 1), true, reason: '나 는 Bold 를 켠 뒤 입력했으므로 bold 여야 한다');
    c.dispose();
  });
}

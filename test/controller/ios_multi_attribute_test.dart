// iOS 한글 IME: 서식을 껐다가 다른 서식 여러 개를 켠 뒤 입력하면 켠 서식이 사라지는 문제.
//
// 시퀀스는 실기기 로그(iPhone iOS 18.2)에서 옮겼다.
//   "한"(bold) → Bold OFF → "글"(평문) → Italic+Underline ON → 다음 글자 입력
// iOS 는 입력마다 단어 전체를 선택(0..2)해 지우고 다시 넣는데, 그 삭제에서
// iosDeletedStyle 동기화가 pending 의 **null 값 속성만** 살리고
// 사용자가 방금 켠 italic/underline 을 버린다.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TextSelection sel(int o) => TextSelection.collapsed(offset: o);
  TextSelection range(int b, int e) => TextSelection(baseOffset: b, extentOffset: e);
  dynamic at(QuillController c, int i, String key) =>
      c.document.collectStyle(i, 1).attributes[key]?.value;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// 앱이 서식 버튼 후 실제로 하는 것
  void button(QuillController c, Attribute a) {
    c.formatText(c.selection.start, 0, a);
    c.toggleInlineStyle(c.selection.start, c.getSelectionStyle());
  }

  test('IOS-MULTI: Bold OFF 후 Italic+Underline 켜고 입력하면 둘 다 적용돼야 한다', () {
    final c = QuillController.basic();

    // "한"(bold)
    button(c, Attribute.bold);
    c.replaceText(0, 0, '한', sel(1));
    // Bold OFF → "글"(평문)
    button(c, Attribute.clone(Attribute.bold, null));
    c.replaceText(1, 0, '글', sel(2));

    expect(at(c, 0, 'bold'), true, reason: '전제: 한 은 bold');
    expect(at(c, 1, 'bold'), isNull, reason: '전제: 글 은 평문');

    // Italic + Underline ON
    button(c, Attribute.italic);
    button(c, Attribute.underline);
    debugPrint('[M] 버튼 후 toggled=${c.toggledStyle} pending=${c.pendingInlineStyle}');

    // iOS IME 사이클: "한글" 통째 선택 → 삭제 → 음절별 재삽입
    c.updateSelection(range(0, 2), ChangeSource.local);
    c.replaceText(0, 2, '', sel(0));
    debugPrint('[M] 삭제 후 toggled=${c.toggledStyle} pending=${c.pendingInlineStyle}');
    c.replaceText(0, 0, '한', sel(1));
    c.replaceText(1, 0, '글', sel(2));

    // 새 글자 입력
    c.replaceText(2, 0, '테', sel(3));
    debugPrint('[M] 최종 doc=${c.document.toDelta().toJson()}');

    expect(at(c, 2, 'italic'), true, reason: '켠 italic 이 사라졌다');
    expect(at(c, 2, 'underline'), true, reason: '켠 underline 이 사라졌다');
    expect(at(c, 2, 'bold'), isNull, reason: 'bold 는 꺼둔 상태여야 한다');
    c.dispose();
  });

  // 반대 방향 — 서식이 켜진 글자 뒤에서 하나만 끄면 그 하나만 빠져야 한다.
  // (실기기 로그: 지워진 글자가 bold 라 문맥이 사용자의 bold=null 을 덮어써 해제가 안 됐다)
  test('IOS-MULTI-OFF: bold+italic+underline 상태에서 bold 만 끄면 bold 만 빠져야 한다', () {
    final c = QuillController.basic();

    button(c, Attribute.bold);
    button(c, Attribute.italic);
    button(c, Attribute.underline);
    c.replaceText(0, 0, '가', sel(1));
    c.replaceText(1, 0, '나', sel(2));
    expect(at(c, 1, 'bold'), true, reason: '전제: 나 는 bold+italic+underline');

    // Bold 만 끈다
    button(c, Attribute.clone(Attribute.bold, null));
    debugPrint('[OFF] 버튼 후 toggled=${c.toggledStyle} pending=${c.pendingInlineStyle}');

    // iOS IME 사이클
    c.updateSelection(range(0, 2), ChangeSource.local);
    c.replaceText(0, 2, '', sel(0));
    debugPrint('[OFF] 삭제 후 toggled=${c.toggledStyle} pending=${c.pendingInlineStyle}');
    c.replaceText(0, 0, '가', sel(1));
    c.replaceText(1, 0, '나', sel(2));

    c.replaceText(2, 0, '다', sel(3));
    debugPrint('[OFF] 최종 doc=${c.document.toDelta().toJson()}');

    expect(at(c, 2, 'bold'), isNull, reason: 'bold 를 껐는데 계속 굵게 나온다');
    expect(at(c, 2, 'italic'), true, reason: 'italic 은 유지돼야 한다');
    expect(at(c, 2, 'underline'), true, reason: 'underline 은 유지돼야 한다');
    c.dispose();
  });
}

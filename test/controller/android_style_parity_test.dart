// Android 플랫폼에서 이번 iOS 수정(범위 선택 제외)이 기존 동작을 바꾸지 않는지 확인.
//
// 가드는 "접힌 선택으로 캐럿이 옮겨갈 때"만 발동한다. 범위 선택을 제외한 것은
// 발동 조건을 좁힌 것이라, Android 에서 새로 깨질 수 있는 방향이 아니다.
// (좁히기 전 버전은 실기기 AOS 에서 정상 확인됨)

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
  bool toolbar(QuillController c) =>
      c.getSelectionStyle().attributes.containsKey('bold');

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// QuillEditorDeleteTextAction(backward) 재현
  void backspace(QuillController c) {
    final start = c.selection.start + (c.selection.isCollapsed ? 0 : 1);
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

  // AOS-1: 어제 고친 백스페이스 케이스 (실기기 AOS 확인 완료분)
  test('AOS-1: bold 구간 지나 평문까지 백스페이스 → 재입력 시 평문', () {
    final c = QuillController.basic();
    c.replaceText(0, 0, 'abc', sel(3));
    c.formatText(3, 0, Attribute.bold);
    c.toggleInlineStyle(3, c.getSelectionStyle());
    c.replaceText(3, 0, 'd', sel(4));
    c.replaceText(4, 0, 'e', sel(5));
    c.replaceText(5, 0, 'f', sel(6));
    for (var i = 0; i < 4; i++) {
      backspace(c);
    }
    c.replaceText(2, 0, '1', sel(3));
    c.replaceText(3, 0, '2', sel(4));
    c.replaceText(4, 0, '3', sel(5));
    expect(c.document.toPlainText(), 'ab123\n');
    for (final i in [2, 3, 4]) {
      expect(boldAt(c, i), isNull, reason: 'index $i 에 서식이 되살아남');
    }
    c.dispose();
  });

  // AOS-2: 오늘 고친 툴바 케이스 (실기기 AOS 확인 완료분) — 탭 이동은 collapsed 라 그대로 동작
  test('AOS-2: 서식 끄기 이력 후 서식 글자에 커서를 두면 툴바가 켜진다', () {
    final c = QuillController.basic();
    c.replaceText(0, 0, 'abc', sel(3));
    c.formatText(3, 0, Attribute.bold);
    c.replaceText(3, 0, 'def', sel(6));
    c.formatText(6, 0, Attribute.clone(Attribute.bold, null));
    c.replaceText(6, 0, 'ghi', sel(9));

    c.updateSelection(sel(5), ChangeSource.local);
    expect(toolbar(c), isTrue, reason: 'bold 구간에 커서 → 툴바 ON');
    c.updateSelection(sel(8), ChangeSource.local);
    expect(toolbar(c), isFalse, reason: '평문 구간에 커서 → 툴바 OFF');
    c.dispose();
  });

  // AOS-3: Android 조합 교체(범위 선택 없이 replace) 에서 서식 유지
  test('AOS-3: Android IME 조합 교체 중 서식 유지', () {
    final c = QuillController.basic();
    c.replaceText(0, 0, '가', sel(1));
    c.formatText(1, 0, Attribute.bold);
    c.toggleInlineStyle(1, c.getSelectionStyle());
    c.replaceText(1, 0, 'ㄴ', sel(2));   // 조합 시작
    c.replaceText(1, 1, '나', sel(2));   // ㄴ → 나 (isImeCompose)
    expect(boldAt(c, 0), isNull, reason: '가 는 평문');
    expect(boldAt(c, 1), true, reason: '나 는 bold');
    c.dispose();
  });

  // AOS-4: 범위 선택은 가드 대상이 아니다 — iOS 수정으로 좁힌 부분의 AOS 영향 확인.
  // 범위 선택(드래그, IME 의 교체 범위 잡기)은 서식 의도를 지우지 않고,
  // 사용자가 캐럿을 놓는 접힌 선택에서만 정리된다.
  test('AOS-4: 범위 선택은 서식 의도를 지우지 않고, 캐럿을 놓을 때만 정리된다', () {
    final c = QuillController.basic();
    c.replaceText(0, 0, 'abc', sel(3));
    c.formatText(3, 0, Attribute.bold);
    expect(c.pendingInlineStyle, isNotNull, reason: '전제: 서식 버튼으로 의도가 세워진다');

    c.updateSelection(range(0, 2), ChangeSource.local); // 드래그 선택
    expect(c.pendingInlineStyle, isNotNull,
        reason: '범위 선택은 캐럿 이동이 아니므로 의도를 지우면 안 된다');

    c.updateSelection(sel(1), ChangeSource.local); // 사용자가 캐럿을 놓음
    expect(c.pendingInlineStyle, isNull,
        reason: '접힌 선택으로 캐럿을 옮기면 의도가 정리되어야 한다');
    c.dispose();
  });

  // AOS-5/6: iOS 전용 분기(iosDeletedStyle 동기화)를 고친 것이 Android 에 영향이 없는지.
  // 그 블록은 defaultTargetPlatform == iOS 일 때만 iosDeletedStyle 이 세팅되어
  // `if (iosDeletedStyle != null)` 안으로 들어가므로 Android 는 구조적으로 진입하지 않는다.
  // iOS 테스트(ios_multi_attribute_test.dart)와 같은 시나리오를 Android 로 고정해 확인한다.
  test('AOS-5: Bold OFF 후 Italic+Underline 켜고 입력 → 둘 다 적용', () {
    final c = QuillController.basic();
    void button(Attribute a) {
      c.formatText(c.selection.start, 0, a);
      c.toggleInlineStyle(c.selection.start, c.getSelectionStyle());
    }

    button(Attribute.bold);
    c.replaceText(0, 0, '한', sel(1));
    button(Attribute.clone(Attribute.bold, null));
    c.replaceText(1, 0, '글', sel(2));

    button(Attribute.italic);
    button(Attribute.underline);
    c.replaceText(2, 0, '테', sel(3));

    expect(c.document.collectStyle(2, 1).attributes['italic']?.value, true);
    expect(c.document.collectStyle(2, 1).attributes['underline']?.value, true);
    expect(c.document.collectStyle(2, 1).attributes['bold']?.value, isNull);
    c.dispose();
  });

  test('AOS-6: bold+italic+underline 에서 bold 만 끄면 bold 만 빠진다', () {
    final c = QuillController.basic();
    void button(Attribute a) {
      c.formatText(c.selection.start, 0, a);
      c.toggleInlineStyle(c.selection.start, c.getSelectionStyle());
    }

    button(Attribute.bold);
    button(Attribute.italic);
    button(Attribute.underline);
    c.replaceText(0, 0, '가', sel(1));
    c.replaceText(1, 0, '나', sel(2));

    button(Attribute.clone(Attribute.bold, null));
    c.replaceText(2, 0, '다', sel(3));

    expect(c.document.collectStyle(2, 1).attributes['bold']?.value, isNull,
        reason: 'bold 를 껐는데 계속 굵게 나온다');
    expect(c.document.collectStyle(2, 1).attributes['italic']?.value, true);
    expect(c.document.collectStyle(2, 1).attributes['underline']?.value, true);
    c.dispose();
  });
}

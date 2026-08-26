// 캐럿을 옮겼을 때 toggledStyle / _pendingInlineStyle 이 어떻게 되어야 하는지 검증.
//
// 툴바 버튼은 controller.getSelectionStyle() 을 보고 켜짐/꺼짐을 정한다. 이 값은
// 문서 서식에 toggledStyle 을 mergeAll 한 것인데, mergeAll 은 값이 null 인 속성
// ("서식 끄기" 의도)을 만나면 그 키를 지운다. 따라서 끄기 의도가 toggledStyle 에
// 남아 있으면 문서에 실제로 있는 서식까지 결과에서 사라져, 서식 글자에 커서를 둬도
// 툴바가 꺼진 채로 표시된다.

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TextSelection sel(int o) => TextSelection.collapsed(offset: o);

  bool toolbarShows(QuillController c, Attribute attr) =>
      c.getSelectionStyle().attributes.containsKey(attr.key);

  /// "abc" + bold "def" + 평문 "ghi" 를 만든다. (중간에 bold OFF 를 거친다)
  QuillController buildDoc() {
    final c = QuillController.basic();
    c.replaceText(0, 0, 'abc', sel(3));
    c.formatText(3, 0, Attribute.bold);
    c.replaceText(3, 0, 'def', sel(6));
    c.formatText(6, 0, Attribute.clone(Attribute.bold, null));
    c.replaceText(6, 0, 'ghi', sel(9));
    return c;
  }

  group('캐럿 이동과 서식 상태', () {
    // CM-T1. 보고된 증상
    test('CM-T1: 서식 끄기 이력이 있어도 서식 글자에 커서를 두면 툴바가 켜진다', () {
      final c = buildDoc();
      expect(c.document.collectStyle(5, 0).attributes.containsKey('bold'), isTrue,
          reason: '전제: 문서상 offset 5 는 bold 구간');

      c.updateSelection(sel(5), ChangeSource.local);

      expect(toolbarShows(c, Attribute.bold), isTrue,
          reason: '끄기 의도(bold:null)가 남아 문서의 bold 까지 지워졌다');
      c.dispose();
    });

    // CM-T2. 반대 방향 — 평문으로 옮기면 꺼져야 한다
    test('CM-T2: 평문 구간으로 커서를 옮기면 툴바가 꺼진다', () {
      final c = buildDoc();
      c.updateSelection(sel(8), ChangeSource.local);
      expect(toolbarShows(c, Attribute.bold), isFalse);
      c.dispose();
    });

    // CM-T3. Android 재포커스 보호 — 같은 자리로 오는 selection 이벤트는 의도를 지우면 안 된다
    test('CM-T3: 같은 위치 selection 이벤트가 반복돼도 서식 버튼 의도가 유지된다', () {
      final c = QuillController.basic();
      c.replaceText(0, 0, 'abc', sel(3));
      c.formatText(3, 0, Attribute.bold); // 서식 버튼

      // 재포커스로 같은 위치 selection 이벤트가 여러 번 들어온다
      c.updateSelection(sel(3), ChangeSource.local);
      c.updateSelection(sel(3), ChangeSource.local);
      c.updateSelection(sel(3), ChangeSource.local);

      c.replaceText(3, 0, 'd', sel(4));
      expect(c.document.collectStyle(3, 1).attributes['bold']?.value, true,
          reason: '재포커스 이벤트가 서식 버튼 의도를 지웠다');
      c.dispose();
    });

    // CM-T4. 서식 버튼 직후 1회 이동은 의도를 유지한다 (버튼 → 재포커스 보호).
    // 그 보호는 한 번만 쓰이므로, 이어지는 이동부터는 의도가 정리된다.
    test('CM-T4: 서식 ON 직후 1회 이동은 의도 유지, 다음 이동부터는 정리된다', () {
      final c = QuillController.basic();
      c.replaceText(0, 0, 'abcdef', sel(6));
      c.formatText(6, 0, Attribute.bold); // 문서 끝에서 bold ON

      c.updateSelection(sel(2), ChangeSource.local); // 1회차 — 보호됨
      expect(toolbarShows(c, Attribute.bold), isTrue,
          reason: '서식 버튼 직후 첫 selection 이벤트는 의도를 지우면 안 된다');

      c.updateSelection(sel(1), ChangeSource.local); // 2회차 — 정리
      expect(toolbarShows(c, Attribute.bold), isFalse,
          reason: '보호는 1회용이므로 이후 이동에서는 의도가 남으면 안 된다');
      c.dispose();
    });

    // CM-T5. 값형 속성(배경색)도 같은 규칙
    test('CM-T5: 배경색도 커서 이동에 따라 툴바 상태가 갱신된다', () {
      final c = QuillController.basic();
      c.replaceText(0, 0, 'abc', sel(3));
      c.formatText(3, 0, BackgroundAttribute('#ffff00')); // 배경색 ON
      c.replaceText(3, 0, 'def', sel(6));
      c.formatText(6, 0, Attribute.clone(Attribute.background, null)); // OFF
      c.replaceText(6, 0, 'ghi', sel(9));

      c.updateSelection(sel(5), ChangeSource.local);
      expect(toolbarShows(c, Attribute.background), isTrue);

      c.updateSelection(sel(8), ChangeSource.local);
      expect(toolbarShows(c, Attribute.background), isFalse);
      c.dispose();
    });
  });
}

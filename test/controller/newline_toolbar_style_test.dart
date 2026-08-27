// 엔터 직후 / 캐럿 이동 시 툴바의 서식 ON/OFF 표시 검증.
//
// [증상] 서식 ON → "abc" 입력 → 서식 OFF → 엔터 를 하면, 실제 입력은 OFF 로 나가는데
//        하단 툴바만 이전 서식이 켜진 채로 표시됐다. (AOS/iOS 공통)
//
// [원인] 포크 QuillController._updateSelection 의 insertNewline 분기가
//        toggledStyle = 이전줄서식.mergeAll(끄기의도) 를 하는데, mergeAll 은 null-값
//        attr(= 끄기 의도)을 map 에서 제거한다. 그래서 toggledStyle 이 빈 Style 이 되고
//        getSelectionStyle() = 문서서식.mergeAll(toggledStyle) 이 이전 줄의 서식을
//        그대로 노출했다. 툴바 버튼(QuillToolbarToggleStyleButton)은 이 값의 키 존재
//        여부로 ON/OFF 를 그리므로 표시만 어긋났다.
//
// 이 테스트는 툴바 버튼과 동일한 판정(getSelectionStyle().attributes.containsKey)으로
// 표시 상태를 검증하고, 실제 입력 결과도 함께 확인해 표시/결과가 일치하는지 본다.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TextSelection sel(int offset) => TextSelection.collapsed(offset: offset);

  /// 툴바 버튼이 켜져 보이는지. (QuillToolbarToggleStyleButton._getIsToggled 와 동일)
  bool toolbarOn(QuillController c, Attribute attr) =>
      c.getSelectionStyle().attributes.containsKey(attr.key);

  /// 캐럿 위치에 입력.
  void type(QuillController c, String text) {
    final i = c.selection.baseOffset;
    c.replaceText(i, 0, text, sel(i + text.length));
  }

  dynamic valueAt(QuillController c, int index, Attribute attr) =>
      c.document.collectStyle(index, 1).attributes[attr.key]?.value;

  QuillController newController() {
    final c = QuillController.basic();
    addTearDown(c.dispose);
    return c;
  }

  group('엔터 직후 툴바 서식 표시', () {
    for (final attr in [Attribute.bold, Attribute.italic, Attribute.underline]) {
      test('${attr.key}: ON → abc → OFF → 엔터 후에도 툴바가 꺼져 있다', () {
        final c = newController()..formatSelection(attr);
        expect(toolbarOn(c, attr), isTrue);

        type(c, 'abc');
        expect(toolbarOn(c, attr), isTrue);

        c.formatSelection(Attribute.clone(attr, null));
        expect(toolbarOn(c, attr), isFalse, reason: '껐으니 꺼져 보여야 한다');

        type(c, '\n');
        expect(toolbarOn(c, attr), isFalse, reason: '엔터는 서식 의도를 바꾸지 않는다');

        // 표시와 실제 입력 결과가 일치해야 한다.
        type(c, 'd');
        expect(toolbarOn(c, attr), isFalse);
        expect(valueAt(c, c.selection.baseOffset - 1, attr), isNull);
        expect(valueAt(c, 0, attr), isTrue, reason: '이전 줄 서식은 그대로');
      });
    }

    test('ON 을 유지한 채 엔터를 치면 툴바도 계속 켜져 있다', () {
      final c = newController()..formatSelection(Attribute.bold);
      type(c, 'abc');
      type(c, '\n');
      expect(toolbarOn(c, Attribute.bold), isTrue);

      type(c, 'd');
      expect(valueAt(c, c.selection.baseOffset - 1, Attribute.bold), isTrue);
    });

    test('여러 서식 중 하나만 끄면 끈 것만 꺼져 보인다', () {
      final c = newController()
        ..formatSelection(Attribute.bold)
        ..formatSelection(Attribute.italic);
      type(c, 'abc');

      c.formatSelection(Attribute.clone(Attribute.italic, null));
      type(c, '\n');

      expect(toolbarOn(c, Attribute.bold), isTrue);
      expect(toolbarOn(c, Attribute.italic), isFalse);

      type(c, 'd');
      final at = c.selection.baseOffset - 1;
      expect(valueAt(c, at, Attribute.bold), isTrue);
      expect(valueAt(c, at, Attribute.italic), isNull);
    });

    test('엔터 후 이전 줄 서식 글자로 캐럿을 옮기면 툴바가 다시 켜진다', () {
      final c = newController()..formatSelection(Attribute.bold);
      type(c, 'abc');
      c.formatSelection(Attribute.clone(Attribute.bold, null));
      type(c, '\n');
      expect(toolbarOn(c, Attribute.bold), isFalse);

      c.updateSelection(sel(2), ChangeSource.local);
      expect(
        toolbarOn(c, Attribute.bold),
        isTrue,
        reason: '끄기 의도가 남아 문서에 실제로 있는 서식까지 가리면 안 된다',
      );
    });
  });

  // 캐럿을 옮겼을 때의 툴바 표시. iOS 는 Android 와 처리 지점이 달라(폭주 회피 때문에
  // updateSelection(public) 에서 상태를 못 건드린다) 양쪽을 모두 재생해 결과가 같은지 본다.
  group('캐럿 이동 시 툴바 서식 표시 (플랫폼 동등성)', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test('$platform: 서식 OFF+엔터 뒤 캐럿을 옮겨도 문서 서식이 그대로 표시된다', () {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        // "abc"(bold) + 개행 + "def"(평문)
        final c = newController()..formatSelection(Attribute.bold);
        type(c, 'abc');
        c.formatSelection(Attribute.clone(Attribute.bold, null));
        type(c, '\n');
        type(c, 'def');
        expect(toolbarOn(c, Attribute.bold), isFalse);

        // bold 구간으로 이동 → 켜져 보여야 한다.
        c.updateSelection(sel(1), ChangeSource.local);
        expect(toolbarOn(c, Attribute.bold), isTrue);

        // 평문으로 이동 → 꺼져 보여야 한다.
        c.updateSelection(sel(6), ChangeSource.local);
        expect(toolbarOn(c, Attribute.bold), isFalse);

        // 다시 bold 구간으로 → 켜져 보여야 한다.
        // (끄기 의도 잔재가 toggledStyle 에 실려 문서 서식까지 지우던 자리)
        c.updateSelection(sel(2), ChangeSource.local);
        expect(
          toolbarOn(c, Attribute.bold),
          isTrue,
          reason: '캐럿이 서식 글자에 있으면 문서 서식이 보여야 한다',
        );

        // iOS 는 같은 자리로 selection 이벤트가 여러 번 온다. 반복해도 흔들리면 안 된다.
        for (var i = 0; i < 3; i++) {
          c.updateSelection(sel(2), ChangeSource.local);
          expect(toolbarOn(c, Attribute.bold), isTrue, reason: '중복 이벤트 ${i + 1}회차');
        }
      });

      test('$platform: 캐럿을 옮긴 평문 자리에 입력하면 끄기 의도가 유지된다', () {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final c = newController()..formatSelection(Attribute.bold);
        type(c, 'abc');
        c.formatSelection(Attribute.clone(Attribute.bold, null));
        type(c, '\n');
        type(c, 'def');

        // bold 구간을 거쳐 평문 끝으로 이동한 뒤 입력.
        c.updateSelection(sel(1), ChangeSource.local);
        c.updateSelection(sel(7), ChangeSource.local);
        type(c, 'X');

        expect(
          valueAt(c, c.selection.baseOffset - 1, Attribute.bold),
          isNull,
          reason: '평문 자리 입력에 앞 글자 서식이 따라붙으면 안 된다',
        );
      });
    }
  });
}

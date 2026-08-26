// 플랫폼 동등성: 같은 사용자 조작이면 iOS 와 Android 의 **최종 문서가 같아야 한다.**
//
// 두 플랫폼은 IME 이벤트 순서가 다르다.
//   Android : 조합 중인 글자 하나만 교체한다 (composing replace)
//   iOS     : 입력마다 단어 전체를 선택해 지우고 통째로 다시 넣는다 (실기기 로그 기준)
// 그래서 같은 replaceText 를 재생할 수는 없고, **각 플랫폼의 이벤트 순서를 재생**한 뒤
// 결과 문서를 비교한다. 기준은 Android 다.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

TextSelection _sel(int o) => TextSelection.collapsed(offset: o);
TextSelection _range(int b, int e) => TextSelection(baseOffset: b, extentOffset: e);

/// 한글 한 음절을 "자음 → 완성" 2단계로 치는 것을 각 플랫폼 방식으로 재생한다.
abstract class ImeDriver {
  TargetPlatform get platform;
  String get name;

  /// [partial] 를 먼저 넣었다가 [full] 로 완성한다. (예: ㄱ → 가)
  void typeSyllable(QuillController c, String partial, String full);
}

class AndroidDriver extends ImeDriver {
  @override
  TargetPlatform get platform => TargetPlatform.android;
  @override
  String get name => 'Android';

  @override
  void typeSyllable(QuillController c, String partial, String full) {
    final i = c.selection.baseOffset;
    c.replaceText(i, 0, partial, _sel(i + 1)); // 조합 시작
    c.replaceText(i, 1, full, _sel(i + 1)); // 조합 완성 (isImeCompose)
  }
}

class IosDriver extends ImeDriver {
  @override
  TargetPlatform get platform => TargetPlatform.iOS;
  @override
  String get name => 'iOS';

  @override
  void typeSyllable(QuillController c, String partial, String full) {
    final i = c.selection.baseOffset;
    c.replaceText(i, 0, partial, _sel(i + 1)); // 조합 시작
    // iOS 는 방금 넣은 글자를 선택 → 삭제 → 완성 글자로 재삽입한다
    c.updateSelection(_range(i, i + 1), ChangeSource.local);
    c.replaceText(i, 1, '', _sel(i));
    c.replaceText(i, 0, full, _sel(i + 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void button(QuillController c, Attribute a) {
    c.formatText(c.selection.start, 0, a);
    c.toggleInlineStyle(c.selection.start, c.getSelectionStyle());
  }

  /// 시나리오를 드라이버로 재생하고 문서 Delta(JSON)를 돌려준다.
  Object run(ImeDriver d, void Function(QuillController c, ImeDriver d) body) {
    debugDefaultTargetPlatformOverride = d.platform;
    final c = QuillController.basic();
    try {
      body(c, d);
      return c.document.toDelta().toJson();
    } finally {
      c.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  }

  void parity(String title, void Function(QuillController, ImeDriver) body) {
    test(title, () {
      final and = run(AndroidDriver(), body);
      final ios = run(IosDriver(), body);
      debugPrint('[PARITY] $title\n  AOS: $and\n  iOS: $ios');
      expect(ios, equals(and), reason: 'iOS 결과가 Android 와 다르다');
    });
  }

  group('플랫폼 동등성 (기준: Android)', () {
    parity('P1: 평문 → Bold ON → 입력', (c, d) {
      d.typeSyllable(c, 'ㄱ', '가');
      d.typeSyllable(c, 'ㄴ', '나');
      button(c, Attribute.bold);
      d.typeSyllable(c, 'ㄷ', '다');
      d.typeSyllable(c, 'ㄹ', '라');
    });

    parity('P2: Bold 구간에서 Bold OFF 후 입력', (c, d) {
      button(c, Attribute.bold);
      d.typeSyllable(c, 'ㄱ', '가');
      d.typeSyllable(c, 'ㄴ', '나');
      button(c, Attribute.clone(Attribute.bold, null));
      d.typeSyllable(c, 'ㄷ', '다');
    });

    parity('P3: Bold OFF 후 Italic+Underline ON 하고 입력', (c, d) {
      button(c, Attribute.bold);
      d.typeSyllable(c, 'ㄱ', '가');
      button(c, Attribute.clone(Attribute.bold, null));
      button(c, Attribute.italic);
      button(c, Attribute.underline);
      d.typeSyllable(c, 'ㄴ', '나');
      d.typeSyllable(c, 'ㄷ', '다');
    });

    parity('P4: 서식 3개 켠 뒤 하나만 끄고 입력', (c, d) {
      button(c, Attribute.bold);
      button(c, Attribute.italic);
      button(c, Attribute.underline);
      d.typeSyllable(c, 'ㄱ', '가');
      button(c, Attribute.clone(Attribute.bold, null));
      d.typeSyllable(c, 'ㄴ', '나');
      d.typeSyllable(c, 'ㄷ', '다');
    });

    parity('P5: 평문|굵게 경계에 커서를 두고 입력', (c, d) {
      d.typeSyllable(c, 'ㄱ', '가');
      d.typeSyllable(c, 'ㄴ', '나');
      button(c, Attribute.bold);
      d.typeSyllable(c, 'ㄷ', '다');
      d.typeSyllable(c, 'ㄹ', '라');
      c.updateSelection(_sel(2), ChangeSource.local); // 나|다 경계
      d.typeSyllable(c, 'ㅅ', '사');
    });
  });
}

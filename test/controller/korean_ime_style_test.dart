// 한국어 IME 서식 보존 테스트
//
// 안드로이드 폰 없이 QuillController.replaceText() 시퀀스를 직접 시뮬레이션하여
// 한국어 IME가 보내는 DELETE/INSERT 이벤트를 재현한다.
//
// 테스트 시나리오 목록:
// T1. 이전 글자(bold) 뒤에 bold OFF → 이전 글자의 bold 유지
// T2. bold 없는 이전 글자 위치를 IME가 재삽입 → 이전 글자에 bold 미적용 (cache 분기)
// T3. 배경색 OFF 후 새 글자에 배경색 없음
// T4. 이전 글자의 배경색은 IME 재삽입 시 보존
// T5. 전체 삭제 후 IME 재삽입(같은 프레임) → 서식 보존
// T6. 전체 삭제 후 직접 삭제(다음 프레임) → 서식 초기화
// T7. AssertionError 없음 (빈 스타일 + 빈 activeStyle)
// T8. 엔터 후 새 글자에 배경색 없음

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ────────────────────────────────────────────────
  // 헬퍼
  // ────────────────────────────────────────────────

  /// position offset의 collapsed selection 반환
  TextSelection sel(int offset) => TextSelection.collapsed(offset: offset);

  /// index 위치의 인라인 스타일 반환 (단일 글자)
  Style styleAt(QuillController c, int index) =>
      c.document.collectStyle(index, 1);

  /// index 위치의 특정 attribute 값 반환
  dynamic attrValueAt(QuillController c, int index, Attribute attr) =>
      styleAt(c, index).attributes[attr.key]?.value;

  /// activeStyle.isNotEmpty 기준으로 retain이 적용되는 replaceText 래퍼
  void ime(QuillController c, int index, int len, String data) {
    c.replaceText(index, len, data, sel(index + data.length));
  }

  // ────────────────────────────────────────────────
  // 테스트 그룹
  // ────────────────────────────────────────────────

  group('한국어 IME 서식 보존', () {
    late QuillController c;

    setUp(() {
      c = QuillController.basic();
    });

    tearDown(() {
      c.dispose();
    });

    // --------------------------------------------------
    // T1. 이전 글자(bold) 뒤에 bold OFF → 이전 글자 bold 유지
    //
    // 재현 시나리오:
    //   "가"(bold) 입력 → bold OFF → "나" 입력 시
    //   IME: DELETE "가ㄴ" → INSERT "가" → INSERT "나"
    //   기대: "가"는 bold 유지, "나"는 bold 없음
    // --------------------------------------------------
    test('T1: 이전 글자(bold) 뒤에 bold OFF 후 한국어 입력 → 이전 글자 bold 유지', () {
      // "가"(bold) 삽입
      c.formatText(0, 0, Attribute.bold);
      ime(c, 0, 0, '가');
      expect(attrValueAt(c, 0, Attribute.bold), isTrue,
          reason: '초기 "가"는 bold여야 함');

      // bold OFF
      c.updateSelection(sel(1), ChangeSource.local);
      c.formatText(1, 0, Attribute.clone(Attribute.bold, null));

      // "ㄴ" INSERT (새 글자, cachedChar=null)
      ime(c, 1, 0, 'ㄴ');

      // IME: "가ㄴ" DELETE → "가" INSERT → "나" INSERT
      ime(c, 0, 2, '');
      ime(c, 0, 0, '가');
      ime(c, 1, 0, '나');

      expect(attrValueAt(c, 0, Attribute.bold), isTrue,
          reason: '"가"는 bold를 유지해야 함');
      expect(attrValueAt(c, 1, Attribute.bold), isNot(isTrue),
          reason: '"나"는 bold가 없어야 함');
    });

    // --------------------------------------------------
    // T2. bold 없는 글자 위치를 IME가 재삽입 → 이전 글자에 bold 미적용
    //
    // 재현 시나리오:
    //   "가나"(no bold) 있음 → bold ON → "ㄷ" 입력
    //   IME: DELETE "가나" → INSERT "가" → INSERT "낟"
    //   기대: "가"는 bold 없음, "낟"은 cachedChar(no bold) 복원이므로 bold 없음
    // --------------------------------------------------
    test('T2: bold 없는 이전 글자를 IME가 재삽입할 때 bold 미적용 (캐시 분기)', () {
      // "가나" 삽입 (bold 없음)
      ime(c, 0, 0, '가');
      ime(c, 1, 0, '나');

      // bold ON
      c.updateSelection(sel(2), ChangeSource.local);
      c.formatText(2, 0, Attribute.bold);

      // "ㄷ" INSERT (새 위치, cachedChar=null → bold 적용됨)
      ime(c, 2, 0, 'ㄷ');

      // IME: "가나ㄷ" DELETE (또는 일부 DELETE) → "가" INSERT → "낟" INSERT
      // 실제 IME에 따라 두 번에 걸쳐 DELETE될 수 있으나 최종 결과만 검증
      ime(c, 0, 3, ''); // "가나ㄷ" DELETE
      ime(c, 0, 0, '가'); // "가" 재삽입
      ime(c, 1, 0, '낟'); // "낟" 삽입 (나의 캐시 위치 재사용)

      expect(attrValueAt(c, 0, Attribute.bold), isNot(isTrue),
          reason: '"가"는 bold 없는 원래 스타일로 복원되어야 함');
    });

    // --------------------------------------------------
    // T3. 배경색 OFF 후 새 글자에 배경색 없음
    //
    // 재현 시나리오:
    //   "가"(background:yellow) 있음 → background OFF → "나" 입력
    //   IME: INSERT "ㄴ" → DELETE "가ㄴ" → INSERT "가" → INSERT "나"
    //   기대: "나"에 배경색 없음
    // --------------------------------------------------
    test('T3: 배경색 OFF 후 새 글자에 배경색 없음', () {
      const bgColor = '#FFF4D03F';

      // "가"(background:yellow) 삽입
      c.formatText(0, 0, BackgroundAttribute(bgColor));
      ime(c, 0, 0, '가');
      expect(attrValueAt(c, 0, Attribute.background), equals(bgColor),
          reason: '초기 "가"는 background여야 함');

      // background OFF
      c.updateSelection(sel(1), ChangeSource.local);
      c.formatText(1, 0, BackgroundAttribute(null));

      // "ㄴ" INSERT (새 위치, cachedChar=null → background:null 적용)
      ime(c, 1, 0, 'ㄴ');

      // IME: "가ㄴ" DELETE → "가" INSERT → "나" INSERT
      ime(c, 0, 2, '');
      ime(c, 0, 0, '가');
      ime(c, 1, 0, '나');

      expect(attrValueAt(c, 1, Attribute.background), isNull,
          reason: '"나"에 배경색이 없어야 함');
    });

    // --------------------------------------------------
    // T4. 이전 글자의 배경색은 IME 재삽입 시 보존
    //
    // 재현 시나리오:
    //   "가"(background:yellow) 있음 → background OFF → "나" 입력
    //   "가"의 배경색은 유지되어야 함
    // --------------------------------------------------
    test('T4: IME 재삽입 시 이전 글자의 배경색 보존', () {
      const bgColor = '#FFF4D03F';

      // "가"(background:yellow) 삽입
      c.formatText(0, 0, BackgroundAttribute(bgColor));
      ime(c, 0, 0, '가');

      // background OFF
      c.updateSelection(sel(1), ChangeSource.local);
      c.formatText(1, 0, BackgroundAttribute(null));

      // "ㄴ" INSERT
      ime(c, 1, 0, 'ㄴ');

      // IME: "가ㄴ" DELETE → "가" INSERT → "나" INSERT
      ime(c, 0, 2, '');
      ime(c, 0, 0, '가');
      ime(c, 1, 0, '나');

      expect(attrValueAt(c, 0, Attribute.background), equals(bgColor),
          reason: '"가"의 배경색은 유지되어야 함');
    });

    // --------------------------------------------------
    // T5. 전체 삭제 후 IME 재삽입(같은 프레임) → 서식 보존
    //
    // 재현 시나리오:
    //   "가"(bold) 있음 → DELETE "가" → IME INSERT "가" (같은 프레임)
    //   기대: "가"의 bold 보존, toggledStyle 초기화 안 됨
    // --------------------------------------------------
    test('T5: 전체 삭제 후 같은 프레임에 IME 재삽입 → 서식 보존', () {
      // "가"(bold) 삽입
      c.formatText(0, 0, Attribute.bold);
      ime(c, 0, 0, '가');
      expect(attrValueAt(c, 0, Attribute.bold), isTrue);

      // 전체 삭제 → document.length = 1
      ime(c, 0, 1, '');
      // 같은 프레임 내 IME INSERT → _pendingStyleReset 취소
      ime(c, 0, 0, '가');

      expect(attrValueAt(c, 0, Attribute.bold), isTrue,
          reason: '전체 삭제 후 같은 프레임 IME INSERT는 서식을 보존해야 함');
    });

    // --------------------------------------------------
    // T6. 전체 삭제 후 직접 삭제(다음 프레임) → 서식 초기화
    //
    // 재현 시나리오:
    //   "가"(bold) 있음 → DELETE "가" → 다음 프레임 (IME INSERT 없음)
    //   기대: toggledStyle 초기화
    // --------------------------------------------------
    testWidgets('T6: 전체 삭제 후 다음 프레임까지 INSERT 없으면 서식 초기화',
        (tester) async {
      c.formatText(0, 0, Attribute.bold);
      ime(c, 0, 0, '가');
      expect(c.toggledStyle.attributes[Attribute.bold.key]?.value, isTrue);

      // 전체 삭제 → _pendingStyleReset = true 예약
      ime(c, 0, 1, '');

      // 프레임 펌핑 → addPostFrameCallback 실행
      await tester.pump();

      // toggledStyle 초기화 확인 (bold:null 또는 비어있음)
      final boldAttr = c.toggledStyle.attributes[Attribute.bold.key];
      expect(boldAttr?.value, isNot(isTrue),
          reason: '전체 삭제 후 다음 프레임에 서식이 초기화되어야 함');
    });

    // --------------------------------------------------
    // T7. AssertionError 없음: 빈 activeStyle + 빈 indexStyle
    //
    // 재현 시나리오:
    //   아무 서식 없이 한국어 IME 입력 → retainDelta가 no-op 될 수 있음
    //   기대: document.compose에서 assertion 미발생
    // --------------------------------------------------
    test('T7: 빈 스타일 + 빈 activeStyle → AssertionError 없음', () {
      // 아무 서식 없이 "가" INSERT
      expect(() => ime(c, 0, 0, '가'), returnsNormally,
          reason: '빈 스타일에서 INSERT 시 크래시가 없어야 함');

      // 전체 삭제 후 재삽입
      expect(() {
        ime(c, 0, 1, '');
        ime(c, 0, 0, '가');
      }, returnsNormally, reason: '전체 삭제 후 재삽입 시 크래시가 없어야 함');
    });

    // --------------------------------------------------
    // T8. 엔터 후 새 줄에 배경색 없음
    //
    // 재현 시나리오:
    //   "가나다"(background:yellow) 있음 → background OFF → 엔터
    //   → 새 줄에서 "라" 입력 → 배경색 없어야 함
    // --------------------------------------------------
    test('T8: 엔터 후 새 줄에 배경색 없음', () {
      const bgColor = '#FFF4D03F';

      // "가나다"(background:yellow) 삽입
      c.formatText(0, 0, BackgroundAttribute(bgColor));
      ime(c, 0, 0, '가');
      ime(c, 1, 0, '나');
      ime(c, 2, 0, '다');

      // background OFF
      c.updateSelection(sel(3), ChangeSource.local);
      c.formatText(3, 0, BackgroundAttribute(null));

      // 엔터 삽입 (data='\n', insertNewline=true)
      c.replaceText(3, 0, '\n', sel(4));

      // 새 줄에서 "라" 입력 (cachedChar=null → activeStyle의 background:null 적용)
      ime(c, 4, 0, '라');

      expect(attrValueAt(c, 4, Attribute.background), isNull,
          reason: '엔터 후 새 줄의 글자에 배경색이 없어야 함');
    });

    // --------------------------------------------------
    // T9. 새 글자(cachedChar=null) → activeStyle 전체 적용 (bold:true)
    //
    // 재현 시나리오:
    //   bold ON → 빈 에디터에 "가" 입력
    //   기대: "가"에 bold 적용
    // --------------------------------------------------
    test('T9: 새 위치(cachedChar=null)에 bold ON 후 입력 → bold 적용', () {
      c.formatText(0, 0, Attribute.bold);
      ime(c, 0, 0, '가');

      expect(attrValueAt(c, 0, Attribute.bold), isTrue,
          reason: '빈 위치에 bold ON 후 입력한 글자는 bold여야 함');
    });

    // --------------------------------------------------
    // T11. 안드로이드 IME: bold 있는 첫 글자 뒤에 bold OFF 후 두 번째 글자 입력
    //
    // 재현 시나리오 (안드로이드):
    //   "가"(bold) → bold OFF → "나" 입력
    //   Android IME: composing range가 이전 글자 포함 →
    //     replaceText(0, 1, '간')  (ㄴ 조합 중)
    //     replaceText(0, 1, '가나') (ㄴ→나 완성)
    //   기대: "가"는 bold 유지, "나"는 bold 없음
    // --------------------------------------------------
    test('T11: 안드로이드 IME - bold 첫 글자 뒤 bold OFF 후 입력 → 첫 글자 bold 유지', () {
      // "가"(bold) 삽입
      c.formatText(0, 0, Attribute.bold);
      ime(c, 0, 0, '가');
      expect(attrValueAt(c, 0, Attribute.bold), isTrue, reason: '"가" bold여야 함');

      // bold OFF (커서 index=1로 이동)
      c.updateSelection(sel(1), ChangeSource.local);
      c.formatText(1, 0, Attribute.clone(Attribute.bold, null));

      // Android IME 패턴: composing range가 이전 글자("가") 포함
      // step1: "간" compose (replaceText(0, 1, '간'))
      ime(c, 0, 1, '간');
      expect(attrValueAt(c, 0, Attribute.bold), isTrue,
          reason: 'composing 중 "간"에도 bold 유지');

      // step2: "가나" compose (replaceText(0, 1, '가나'))
      ime(c, 0, 1, '가나');

      expect(attrValueAt(c, 0, Attribute.bold), isTrue,
          reason: '"가"의 bold는 유지되어야 함');
      expect(attrValueAt(c, 1, Attribute.bold), isNot(isTrue),
          reason: '"나"에는 bold가 없어야 함');
    });

    // --------------------------------------------------
    // T12. 안드로이드 IME: 배경색 있는 첫 글자 뒤에 배경색 OFF 후 두 번째 글자 입력
    //
    // 재현 시나리오 (안드로이드):
    //   "가"(background) → background OFF → "나" 입력 (Android composing replace)
    //   기대: "가"는 background 유지, "나"는 background 없음
    // --------------------------------------------------
    test('T12: 안드로이드 IME - 배경색 첫 글자 뒤 배경색 OFF 후 입력 → 첫 글자 배경색 유지', () {
      const bgColor = '#FFF4D03F';

      // "가"(background) 삽입
      c.formatText(0, 0, BackgroundAttribute(bgColor));
      ime(c, 0, 0, '가');
      expect(attrValueAt(c, 0, Attribute.background), equals(bgColor));

      // background OFF
      c.updateSelection(sel(1), ChangeSource.local);
      c.formatText(1, 0, BackgroundAttribute(null));

      // Android IME 패턴
      ime(c, 0, 1, '간');
      ime(c, 0, 1, '가나');

      expect(attrValueAt(c, 0, Attribute.background), equals(bgColor),
          reason: '"가"의 배경색은 유지되어야 함');
      expect(attrValueAt(c, 1, Attribute.background), isNull,
          reason: '"나"에는 배경색이 없어야 함');
    });

    // --------------------------------------------------
    // T10. color 없는 상황에서 bold ON 후 IME 입력 → 이전 글자 bold 미오염
    //
    // 색상이 없을 때(cachedChar={}) 도 bold 오염 방지 검증
    // --------------------------------------------------
    test('T10: 색상 없는 이전 글자에 bold ON이 전파되지 않음', () {
      // "가" 삽입 (no color, no bold)
      ime(c, 0, 0, '가');
      expect(attrValueAt(c, 0, Attribute.bold), isNot(isTrue));

      // bold ON
      c.updateSelection(sel(1), ChangeSource.local);
      c.formatText(1, 0, Attribute.bold);

      // "ㄴ" INSERT at 1 (새 위치, bold 적용)
      ime(c, 1, 0, 'ㄴ');

      // IME: "가ㄴ" DELETE → "가" INSERT → "나" INSERT
      ime(c, 0, 2, '');
      ime(c, 0, 0, '가'); // 캐시: "가"의 스타일 = {} (no bold)
      ime(c, 1, 0, '나'); // 캐시: "ㄴ"의 스타일 = {bold:true}

      // "가"는 bold 없음 (cachedChar={} → bold:null 적용)
      expect(attrValueAt(c, 0, Attribute.bold), isNot(isTrue),
          reason: '색상 없는 이전 글자("가")에 bold가 전파되면 안 됨');
      // "나"는 원래 "ㄴ"의 bold:true 복원
      expect(attrValueAt(c, 1, Attribute.bold), isTrue,
          reason: '원래 bold로 입력된 "ㄴ"이 "나"가 될 때 bold 유지');
    });
  });
}

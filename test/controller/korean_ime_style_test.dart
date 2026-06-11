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

  // ────────────────────────────────────────────────
  // 일본어 IME 괄호 변환 테스트
  //
  // 일본어 IME에서 특정 단어(예: まるかっこ)를 입력 후
  // 특수기호(예: 「（」)로 변환할 때의 동작 검증.
  //
  // 핵심 버그: isImeCompose에서 len > number일 때(예: 5글자→1글자)
  //   else if 블록이 모든 삭제 위치(0..len-1)를 캐시하지만,
  //   retain 루프는 0..number-1만 업데이트한다.
  //   number..len-1 위치가 _styleCacheByIndex에 스테일(stale)로 남아
  //   삭제 후 재입력 시 _imePreservedStyles로 복사되어 불필요한
  //   document.compose를 유발하는 문제를 검증한다.
  // ────────────────────────────────────────────────
  group('일본어 IME 괄호 변환', () {
    late QuillController c;

    setUp(() {
      c = QuillController.basic();
    });

    tearDown(() {
      c.dispose();
    });

    // --------------------------------------------------
    // JA-T1: まるかっこ(5글자) → （(1글자) 1회 변환
    //
    // 일본어 IME 이벤트 시퀀스:
    //   INSERT "ま" → COMPOSE "まる" → COMPOSE "まるか"
    //   → COMPOSE "まるかっ" → COMPOSE "まるかっこ"
    //   → 후보 선택으로 COMPOSE "（" (len=5, number=1)
    //
    // 기대: 문서에 「（」만 남아야 함
    // --------------------------------------------------
    test('JA-T1: まるかっこ→（ 1회 변환 정상', () {
      // 일본어 로마자 입력 composing 시퀀스
      ime(c, 0, 0, 'ま');     // isInsertOnly: "ま" 삽입
      ime(c, 0, 1, 'まる');   // isImeCompose: len=1, number=2
      ime(c, 0, 2, 'まるか'); // isImeCompose: len=2, number=3
      ime(c, 0, 3, 'まるかっ'); // isImeCompose: len=3, number=4
      ime(c, 0, 4, 'まるかっこ'); // isImeCompose: len=4, number=5
      // 후보 선택: len=5, number=1 → stale entries [1..4] 발생
      ime(c, 0, 5, '（');

      expect(c.document.toPlainText(), equals('（\n'),
          reason: '1회째 まるかっこ→（ 변환 후 문서에 「（」가 있어야 함');
    });

    // --------------------------------------------------
    // JA-T2: 1회 변환 후 삭제 → 2회째 변환 (스테일 캐시 회귀 테스트)
    //
    // 버그 재현 시나리오:
    //   1회: まるかっこ → （  (len=5→1 시 positions 1..4가 stale)
    //   삭제: 「（」 삭제 → document 비어짐
    //         → _imePreservedStyles에 stale entries [1..4] 복사됨
    //   2회: まるかっこ → （  (stale 엔트리로 인한 불필요한 compose 발생)
    //
    // 기대: 2회째도 「（」가 정상 입력되어야 함
    // --------------------------------------------------
    test('JA-T2: 1회 변환 후 삭제 → 2회째 변환도 정상 (스테일 캐시 회귀)', () {
      // 1회째 변환
      ime(c, 0, 0, 'ま');
      ime(c, 0, 1, 'まる');
      ime(c, 0, 2, 'まるか');
      ime(c, 0, 3, 'まるかっ');
      ime(c, 0, 4, 'まるかっこ');
      ime(c, 0, 5, '（'); // isImeCompose: len=5, number=1 → stale entries [1..4]

      expect(c.document.toPlainText(), equals('（\n'), reason: '1회째 변환 확인');

      // 「（」 삭제 → document.length <= 1 → stale entries가 _imePreservedStyles로 복사됨
      ime(c, 0, 1, '');
      expect(c.document.toPlainText(), equals('\n'), reason: '삭제 후 문서 비어야 함');

      // 2회째 변환 (버그가 있으면 이 시퀀스가 올바르게 동작하지 않음)
      ime(c, 0, 0, 'ま');
      ime(c, 0, 1, 'まる');
      ime(c, 0, 2, 'まるか');
      ime(c, 0, 3, 'まるかっ');
      ime(c, 0, 4, 'まるかっこ');
      ime(c, 0, 5, '（');

      expect(c.document.toPlainText(), equals('（\n'),
          reason: '2회째 まるかっこ→（ 변환도 「（」가 정상 입력되어야 함 (스테일 캐시 버그 회귀 방지)');
    });

    // --------------------------------------------------
    // JA-T3: 1→1 단순 변환 「(」→「（」 2회 연속 (삭제 후 재시도)
    //
    // 일본어 IME에서 ASCII「(」를 전각「（」로 직접 변환하는 경우.
    // len=1, number=1이므로 스테일 엔트리 문제는 없지만
    // _imePreservedStyles 기반 shouldRetainDelta 동작을 검증한다.
    // --------------------------------------------------
    test('JA-T3: ASCII (→ 전각（ 1→1 변환 후 삭제 → 2회째도 정상', () {
      // 1회째 (isInsertOnly "(", isImeCompose "(→（")
      ime(c, 0, 0, '(');   // isInsertOnly
      ime(c, 0, 1, '（');  // isImeCompose: len=1, number=1

      expect(c.document.toPlainText(), equals('（\n'), reason: '1회째 「（」 확인');

      // 삭제
      ime(c, 0, 1, '');
      expect(c.document.toPlainText(), equals('\n'));

      // 2회째
      ime(c, 0, 0, '(');
      ime(c, 0, 1, '（');

      expect(c.document.toPlainText(), equals('（\n'),
          reason: '2회째도 「（」가 정상 입력되어야 함');
    });

    // --------------------------------------------------
    // JA-T4: bold 없는 환경에서 まるかっこ→（ 2회 변환 시 bold 오염 없음
    //
    // stale cache에 의한 불필요한 retain이 실행되더라도
    // 서식이 없는 문서에서 bold가 전파되지 않아야 한다.
    // --------------------------------------------------
    test('JA-T4: 서식 없는 환경에서 まるかっこ→（ 2회 변환 후 bold 없음', () {
      // 1회째
      ime(c, 0, 0, 'ま');
      ime(c, 0, 1, 'まる');
      ime(c, 0, 2, 'まるか');
      ime(c, 0, 3, 'まるかっ');
      ime(c, 0, 4, 'まるかっこ');
      ime(c, 0, 5, '（');

      // 삭제 후 2회째
      ime(c, 0, 1, '');
      ime(c, 0, 0, 'ま');
      ime(c, 0, 1, 'まる');
      ime(c, 0, 2, 'まるか');
      ime(c, 0, 3, 'まるかっ');
      ime(c, 0, 4, 'まるかっこ');
      ime(c, 0, 5, '（');

      expect(attrValueAt(c, 0, Attribute.bold), isNot(isTrue),
          reason: '서식 없는 「（」에 bold가 전파되면 안 됨');
      expect(c.document.toPlainText(), equals('（\n'));
    });

    // --------------------------------------------------
    // JA-T5: bold ON 상태에서 まるかっこ→（ 변환 시 bold 적용
    //
    // 사용자가 bold를 켠 상태에서 일본어 괄호를 입력하면
    // 변환된 「（」에도 bold가 적용되어야 한다.
    // --------------------------------------------------
    test('JA-T5: bold ON 상태에서 まるかっこ→（ 변환 시 bold 유지', () {
      c.formatText(0, 0, Attribute.bold);

      ime(c, 0, 0, 'ま');
      ime(c, 0, 1, 'まる');
      ime(c, 0, 2, 'まるか');
      ime(c, 0, 3, 'まるかっ');
      ime(c, 0, 4, 'まるかっこ');
      ime(c, 0, 5, '（');

      expect(attrValueAt(c, 0, Attribute.bold), isTrue,
          reason: 'bold ON 상태에서 変換した「（」は bold이어야 함');
    });

    // --------------------------------------------------
    // JA-T6: 「か」→「（）」(1글자→2글자) 삭제 후 2회째 변환
    //
    // 재현 시나리오 (사용자 보고):
    //   1회: か(composing) → （）(candidate 선택, isImeCompose len=1→number=2)
    //   삭제: 「）」삭제 → 「（」삭제 → document 비어짐
    //   2회: か → （） 재시도
    //
    // 기대: 2회째도 「（）」가 정상 입력되어야 함.
    // 버그가 있으면 cursor가 「か」앞(position 0)으로 이동하고 「（）」가 입력되지 않는다.
    // --------------------------------------------------
    test('JA-T6: か→（） 1회 변환 후 삭제 → 2회째 변환 정상', () {
      // 1회째: isInsertOnly "か" → isImeCompose "か"→"（）"
      ime(c, 0, 0, 'か');          // isInsertOnly
      ime(c, 0, 1, '（）');        // isImeCompose: len=1, number=2

      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '1회째 か→（） 변환 확인');

      // 삭제: 「）」→「（」 순서 삭제
      ime(c, 1, 1, ''); // 「）」삭제
      ime(c, 0, 1, ''); // 「（」삭제 → document 비어짐
      expect(c.document.toPlainText(), equals('\n'),
          reason: '삭제 후 document 비어야 함');

      // 2회째: 같은 시퀀스 반복
      ime(c, 0, 0, 'か');
      ime(c, 0, 1, '（）');

      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '2회째 か→（） 변환도 정상이어야 함 (cursor 이동 버그 회귀 방지)');
    });

    // --------------------------------------------------
    // JA-T7: かっこ→（）2회 변환 (같은 프레임 내 삭제→재삽입)
    //
    // 재현 시나리오 (사용자 보고 "입력했던 글자를 삭제후 かっこ 입력 후 (를 선택하면 선택이 안됨"):
    //   1회: か → （） 변환
    //   같은 프레임에 삭제 + 2회째 か → （） 변환
    //
    // 기대: _pendingStyleReset 취소가 올바르게 동작하고 2회째도 「（）」가 입력됨.
    // --------------------------------------------------
    test('JA-T7: 같은 프레임 내 삭제+재삽입 후 か→（） 변환 정상', () {
      // 1회째 변환
      ime(c, 0, 0, 'か');
      ime(c, 0, 1, '（）');
      expect(c.document.toPlainText(), equals('（）\n'));

      // 같은 프레임: 삭제 후 즉시 재삽입 (_pendingStyleReset 취소 경로)
      ime(c, 1, 1, '');
      ime(c, 0, 1, ''); // document 비어짐 → _pendingStyleReset = true
      // _pendingStyleReset이 false로 취소되어야 함:
      ime(c, 0, 0, 'か');      // INSERT → _pendingStyleReset = false
      ime(c, 0, 1, '（）');    // isImeCompose len=1→2

      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '같은 프레임 삭제+재삽입 후에도 か→（） 변환이 정상이어야 함');
    });

    // --------------------------------------------------
    // JA-T8: か→（） 5회 연속 삭제+재입력 반복
    //
    // _styleCacheByIndex / _imePreservedStyles 상태 축적 없이
    // 매 사이클이 이전 사이클의 영향을 받지 않아야 한다.
    // --------------------------------------------------
    test('JA-T8: か→（） 5회 연속 삭제+재입력 반복 — 매 사이클 정상', () {
      void oneCycle(int round) {
        ime(c, 0, 0, 'か');
        ime(c, 0, 1, '（）');
        expect(c.document.toPlainText(), equals('（）\n'),
            reason: '$round회째 변환 확인');
        // 「）」→「（」순서 삭제
        ime(c, 1, 1, '');
        ime(c, 0, 1, '');
        expect(c.document.toPlainText(), equals('\n'),
            reason: '$round회째 삭제 후 document 비어야 함');
      }

      for (var i = 1; i <= 5; i++) {
        oneCycle(i);
      }

      // 마지막 변환 (5회 삭제 후)
      ime(c, 0, 0, 'か');
      ime(c, 0, 1, '（）');
      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '5회 반복 후 마지막 変換도 정상이어야 함 (상태 축적 버그 방지)');
    });

    // --------------------------------------------------
    // JA-T9: か→（） 반복 + まるかっこ→（ 혼합 삭제+재입력
    //
    // len=1→2 변환과 len=5→1 변환이 혼재할 때 캐시 오염 없음을 검증한다.
    // --------------------------------------------------
    test('JA-T9: か→（） 와 まるかっこ→（ 혼합 5회 반복 — 상태 오염 없음', () {
      void shortCycle(int round) {
        ime(c, 0, 0, 'か');
        ime(c, 0, 1, '（）');
        expect(c.document.toPlainText(), equals('（）\n'),
            reason: '[$round] か→（） 변환 확인');
        ime(c, 1, 1, '');
        ime(c, 0, 1, '');
      }

      void longCycle(int round) {
        ime(c, 0, 0, 'ま');
        ime(c, 0, 1, 'まる');
        ime(c, 0, 2, 'まるか');
        ime(c, 0, 3, 'まるかっ');
        ime(c, 0, 4, 'まるかっこ');
        ime(c, 0, 5, '（');
        expect(c.document.toPlainText(), equals('（\n'),
            reason: '[$round] まるかっこ→（ 변환 확인');
        ime(c, 0, 1, '');
      }

      // 혼합 반복: short → long → short → long → short
      shortCycle(1);
      longCycle(2);
      shortCycle(3);
      longCycle(4);
      shortCycle(5);

      // 마지막 변환
      ime(c, 0, 0, 'か');
      ime(c, 0, 1, '（）');
      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '혼합 반복 후 마지막 変換도 정상이어야 함');
      expect(attrValueAt(c, 0, Attribute.bold), isNot(isTrue),
          reason: 'bold 오염 없어야 함');
    });

    // --------------------------------------------------
    // JA-T10: か→（） 변환 후 삭제 없이 か 재입력
    //
    // 재현 시나리오:
    //   1. か → （） 변환 (cursor at 1, 괄호 안)
    //   2. 삭제 없이 cursor 위치(1)에서 か 재입력
    //   3. 문서: "（か）\n" — 정상 삽입 확인
    //   4. 그 か 도 （）로 변환 가능 확인 → "（（））\n"
    //
    // 이전 변환 후 남은 캐시가 다음 입력에 영향을 주지 않아야 한다.
    // --------------------------------------------------
    test('JA-T10: か→（） 변환 후 삭제 없이 か 재입력 — 괄호 안 정상 입력', () {
      // 1단계: か → （） 변환
      ime(c, 0, 0, 'か');         // isInsertOnly at 0
      ime(c, 0, 1, '（）');       // isImeCompose len=1→2, cursor → sel(2)

      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '1단계: か→（） 변환 확인');

      // 2단계: cursor=1 (괄호 안)에서 か 삽입 (삭제 없이)
      // Samsung 키보드 기준: 변환 후 cursor가 （ 다음 위치(1)에 있음
      ime(c, 1, 0, 'か');         // isInsertOnly at 1

      expect(c.document.toPlainText(), equals('（か）\n'),
          reason: '2단계: 괄호 안에 か 삽입 확인');

      // 3단계: 괄호 안의 か(position 1)를 （）로 재변환
      ime(c, 1, 1, '（）');       // isImeCompose len=1→2 at position 1

      expect(c.document.toPlainText(), equals('（（））\n'),
          reason: '3단계: 괄호 안의 か→（） 중첩 변환 확인');
    });

    // --------------------------------------------------
    // JA-T11: か→（） 변환 후 삭제 없이 か 재입력 + 변환 → 삭제 → 다시 か 입력
    //
    // 복합 시나리오: 변환 중 삽입+삭제가 혼재할 때
    //   1. か → （）
    //   2. 괄호 안에 か 삽입 → "（か）"
    //   3. か(at 1) 삭제 → "（）"
    //   4. 다시 か 삽입 + 변환 → 정상 동작 확인
    // --------------------------------------------------
    test('JA-T11: か→（） 후 괄호 안 か 삽입+삭제+재삽입+변환 — 연속 상태 정상', () {
      // 1단계: か → （）
      ime(c, 0, 0, 'か');
      ime(c, 0, 1, '（）');
      expect(c.document.toPlainText(), equals('（）\n'));

      // 2단계: 괄호 안에 か 삽입
      ime(c, 1, 0, 'か');
      expect(c.document.toPlainText(), equals('（か）\n'));

      // 3단계: か(at 1) 삭제 → "（）\n"
      ime(c, 1, 1, '');
      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '괄호 안 か 삭제 확인');

      // 4단계: 괄호 안(position 1)에 か 재삽입 후 변환
      ime(c, 1, 0, 'か');
      ime(c, 1, 1, '（）');
      expect(c.document.toPlainText(), equals('（（））\n'),
          reason: '삭제 후 재삽입+변환 정상 확인');
    });

    // --------------------------------------------------
    // JA-T12: か→（） 변환 후 괄호 다음(position 2)에서 か 입력
    //
    // 재현 시나리오:
    //   1. か → （） 변환 → "（）\n", cursor at 1 (Samsung 기준)
    //   2. cursor를 position 2(）다음)로 이동
    //   3. か 입력 → 기대: "（）か\n"
    //   4. 그 か 도 （）로 변환 가능 확인 → "（）（）\n"
    // --------------------------------------------------
    test('JA-T12: か→（） 변환 후 괄호 다음(position 2)에서 か 입력 → （）か', () {
      // 1단계: か → （）
      ime(c, 0, 0, 'か');
      ime(c, 0, 1, '（）');
      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '1단계: か→（） 변환 확인');

      // 2단계: position 2 (）바로 다음)에 か 삽입
      ime(c, 2, 0, 'か');
      expect(c.document.toPlainText(), equals('（）か\n'),
          reason: '2단계: 괄호 다음 か 삽입 → "（）か"이어야 함');

      // 3단계: その か(at 2) 도 （）로 변환 → "（）（）\n"
      ime(c, 2, 1, '（）');
      expect(c.document.toPlainText(), equals('（）（）\n'),
          reason: '3단계: 괄호 다음 か→（） 변환 → "（）（）"이어야 함');
    });

    // --------------------------------------------------
    // JA-T13: か→（） 변환 후 괄호 다음 か 입력 → 삭제 → 재입력+변환
    //
    // 괄호 바깥에서의 삭제+재입력 사이클도 정상 동작해야 한다.
    // --------------------------------------------------
    test('JA-T13: か→（） 후 position 2에서 か 삽입 → 삭제 → 재입력+변환', () {
      // 1단계: か → （）
      ime(c, 0, 0, 'か');
      ime(c, 0, 1, '（）');

      // 2단계: position 2에 か 삽입 → "（）か\n"
      ime(c, 2, 0, 'か');
      expect(c.document.toPlainText(), equals('（）か\n'));

      // 3단계: か(at 2) 삭제 → "（）\n"
      ime(c, 2, 1, '');
      expect(c.document.toPlainText(), equals('（）\n'),
          reason: '괄호 다음 か 삭제 확인');

      // 4단계: 다시 position 2에 か 삽입 후 변환
      ime(c, 2, 0, 'か');
      ime(c, 2, 1, '（）');
      expect(c.document.toPlainText(), equals('（）（）\n'),
          reason: '삭제 후 재삽입+변환 → "（）（）"이어야 함');
    });
  });
}

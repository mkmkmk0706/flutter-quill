import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, TargetPlatform;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show ClipboardData, Clipboard;
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../../quill_delta.dart';
import '../common/structs/image_url.dart';
import '../common/structs/offset_value.dart';
import '../common/utils/embeds.dart';
import '../delta/delta_diff.dart';
import '../document/attribute.dart';
import '../document/document.dart';
import '../document/nodes/embeddable.dart';
import '../document/nodes/leaf.dart';
import '../document/structs/doc_change.dart';
import '../document/style.dart';
import '../editor/config/editor_config.dart';
import '../editor/raw_editor/raw_editor_state.dart';
import '../editor_toolbar_controller_shared/clipboard/clipboard_service_provider.dart';
import 'clipboard/quill_controller_paste.dart';
import 'clipboard/quill_controller_rich_paste.dart';
import 'quill_controller_config.dart';





void _dbg(String msg) {
  if (kDebugMode) log(msg);
}

typedef ReplaceTextCallback = bool Function(int index, int len, Object? data);
typedef DeleteCallback = void Function(int cursorPosition, bool forward);

class QuillController extends ChangeNotifier {
  QuillController({
    required Document document,
    required TextSelection selection,
    this.config = const QuillControllerConfig(),
    this.keepStyleOnNewLine = true,
    this.onReplaceText,
    this.onDelete,
    this.onSelectionCompleted,
    this.onSelectionChanged,
    this.readOnly = false,
  }) : _document = document,
       _selection = selection;

  factory QuillController.basic({
    QuillControllerConfig config = const QuillControllerConfig(),
  }) => QuillController(
    config: config,
    document: Document(),
    selection: const TextSelection.collapsed(offset: 0),
  );

  final QuillControllerConfig config;

  /// Document managed by this controller.
  Document _document;

  Document get document => _document;

  // Store editor config to pass them to the document to
  // support search within embed objects https://github.com/singerdmx/flutter-quill/pull/2090.
  // For internal use only, should not be exposed as a public API.
  QuillEditorConfig? _editorConfig;

  @visibleForTesting
  @internal
  QuillEditorConfig? get editorConfig => _editorConfig;
  @internal
  set editorConfig(QuillEditorConfig? value) {
    _editorConfig = value;
    _setDocumentSearchProperties();
  }

  // Pass required editor config to the document
  // to support search within embed objects https://github.com/singerdmx/flutter-quill/pull/2090
  void _setDocumentSearchProperties() {
    _document
      ..searchConfig = _editorConfig?.searchConfig
      ..embedBuilders = _editorConfig?.embedBuilders
      ..unknownEmbedBuilder = _editorConfig?.unknownEmbedBuilder;
  }

  set document(Document doc) {
    _document = doc;
    _setDocumentSearchProperties();

    // Prevent the selection from
    _selection = const TextSelection(baseOffset: 0, extentOffset: 0);

    notifyListeners();
  }

  /// Tells whether to keep or reset the [toggledStyle]
  /// when user adds a new line.
  final bool keepStyleOnNewLine;

  /// Currently selected text within the [document].
  TextSelection get selection => _selection;
  TextSelection _selection;

  /// Custom [replaceText] handler
  /// Return false to ignore the event
  ReplaceTextCallback? onReplaceText;

  /// Custom delete handler
  DeleteCallback? onDelete;

  void Function()? onSelectionCompleted;
  void Function(TextSelection textSelection)? onSelectionChanged;

  /// Store any styles attribute that got toggled by the tap of a button
  /// and that has not been applied yet.
  /// It gets reset after each format action within the [document].
  Style toggledStyle = const Style();

  /// Android에서 색상/서식 적용 후 에디터 재포커스 시 selection 변경으로
  /// toggledStyle이 리셋되는 것을 한 번 방지하는 플래그.
  bool _preserveToggledStyleOnNextSelection = false;

  /// 포맷 버튼 클릭 시 저장되어, Android 포커스 이벤트로 toggledStyle이
  /// 리셋되어도 첫 번째 글자에 올바른 서식이 유지되도록 하는 백업 스타일.
  /// _preserveToggledStyleOnNextSelection 이 소비된 이후의 추가 selection
  /// 이벤트에서도 toggledStyle을 복원하는 데 사용된다.
  Style? _pendingInlineStyleValue;

  Style? get _pendingInlineStyle => _pendingInlineStyleValue;

  /// 새 서식 의도가 세워지면 "이월된 끄기 의도" 표식은 자동으로 풀린다.
  /// (대입 지점이 여러 곳이라 setter 로 모아 빠뜨리지 않게 한다)
  set _pendingInlineStyle(Style? value) {
    _pendingInlineStyleValue = value;
    _offIntentCarried = false;
  }

  /// 현재 [_pendingInlineStyle] 이 **캐럿이 자리를 떠나며 남긴 끄기 의도**인지.
  ///
  /// 이 잔재는 "옮긴 자리에서 입력할 때 앞 글자 서식을 상속하지 않게" 하려고 남기는 값이라
  /// **입력에만 쓰고 표시에는 쓰면 안 된다.** toggledStyle 에 실으면
  /// getSelectionStyle() 의 mergeAll 이 문서에 실제로 있는 서식까지 지워
  /// 캐럿을 서식 글자에 놓아도 툴바가 꺼진 채로 표시된다.
  bool _offIntentCarried = false;

  /// 지금 처리 중인 selection 변경이 **사용자發**(탭 등)인지.
  /// replaceText 가 자기 편집 결과로 부르는 내부 갱신과 구분한다.
  bool _selectionChangeFromUser = false;

  /// [_pendingInlineStyle] 이 세워진 캐럿 위치.
  /// 캐럿이 다른 자리로 옮겨가면 그 서식 의도는 의미를 잃으므로 복원하지 않는다.
  int? _pendingInlineStyleOffset;

  /// IME composing 중 mixin이 안정적으로 참조할 수 있도록 공개한다.
  /// toggledStyle은 selection 이벤트로 초기화될 수 있으므로, 이 값을 사용한다.
  Style? get pendingInlineStyle => _pendingInlineStyle;

  /// [raw_editor_actions] handling of backspace event may need to force the style displayed in the toolbar
  void forceToggledStyle(Style style) {
    toggledStyle = style;
    // _updateSelection이 나중에 toggledStyle을 리셋하더라도 _pendingInlineStyle로 복원되도록 함께 갱신한다.
    //
    // ★ 빈 Style(서식 없음)이 오면 _pendingInlineStyle 도 비운다.
    // 백스페이스 액션(QuillEditorDeleteTextAction)은 삭제 후 문맥 서식을 이 메서드로 알려주는데,
    // 평문 구간까지 지우면 빈 Style 이 온다. 그때 pending 을 남겨두면
    // _onlyInlineToggledStyleStyle 의 폴백과 _updateSelection 의 복원이 예전 서식을 되살려,
    // 평문 자리에 입력한 글자에 지워진 서식이 다시 붙는다.
    //
    // 주의: "서식 끄기" 의도는 {bold:null} 처럼 값이 null 인 *속성이 있는* 스타일이라
    // isNotEmpty 이다. 따라서 이 분기는 OFF 의도 보존(T1/T3/T11/T12)을 건드리지 않는다.
    _pendingInlineStyle = style.isNotEmpty ? style : null;
    _dbg('[replaceText] forceToggledStyle:$toggledStyle');
    notifyListeners();
  }

  bool ignoreFocusOnTextChange = false;

  /// 입력(특히 IME) 텍스트를 문서에 반영하기 전에 강제할 최대 글자수.
  ///
  /// 0 이하이면 제한 없음. grapheme(이모지 안전) 기준으로 세며 '\n'은 세지 않는다.
  /// [RawEditorStateTextInputClientMixin.updateEditingValue] 에서 diff 를 문서에
  /// 적용하기 전에 초과분을 잘라내므로, 문서를 사후에 줄일 때 발생하던 IME offset
  /// desync 크래시 없이 화면에서도 실시간으로 길이가 제한된다.
  /// (Flutter [LengthLimitingTextInputFormatter] 와 동일한 위치·방식)
  int maxLength = 0;

  /// [maxLength] 초과 입력이 잘렸을 때 호출된다. (토스트 등 사용자 알림용)
  VoidCallback? onMaxLengthExceeded;

  /// Skip the keyboard request in [QuillRawEditorState.requestKeyboard].
  ///
  /// See also: [QuillRawEditorState._didChangeTextEditingValue]
  bool skipRequestKeyboard = false;

  /// [clearComposing] 의 실제 구현. 에디터가 부착될 때 스스로 등록한다.
  ///
  /// 컨트롤러는 에디터 state 를 참조하지 않으므로(IME 연결은 에디터가 쥐고 있다)
  /// 콜백으로 연결한다. 에디터가 없거나 dispose 된 뒤에는 null 이라 호출이 무시된다.
  @internal
  VoidCallback? clearComposingHandler;

  /// 진행 중인 IME 조합(한글/일본어 자동완성 등)을 확정하고 조합 상태를 해지한다.
  ///
  /// IME 는 조합 중 자기 사본을 들고 있다가 앱이 문서를 바꾸면 그 사본을 다시 주장해
  /// 글자가 중복/유실되거나 커서가 어긋난다. 이미지·영상 임베드 삽입처럼 앱이 문서를
  /// 직접 바꾸기 **직전에** 호출할 것.
  ///
  /// 조합 중이 아니거나 에디터가 붙어있지 않으면 아무 일도 하지 않는다.
  /// 텍스트는 그대로 두고 composing 만 비우므로 키보드는 내려가지 않는다.
  void clearComposing() => clearComposingHandler?.call();

  /// True when this [QuillController] instance has been disposed.
  ///
  /// A safety mechanism to ensure that listeners don't crash when adding,
  /// removing or listeners to this instance.
  bool _isDisposed = false;

  Stream<DocChange> get changes => document.changes;

  TextEditingValue get plainTextEditingValue =>
      TextEditingValue(text: document.toPlainText(), selection: selection);

  /// Only attributes applied to all characters within this range are
  /// included in the result.
  Style getSelectionStyle() {
    return document
        .collectStyle(selection.start, selection.end - selection.start)
        .mergeAll(toggledStyle);
  }

  // Increases or decreases the indent of the current selection by 1.
  void indentSelection(bool isIncrease) {
    if (selection.isCollapsed) {
      _indentSelectionFormat(isIncrease);
    } else {
      _indentSelectionEachLine(isIncrease);
    }
  }

  void _indentSelectionFormat(bool isIncrease) {
    final indent = getSelectionStyle().attributes[Attribute.indent.key];
    if (indent == null) {
      if (isIncrease) {
        formatSelection(Attribute.indentL1);
      }
      return;
    }
    if (indent.value == 1 && !isIncrease) {
      formatSelection(Attribute.clone(Attribute.indentL1, null));
      return;
    }
    if (isIncrease) {
      if (indent.value < 5) {
        formatSelection(Attribute.getIndentLevel(indent.value + 1));
      }
      return;
    }
    formatSelection(Attribute.getIndentLevel(indent.value - 1));
  }

  void _indentSelectionEachLine(bool isIncrease) {
    final styles = document.collectAllStylesWithOffset(
      selection.start,
      selection.end - selection.start,
    );
    for (final style in styles) {
      final indent = style.value.attributes[Attribute.indent.key];
      final formatIndex = math.max(style.offset, selection.start);
      final formatLength =
          math.min(style.offset + (style.length ?? 0), selection.end) -
          style.offset;
      Attribute? formatAttribute;
      if (indent == null) {
        if (isIncrease) {
          formatAttribute = Attribute.indentL1;
        }
      } else if (indent.value == 1 && !isIncrease) {
        formatAttribute = Attribute.clone(Attribute.indentL1, null);
      } else if (isIncrease) {
        if (indent.value < 5) {
          formatAttribute = Attribute.getIndentLevel(indent.value + 1);
        }
      } else {
        formatAttribute = Attribute.getIndentLevel(indent.value - 1);
      }
      if (formatAttribute != null) {
        document.format(formatIndex, formatLength, formatAttribute);
      }
    }
    notifyListeners();
  }

  /// Returns all styles and Embed for each node within selection
  List<OffsetValue> getAllIndividualSelectionStylesAndEmbed() {
    final stylesAndEmbed = document.collectAllIndividualStyleAndEmbed(
      selection.start,
      selection.end - selection.start,
    );
    return stylesAndEmbed;
  }

  /// Returns plain text for each node within selection
  String getPlainText() {
    final text = document.getPlainText(
      selection.start,
      selection.end - selection.start,
    );
    return text;
  }

  /// Returns all styles for any character within the specified text range.
  List<Style> getAllSelectionStyles() {
    final styles = document.collectAllStyles(
      selection.start,
      selection.end - selection.start,
    )..add(toggledStyle);
    return styles;
  }

  void undo() {
    final result = document.undo();
    if (result.changed) {
      _handleHistoryChange(result.len);
    }
  }

  void _handleHistoryChange(int len) {
    updateSelection(TextSelection.collapsed(offset: len), ChangeSource.local);
  }

  void redo() {
    final result = document.redo();
    if (result.changed) {
      _handleHistoryChange(result.len);
    }
  }

  bool get hasUndo => document.hasUndo;

  bool get hasRedo => document.hasRedo;

  /// clear editor
  void clear() {
    replaceText(
      0,
      plainTextEditingValue.text.length - 1,
      '',
      const TextSelection.collapsed(offset: 0),
    );
  }

  void replaceTextOri(
    int index,
    int len,
    Object? data,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    @experimental bool shouldNotifyListeners = true,
  }) {
    assert(data is String || data is Embeddable || data is Delta);

    if (onReplaceText != null && !onReplaceText!(index, len, data)) {
      return;
    }

    Delta? delta;
    Style? style;
    if (len > 0 || data is! String || data.isNotEmpty) {
      delta = document.replace(index, len, data);

      /// Remove block styles as they can only be attached to line endings
      style = Style.attr(
        Map<String, Attribute>.fromEntries(
          toggledStyle.attributes.entries.where(
            (a) => a.value.scope != AttributeScope.block,
          ),
        ),
      );
      var shouldRetainDelta =
          style.isNotEmpty &&
          delta.isNotEmpty &&
          delta.length <= 2 &&
          delta.last.isInsert;
      if (shouldRetainDelta &&
          style.isNotEmpty &&
          delta.length == 2 &&
          delta.last.data == '\n') {
        // if all attributes are inline, shouldRetainDelta should be false
        final anyAttributeNotInline = style.values.any(
          (attr) => !attr.isInline,
        );
        if (!anyAttributeNotInline) {
          shouldRetainDelta = false;
        }
      }
      if (shouldRetainDelta) {
        final retainDelta = Delta()
          ..retain(index)
          ..retain(data is String ? data.length : 1, style.toJson());
        document.compose(retainDelta, ChangeSource.local);
      }
    }

    if (textSelection != null) {
      if (delta == null || delta.isEmpty) {
        _updateSelection(textSelection);
      } else {
        final user = Delta()
          ..retain(index)
          ..insert(data)
          ..delete(len);
        final positionDelta = getPositionDelta(user, delta);
        _updateSelection(
          textSelection.copyWith(
            baseOffset: textSelection.baseOffset + positionDelta,
            extentOffset: textSelection.extentOffset + positionDelta,
          ),
          insertNewline: data == '\n',
        );
      }
    }

    if (ignoreFocus) {
      ignoreFocusOnTextChange = true;
    }
    if (shouldNotifyListeners) {
      notifyListeners();
    }
    ignoreFocusOnTextChange = false;
  }

  void toggleInlineStyle(int index, Style selectionStyle) {
    forceImeStyle(index, selectionStyle);
  }

  /// [data] 가 문서에 넣는 글자 수.
  ///
  /// 붙여넣기는 data 가 [Delta] 라 길이를 1 로 세면 실제 캐럿 위치와 어긋난다.
  /// 그러면 _pendingInlineStyleOffset 이 틀어져 "캐럿이 떠났다" 로 판정되고,
  /// 붙여넣기 전에 켜둔 서식이 붙여넣은 뒤 사라진다. (iOS 에서만 드러남 — Android 는
  /// 위치 기준 검사를 하지 않는다)
  int _insertedLengthOf(Object? data) {
    if (data is String) return data.length;
    if (data is Delta) {
      var length = 0;
      for (final op in data.toList()) {
        if (op.isInsert) length += op.length ?? 0;
      }
      return length;
    }
    return 1;
  }

  Style? getCachedStyle(int index) {
    return _styleCacheByIndex[index] ?? _imePreservedStyles[index];
  }

  Style _onlyInlineToggledStyleStyle() {
    final sourceStyle = toggledStyle.isNotEmpty
        ? toggledStyle
        : (_pendingInlineStyle ?? const Style());
    final result = Map<String, Attribute>.fromEntries(
      sourceStyle.attributes.entries.where(
        (a) => a.value.scope != AttributeScope.block,
      ),
    );
    // _pendingInlineStyle의 null값 속성(서식 OFF 의도)을 누락 없이 반영한다.
    // _updateSelection의 mergeAll이 null값 속성을 제거하면 toggledStyle에서 사라지는데,
    // _pendingInlineStyle에는 보존되어 있으므로 여기서 다시 추가해 OFF 의도를 유지한다.
    // 예: 엔터 후 background:null이 toggledStyle에서 사라지더라도 activeStyle에 포함됨.
    if (_pendingInlineStyle != null) {
      for (final attr in _pendingInlineStyle!.values) {
        if (attr.value == null &&
            attr.scope != AttributeScope.block &&
            !result.containsKey(attr.key)) {
          result[attr.key] = attr;
        }
      }
    }
    return Style.attr(result);
  }

  // 문서 서식(selectionStyle)에서 인라인(비블록) 속성만 추출한다.
  // link는 이어 입력 시 링크가 확장되지 않도록 제외한다.
  Style _inlineContextStyle(Style documentStyle) {
    final result = Map<String, Attribute>.fromEntries(
      documentStyle.attributes.entries.where(
        (a) =>
            a.value.scope != AttributeScope.block &&
            a.key != Attribute.link.key,
      ),
    );
    return Style.attr(result);
  }

  final Map<int, Style> _styleCacheByIndex = {};
  // document.length<=1 클리어로부터 IME 조합 스타일을 보호하는 보조 캐시.
  // DELETE로 문서가 일시 비워질 때 _styleCacheByIndex 값을 여기에 복사해두고,
  // 바로 이어지는 INSERT에서 사용한 뒤 비운다.
  final Map<int, Style> _imePreservedStyles = {};

  // 전체 삭제 후 서식 초기화 예약 플래그.
  // document.length <= 1이 되면 true로 설정하고 postFrameCallback으로 초기화 실행을 예약한다.
  // 같은 프레임 내에 INSERT(IME 조합 완성)가 오면 false로 캔슬된다.
  bool _pendingStyleReset = false;

  // 문서 컨텍스트 상속을 방지하기 위한 bool 인라인 속성의 null 버전 목록.
  // cachedChar 기반 retain 적용 시, charStyle에 없는 속성을 명시적으로 null 처리하여
  // 앞 글자의 bold/italic 등이 새 글자로 자동 상속되는 것을 차단한다.
  static final List<Attribute> _nullBoolInlineAttrs = [
    Attribute.clone(Attribute.bold, null),
    Attribute.clone(Attribute.italic, null),
    Attribute.clone(Attribute.underline, null),
    Attribute.clone(Attribute.strikeThrough, null),
    Attribute.clone(Attribute.inlineCode, null),
    Attribute.clone(Attribute.small, null),
  ];
  void cacheStyle(int index, int length) {
    for (var i = 0; i < length; i++) {
      final newIndex = index + i;
      _styleCacheByIndex[newIndex] = document.collectStyle(newIndex, 1);
      _dbg(
        '[replaceText] retain[$newIndex] savedStyle: ${_styleCacheByIndex[newIndex]}',
      );
    }
  }

  /// 버튼 클릭 후 호출: 현재 커서 위치에 사용자가 원하는 스타일을 캐시에 미리 저장한다.
  /// [forceImeStyle] 이 마지막으로 심은 캐시 위치.
  /// 삭제 시 스테일 캐시를 정리할 때 이 항목만은 지우지 않는다. (아래 설명)
  int? _forceImeStyleIndex;

  void forceImeStyle(int index, Style selectionStyle) {
    _styleCacheByIndex[index] = selectionStyle;
    _forceImeStyleIndex = index;
    _dbg('[replaceText] forceImeStyle index:[$index] style=$selectionStyle');
  }

  void replaceText(
    int index,
    int len,
    Object? data,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    bool shouldNotifyListeners = true,
  }) {
    assert(data is String || data is Embeddable || data is Delta);

    if (onReplaceText != null && !onReplaceText!(index, len, data)) {
      return;
    }

    final isDeleteOnly = data is String && data.isEmpty && len > 0;
    final isInsertOnly = data is String && data.isNotEmpty && len == 0;

    // INSERT(또는 IME 교체)가 오면 전체 삭제 후 서식 초기화 예약을 취소한다.
    // 같은 프레임 내에 온 INSERT는 한국어 IME 조합 완성(ㄱ→가 등)이므로 서식을 보존해야 한다.
    if (_pendingStyleReset && !isDeleteOnly) {
      _pendingStyleReset = false;
    }

    final selectionStyle = getSelectionStyle();
    final toggleStyle = toggledStyle;

    // iOS 에서 삭제 후 입력 시 적용할 문맥 서식. null 이면 동기화하지 않는다.
    Style? iosDeletedStyle;

    if (isDeleteOnly) {
      // 삭제로 문서가 줄면 삭제 지점보다 뒤의 캐시 항목은 이미 사라진 글자를 가리킨다.
      // 그대로 두면 나중에 그 위치에 입력한 글자가 죽은 글자의 서식을 물려받는다.
      // (백스페이스를 여러 번 누른 뒤 재입력하면 지운 글자들의 서식이 위치별로 되살아나던 증상)
      // 조합 재삽입에 필요한 index..index+len-1 은 바로 아래 cacheStyle 이 다시 채운다.
      // ★ forceImeStyle 이 심은 위치는 지우지 않는다.
      // 앱은 서식 버튼 직후 toggleInlineStyle(=forceImeStyle) 로 **캐럿 위치**에 사용자가 고른
      // 서식을 심는다. 그런데 iOS 한글 IME 는 캐럿 앞쪽 단어를 통째로 지우므로, 그 삭제의
      // "뒤쪽 정리"가 캐럿에 심어둔 서식까지 날려버렸다.
      // (실기기 로그: forceImeStyle index:[6] 인데 삭제는 retain[4] Delete[2] → k>5 로 6이 제거됨)
      _styleCacheByIndex.removeWhere(
        (k, _) => k > index + len - 1 && k != _forceImeStyleIndex,
      );
      cacheStyle(index, len);
      // iOS 는 IME composing 이 무효라 mixin 의 forceToggledStyle 동기화(Android 경로)가
      // 일어나지 않는다. 그러면 캐시(삭제된 글자의 문맥 서식)와 toggledStyle(사용자가 켠 서식)이
      // 서로 다른 값을 갖고, 삽입 시 글자마다 이긴 쪽이 달라진다.
      // (캐시가 있는 앞 글자는 문맥 서식 → 캐시가 없는 뒷 글자는 toggledStyle)
      // Android 와 동일하게 문맥 서식으로 통일하기 위해 삭제 시점에 toggledStyle 을 맞춘다.
      // 실제 동기화는 _updateSelection 이 toggledStyle 을 리셋한 뒤인 이 메서드 끝에서 한다.
      //
      // ★ 범위의 첫 글자가 아니라 마지막 글자의 서식을 쓴다.
      // iOS 한글 IME 는 음절을 조합할 때 이전 글자를 지웠다 다시 넣으며(예: "가나다ㄹ" 에서
      // "다ㄹ" 삭제 → "다" 삽입 → "라" 삽입) 그 삭제가 이 경로로 들어온다.
      // 사용자가 방금 켠 서식은 범위의 마지막 글자에만 들어있고 앞 글자는 아직 이전 서식이라,
      // 첫 글자를 집으면 새로 고른 서식이 음절마다 이전 서식으로 되돌아간다.
      // (배경색을 바꿔도 계속 이전 배경색으로 입력되던 증상)
      // 백스페이스 1 글자 삭제는 index == index + len - 1 이라 동작이 같다.
      //
      // ★ link 는 제외한다(_inlineContextStyle).
      // 캐시는 문서 서식 그대로라 링크 글자면 link 도 들어있다. 그대로 toggledStyle 에 실으면
      // 링크 뒤에 이어 쓰는 글자마다 link 가 따라붙어 서식이 풀리지 않는다.
      // iOS 한글 IME 는 음절마다 삭제→삽입을 반복해 이 경로를 계속 타므로 증상이 이어진다.
      // (Android 는 composing 경로라 여기 오지 않아 문제가 없었다)
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final cached = getCachedStyle(index + len - 1);
        iosDeletedStyle = cached == null ? null : _inlineContextStyle(cached);
      }
    } else if (data is String && data.isNotEmpty && len > 0) {
      // 안드로이드 IME는 composing range 전체를 replace하므로 이전 글자까지 포함된다.
      // isDeleteOnly가 아니어서 cacheStyle이 호출되지 않으므로,
      // 아직 캐시가 없는 위치의 스타일을 document.replace 전에 미리 저장한다.
      for (var i = index; i < index + len; i++) {
        if (!_styleCacheByIndex.containsKey(i) &&
            !_imePreservedStyles.containsKey(i)) {
          _styleCacheByIndex[i] = document.collectStyle(i, 1);
        }
      }
    }

    _dbg(
      '[replaceText] ===> retain[$index] Delete[$len] Insert[$data] isInsert:$isInsertOnly, isDelete:$isDeleteOnly, ** selectionStyle=$selectionStyle ## toggledStyle=$toggleStyle',
    );

    // document.replace 전후로 toggledStyle/_pendingInlineStyle은 변경되지 않으므로
    // 미리 계산해서 블록 안팎 두 곳에서 재사용한다.
    final activeStyle = _onlyInlineToggledStyleStyle();
    // IME 조합 교체 (한국어 등): ㄱ→가 처럼 composing text를 교체하는 경우
    // _pendingInlineStyle 업데이트(블록 밖)에서도 참조하므로 여기서 미리 계산한다.
    final isImeCompose = data is String && data.isNotEmpty && len > 0;
    // 명시적 서식(activeStyle)이 없고 IME 조합이 아닌 경우,
    // 커서 위치의 문서 서식(selectionStyle)에서 인라인 속성을 상속한다.
    // 예: 빨간 텍스트 중간에 커서를 놓고 이모지를 입력하면 같은 색으로 이어진다.
    // isImeCompose는 cachedChar 기반으로 서식을 처리하므로 여기서는 제외한다.
    final effectiveActiveStyle =
        (!isImeCompose && activeStyle.isEmpty)
            ? _inlineContextStyle(selectionStyle)
            : activeStyle;

    Delta? delta;
    if (len > 0 || data is! String || data.isNotEmpty) {
      delta = document.replace(index, len, data);

      final indexStyle = getCachedStyle(index);

      _dbg(
        '[replaceText] styleIndex=$index indexStyle=$indexStyle, $data replace[${delta.toJson()}]',
      );

      // 순수 삽입: [retain, insert] 또는 [insert]
      final isPureInsert = delta.length <= 2 && delta.last.isInsert;

      final number = data is String ? data.length : 1;

      // ★ 삽입 범위 **전체** 에 캐시가 있는지 본다. (예전엔 index 한 곳만 봤다)
      // iOS 한글 IME 는 단어를 통째로 다시 넣으므로 한 번의 insert 가 여러 글자다.
      // 앞 글자에 캐시가 없고 뒤 글자에만 있으면(서식 버튼이 캐럿에 심어둔 경우) 예전 조건은
      // retain 자체를 건너뛰어, 심어둔 서식이 적용되지 않았다.
      var hasCachedInRange = false;
      for (var i = 0; i < number; i++) {
        final st = getCachedStyle(index + i);
        if (st != null && st.isNotEmpty) {
          hasCachedInRange = true;
          break;
        }
      }

      // indexStyle != null 만으로는 Style{}(서식 없음)도 shouldRetainDelta를 유발한다.
      // 서식 없는 글자에 대해 retain을 적용해도 no-op이므로 isNotEmpty를 추가 확인한다.
      // ★ 붙여넣기(data is Delta)는 제외한다.
      // 붙여넣는 내용은 자기 서식을 이미 갖고 있는데, 아래 retain 루프는
      // `number = data is String ? data.length : 1` 이라 Delta 를 "1글자"로 세어
      // **붙여넣은 첫 글자에만** 현재 toggledStyle 을 찍어버린다.
      // (Bold 를 켜둔 채 평문을 붙여넣으면 첫 글자만 굵어지던 증상)
      // 임베드 삽입(Embeddable)은 기존 동작을 유지한다.
      var shouldRetainDelta =
          data is! Delta &&
          (effectiveActiveStyle.isNotEmpty || hasCachedInRange) &&
          delta.isNotEmpty &&
          (isPureInsert || isImeCompose);
      final isEnd =
          activeStyle.isNotEmpty &&
          delta.length == 2 &&
          delta.last.data == '\n';

      if (shouldRetainDelta && isEnd) {
        // if all attributes are inline, shouldRetainDelta should be false
        final anyAttributeNotInline = activeStyle.values.any(
          (attr) => !attr.isInline,
        );
        if (!anyAttributeNotInline) {
          shouldRetainDelta = false;
        }
      }

      if (shouldRetainDelta) {
        final retainDelta = Delta()..retain(index);
        for (var i = 0; i < number; i++) {
          final cachedChar = getCachedStyle(index + i);
          final Style charStyle;
          if (cachedChar != null) {
            // 캐시된 글자: 원래 서식 복원.
            // cachedChar={} (서식 없음)도 캐시 분기로 처리 → activeStyle 전파 차단.
            final attrs = Map<String, Attribute>.from(cachedChar.attributes);
            // 앞 글자로부터 bool 속성 상속을 막기 위해 캐시에 없는 속성을 명시적 null로 채운다.
            for (final nullAttr in _nullBoolInlineAttrs) {
              if (!attrs.containsKey(nullAttr.key)) {
                attrs[nullAttr.key] = nullAttr;
              }
            }
            // 사용자가 OFF한 속성(null값) 중 캐시에 없는 것만 추가 (캐시 값은 덮어쓰지 않음).
            for (final activeAttr in effectiveActiveStyle.values) {
              if (activeAttr.value == null &&
                  !attrs.containsKey(activeAttr.key)) {
                attrs[activeAttr.key] = activeAttr;
              }
            }
            charStyle = Style.attr(attrs);
          } else {
            charStyle = effectiveActiveStyle;
          }
          // 안드로이드 IME 연속 compose replace 대비: 직전 retain 스타일을 다음 이벤트에서 재사용.
          if (isImeCompose) {
            _styleCacheByIndex[index + i] = charStyle;
          }
          if (charStyle.isNotEmpty) {
            retainDelta.retain(1, charStyle.toJson());
          } else {
            retainDelta.retain(1);
          }
        }

        _dbg(
          '[replaceText] retain[$index ~ $number] isEnd:$isEnd activeStyle=$activeStyle',
        );

        // retainDelta가 no-op retain만 포함하면 document.compose 내부 trim() 후
        // delta가 비어 assertion 실패하므로 사전에 체크한다.
        retainDelta.trim();
        if (retainDelta.isNotEmpty) {
          document.compose(retainDelta, ChangeSource.local);
        }
      }

      // isImeCompose: retain 루프에서 캐시를 이미 최신 charStyle로 업데이트했으므로 클리어 안 함.
      // insert-only: 소비된 캐시 위치만 제거.
      if (!isDeleteOnly && !isImeCompose) {
        for (var i = 0; i < number; i++) {
          _styleCacheByIndex.remove(index + i);
          _imePreservedStyles.remove(index + i);
          if (_forceImeStyleIndex == index + i) _forceImeStyleIndex = null;
        }
      }
      // isImeCompose 변환 후 스테일 캐시 정리:
      // 1) len > number: retain 루프가 처리하지 않은 위치(number..len-1)의 _styleCacheByIndex 제거
      //    예: 「まるかっこ」(5글자) → 「（」(1글자) 변환 시 위치 1~4 스테일 제거
      // 2) 모든 isImeCompose: 이전 변환 사이클에서 남은 _imePreservedStyles 스테일 엔트리 제거
      //    삭제→재입력 사이클에서 빈 Style{}이 캐시에 남아 다음 변환에서 불필요한 retain을 유발
      if (isImeCompose) {
        for (var i = index + number; i < index + len; i++) {
          _styleCacheByIndex.remove(i);
        }
        for (var i = index; i < index + math.max(len, number); i++) {
          _imePreservedStyles.remove(i);
        }
      }
    }

    // 엔터('\n') 제외: 새 줄에서 toggledStyle이 iOS 다중 selection 이벤트에서도 유지되도록 한다.
    // 비어있으면 기존 값 유지: 한국어 IME 조합 중 document 일시 비워짐 등으로 유실 방지.
    // effectiveActiveStyle: 명시적 서식이 없을 때 selectionStyle 상속분도 포함하므로
    // 이후 _updateSelection에서 toggledStyle을 올바르게 복원한다.
    if ((data is! String || data != '\n') && effectiveActiveStyle.isNotEmpty) {
      _pendingInlineStyle = effectiveActiveStyle;
      _pendingInlineStyleOffset = index + _insertedLengthOf(data) - len;
    }

    if (textSelection != null) {
      if (delta == null || delta.isEmpty) {
        _updateSelection(textSelection);
      } else if (isImeCompose) {
        // IME compose replace (e.g. かっけ→かっこ): same char count, cursor stays
        // where the IME placed it. Skip positionDelta to avoid a spurious
        // sel=composing.end-1 mismatch that triggers an updateRemote correction
        // which clears Samsung's composing span and cancels the conversion.
        _updateSelection(textSelection, insertNewline: data == '\n');
      } else {
        final user = Delta()
          ..retain(index)
          ..insert(data)
          ..delete(len);
        final positionDelta = getPositionDelta(user, delta);
        _updateSelection(
          textSelection.copyWith(
            baseOffset: textSelection.baseOffset + positionDelta,
            extentOffset: textSelection.extentOffset + positionDelta,
          ),
          insertNewline: data == '\n',
        );
      }
    }

    // iOS 삭제: 위에서 구한 문맥 서식으로 toggledStyle 을 동기화한다.
    // _updateSelection 이 toggledStyle 을 리셋한 뒤여야 하므로 여기서 처리한다.
    // _pendingInlineStyle 도 함께 갱신해야 이후 selection 이벤트에서 복원된다.
    if (iosDeletedStyle != null) {
      // 문맥(iosDeletedStyle)은 **바탕**이고, _pendingInlineStyle(사용자 의도)이 **덮는다.**
      //
      // 값이 null 인 속성(서식 끄기 의도)은 캐시·문서에 남지 않는다. 문서에는 "키가 아예 없는"
      // 상태로만 저장되고, 그 상태로 삽입하면 앞 글자의 서식을 상속해버린다.
      // 그래서 여기서 실어줘야 한다. (배경색을 없앤 뒤 입력하면 이전 배경색이 다시 붙던 증상)
      //
      // ★ 예전에는 "값이 null 이고 문맥에 없는 키" 만 실었는데, 그러면 양방향이 다 깨진다.
      // iOS 한글 IME 는 입력마다 단어 전체를 지웠다 다시 넣으므로 "서식 버튼을 누른 직후" 의
      // 삭제가 이 경로를 탄다. 그때 지워진 글자의 서식(문맥)이 사용자 의도를 이기면
      // 방금 누른 버튼이 무시된다. 실기기 로그로 두 방향 모두 확인했다.
      //   켜기: 버튼 후 {bold:null, italic:true, underline:true} → 동기화 후 {bold:null}
      //         (막 켠 italic/underline 이 value != null 이라 실리지 않아 서식이 안 먹음)
      //   끄기: 버튼 후 {bold:null, ...} → 동기화 후 {bold:true, ...}
      //         (지워진 글자가 bold 라 문맥에 키가 있어 bold:null 이 차단됨 → 해제 안 됨)
      //
      // Android 는 iosDeletedStyle 이 항상 null 이라 이 블록에 진입하지 않는다.
      var syncStyle = iosDeletedStyle;
      final pending = _pendingInlineStyle;
      if (pending != null) {
        final merged = Map<String, Attribute>.from(syncStyle.attributes);
        for (final attr in pending.values) {
          // 서식 끄기 의도(value == null)는 **문맥을 덮는다.**
          // 끄기는 캐시·문서에 "키가 아예 없는" 상태로만 남으므로 여기서 실어주지 않으면
          // 삽입 시 앞 글자의 서식을 그대로 상속한다. 게다가 문맥(지워진 글자)이 그 서식을
          // 켜고 있으면 예전 조건(!merged.containsKey)에 막혀 **끈 서식이 도로 켜졌다.**
          // (실기기 로그: 사용자가 bold/italic/underline 을 모두 껐는데 동기화 결과가 전부 true)
          //
          // 반대로 켜기 의도(value != null)는 싣지 않는다. _pendingInlineStyle 은 타이핑으로도
          // 갱신되어 stale 일 수 있고, 그걸 실으면 서식 구간을 백스페이스로 지나 평문까지
          // 지운 뒤 입력해도 이전 서식이 붙는다. 사용자가 방금 켠 서식은 앱이 서식 버튼 직후
          // forceImeStyle 로 캐럿에 심어둔 캐시가 전달한다.
          if (attr.scope == AttributeScope.block) continue;
          if (attr.value == null) {
            merged[attr.key] = attr;
          } else if (!merged.containsKey(attr.key)) {
            merged[attr.key] = attr;
          }
        }
        syncStyle = Style.attr(merged);
      }
      toggledStyle = syncStyle;
      // ★ 문맥에 서식이 없으면 _pendingInlineStyle 도 비운다.
      // 예전에는 비어 있으면 갱신을 건너뛰어, 타이핑으로 남은 stale 값이 그대로 살아있었다.
      // 그러면 서식 구간을 백스페이스로 지나 평문까지 지운 뒤 입력해도 이전 서식이 붙는다.
      // (실기기 로그: savedStyle[3]={} 인데 동기화 결과가 {bold:true})
      _pendingInlineStyle = syncStyle.isNotEmpty ? syncStyle : null;
      _pendingInlineStyleOffset = syncStyle.isNotEmpty ? index : null;
      _dbg('[replaceText] iOS delete sync toggledStyle:$toggledStyle');
    }

    // document.length <= 1 (문서가 비워짐) 처리
    if (document.length <= 1) {
      _preserveToggledStyleOnNextSelection = false;
      // 스타일 캐시를 보조 맵으로 옮겨 바로 이어지는 IME INSERT에서 사용 가능하도록 보존한다.
      if (_styleCacheByIndex.isNotEmpty) {
        _imePreservedStyles.addAll(_styleCacheByIndex);
      }
      _styleCacheByIndex.clear();
      // 전체 삭제 후 서식 초기화를 다음 프레임으로 예약한다.
      // 한국어 IME 'ㄱ→가' 변환처럼 DELETE 직후 같은 프레임 내에 INSERT가 오면
      // replaceText 진입 시 _pendingStyleReset=false 로 취소되어 서식이 보존된다.
      // 사용자가 직접 모두 삭제한 경우 같은 프레임 내에 INSERT가 없으므로
      // 콜백이 실행되어 서식이 초기화된다.
      _pendingStyleReset = true;
      // scheduleFrame을 명시적으로 호출해 post-frame callback이 실행될 보장을 추가한다.
      // 위젯 트리 없는 테스트 환경에서도 tester.pump()로 콜백이 실행되도록 한다.
      SchedulerBinding.instance.scheduleFrame();
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_pendingStyleReset) {
          _pendingStyleReset = false;
          toggledStyle = const Style();
          _pendingInlineStyle = null;
          _imePreservedStyles.clear();
          notifyListeners();
        }
      });
    }

    if (ignoreFocus) {
      ignoreFocusOnTextChange = true;
    }

    if (shouldNotifyListeners) {
      notifyListeners();
    }

    ignoreFocusOnTextChange = false;
  }

  /// Called in two cases:
  /// forward == false && textBefore.isEmpty
  /// forward == true && textAfter.isEmpty
  /// Android only
  /// see https://github.com/singerdmx/flutter-quill/discussions/514
  void handleDelete(int cursorPosition, bool forward) =>
      onDelete?.call(cursorPosition, forward);

  void formatTextStyle(int index, int len, Style style) {
    style.attributes.forEach((key, attr) {
      formatText(index, len, attr);
    });
  }

  void formatText(
    int index,
    int len,
    Attribute? attribute, {
    @experimental bool shouldNotifyListeners = true,
  }) {
    if (len == 0 && attribute!.key != Attribute.link.key) {
      // Add the attribute to our toggledStyle.
      // It will be used later upon insertion.
      toggledStyle = toggledStyle.put(attribute);
      // Android에서 서식 적용 직후 에디터 재포커스 탭으로 인한 selection 변경이
      // toggledStyle을 리셋하지 않도록 한 번 보호한다.
      _preserveToggledStyleOnNextSelection = true;
      // 여러 번의 selection 이벤트에서도 서식이 유지되도록 별도로 저장한다.
      _pendingInlineStyle = toggledStyle;
      _pendingInlineStyleOffset = index;
      // 사용자가 새 서식을 설정했으므로 forceImeStyle이 남긴 stale 캐시를 비운다.
      // formatText → afterButtonPressed → forceImeStyle 순서이므로, 이 clear 이후
      // forceImeStyle이 최신 getSelectionStyle()로 재설정한다.
      // _imePreservedStyles도 함께 비워 이전 IME 사이클 데이터가 남지 않도록 한다.
      _styleCacheByIndex.clear();
      _imePreservedStyles.clear();
      _dbg('[replaceText] toggledStyle:$toggledStyle');
    }

    final change = document.format(index, len, attribute);
    // Transform selection against the composed change and give priority to
    // the change. This is needed in cases when format operation actually5
    // inserts data into the document (e.g. embeds).
    final adjustedSelection = selection.copyWith(
      baseOffset: change.transformPosition(selection.baseOffset),
      extentOffset: change.transformPosition(selection.extentOffset),
    );
    if (selection != adjustedSelection) {
      _updateSelection(adjustedSelection);
    }
    if (shouldNotifyListeners) {
      notifyListeners();
    }
  }

  void formatSelection(
    Attribute? attribute, {
    @experimental bool shouldNotifyListeners = true,
  }) {
    formatText(
      selection.start,
      selection.end - selection.start,
      attribute,
      shouldNotifyListeners: shouldNotifyListeners,
    );
  }

  void moveCursorToStart() {
    updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
  }

  void moveCursorToPosition(int position) {
    updateSelection(
      TextSelection.collapsed(offset: position),
      ChangeSource.local,
    );
  }

  void moveCursorToEnd() {
    updateSelection(
      TextSelection.collapsed(offset: plainTextEditingValue.text.length),
      ChangeSource.local,
    );
  }

  void updateSelection(TextSelection textSelection, ChangeSource source) {
    // 캐럿을 다른 자리에 놓으면 위치 캐시(_styleCacheByIndex)는 의미를 잃는다.
    //
    // 이 캐시는 "IME 가 지웠다 다시 넣는 글자의 원래 서식"을 위치로 기억하는 장치다.
    // 그런데 글 중간에 글자를 끼워 넣으면 뒤 글자들이 밀리는데 캐시는 **밀리기 전 위치**의
    // 서식을 그대로 들고 있어, 새로 친 글자가 원래 그 자리에 있던 글자의 서식을 물려받는다.
    // (실기기 로그: 평문 자리에 입력했는데 char[2]/char[3] 이 cached={bold:true} 로 굵어짐)
    //
    // 캐럿 이동은 새 입력 맥락의 시작이므로 여기서 버린다.
    // toggledStyle 등 알림을 유발하는 상태는 건드리지 않는다. (iOS selection 폭주 회피)
    final caretJumped = textSelection.isCollapsed &&
        textSelection.baseOffset != _selection.baseOffset;
    if (caretJumped) {
      _styleCacheByIndex.clear();
      _imePreservedStyles.clear();
      _forceImeStyleIndex = null;
    }
    // 캐럿을 다른 자리에 놓으면 "다음 글자에 적용할 서식" 의도는 의미를 잃는다.
    // 비우지 않으면 서식 끄기 의도({bold:null})가 남아, getSelectionStyle 의 mergeAll 이
    // 문서에 실제로 있는 서식까지 지워 툴바 버튼이 꺼진 채로 표시된다.
    //
    // ★ iOS 는 제외한다. iOS 에서 여기서 상태를 바꾸면
    //   notify → updateRemote → IME 가 selection 을 되쏘는 폭주가 일어나
    //   글자 중간에 입력할 때 캐럿이 문장 끝으로 튄다. (실기기 로그로 확인)
    //   iOS 는 아래 _updateSelection 안에서 위치 기준으로 처리한다.
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      final caretMoved = textSelection.isCollapsed &&
          (textSelection.baseOffset != _selection.baseOffset ||
              textSelection.extentOffset != _selection.extentOffset);
      if (caretMoved &&
          !_preserveToggledStyleOnNextSelection &&
          _pendingInlineStyle != null) {
        _pendingInlineStyle = null;
        _pendingInlineStyleOffset = null;
        toggledStyle = const Style();
      }
    }
    _selectionChangeFromUser = true;
    try {
      _updateSelection(textSelection);
    } finally {
      _selectionChangeFromUser = false;
    }
    notifyListeners();
  }

  void compose(Delta delta, TextSelection textSelection, ChangeSource source) {
    if (delta.isNotEmpty) {
      document.compose(delta, source);
    }

    textSelection = selection.copyWith(
      baseOffset: delta.transformPosition(selection.baseOffset, force: false),
      extentOffset: delta.transformPosition(
        selection.extentOffset,
        force: false,
      ),
    );
    if (selection != textSelection) {
      _updateSelection(textSelection);
    }

    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `addListener` won't be called on a
    // disposed `ChangeListener`
    if (!_isDisposed) {
      super.addListener(listener);
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    // By using `_isDisposed`, make sure that `removeListener` won't be called
    // on a disposed `ChangeListener`
    if (!_isDisposed) {
      super.removeListener(listener);
    }
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      document.close();
    }

    _isDisposed = true;
    super.dispose();
  }

  void _updateSelection(
    TextSelection textSelection, {
    bool insertNewline = false,
  }) {
    _selection = textSelection;

    final end = document.length - 1;

    _selection = selection.copyWith(
      baseOffset: math.min(selection.baseOffset, end),
      extentOffset: math.min(selection.extentOffset, end),
    );

    if (keepStyleOnNewLine) {
      if (insertNewline && selection.start > 0) {
        final style = document.collectStyle(selection.start - 1, 0);
        final ignoredStyles = style.attributes.values.where(
          (s) =>
              !s.isInline ||
              s.key == Attribute.link.key ||
              s.key == Attribute.color.key ||
              s.key == Attribute.background.key,
        );
        final inheritedStyle = style.removeAll(ignoredStyles.toSet());
        // 엔터 전 사용자가 변경한 서식(_pendingInlineStyle)을 우선 적용하고,
        // 이전 줄에서 상속할 스타일로 부족한 부분을 채운다.
        final prevPending = _pendingInlineStyle;
        toggledStyle = inheritedStyle.mergeAll(
          _pendingInlineStyle ?? toggledStyle,
        );
        // iOS는 Enter 한 번에 insertNewline=true 이벤트를 여러 번 보낸다.
        // mergeAll은 null-값 attr(예: bold:null)을 map에서 제거하므로,
        // prevPending의 null attr을 다시 추가하여 "서식 끄기" 의도를 보존한다.
        final pendingMap = Map<String, Attribute>.from(toggledStyle.attributes);
        if (prevPending != null) {
          for (final attr in prevPending.values) {
            if (attr.value == null && !pendingMap.containsKey(attr.key)) {
              pendingMap[attr.key] = attr;
            }
          }
        }
        _pendingInlineStyle = pendingMap.isNotEmpty
            ? Style.attr(pendingMap)
            : null;
        // ★ toggledStyle 에도 같은 "끄기 의도"를 남긴다.
        // 위 mergeAll 이 null-값 attr 을 지워버려 toggledStyle 만 빈 Style 이 되면,
        // getSelectionStyle() = 문서서식.mergeAll(toggledStyle) 이 지울 게 없어
        // **엔터 직전에 끈 서식이 문서 문맥 그대로 툴바에 켜진 채로 표시된다.**
        // (재현: bold ON → "abc" → bold OFF → 엔터 → 툴바만 bold 가 다시 켜짐.
        //  실제 입력은 OFF 로 나가므로 표시와 결과가 어긋난다.)
        //
        // 삽입 경로는 toggledStyle 이 비면 _pendingInlineStyle 로 폴백하는
        // _onlyInlineToggledStyleStyle() 를 쓰므로, 여기서 같은 값을 넣어도 결과가 같다.
        // 다른 분기(else)도 이미 toggledStyle = _pendingInlineStyle 로 맞추고 있어
        // 엔터 분기만 예외였던 것을 통일하는 셈이다.
        toggledStyle = _pendingInlineStyle ?? const Style();
        _preserveToggledStyleOnNextSelection = false;
        _dbg(
          '[replaceText] updateSelection 1:$toggledStyle [insertNewline && selection.start > 0] $insertNewline, ${selection.start}',
        );
      } else if (_preserveToggledStyleOnNextSelection) {
        // 서식 적용 직후 최초 selection 변경(재포커스 탭 등)은 toggledStyle을 보존한다.
        _preserveToggledStyleOnNextSelection = false;
        _dbg('[replaceText] updateSelection preserve:$toggledStyle');
      } else {
        // Android에서 포커스 이벤트가 여러 번 올 때 _pendingInlineStyle로 복원한다.
        //
        // ★ 단, 캐럿이 **그 의도가 세워진 자리에 그대로 있을 때만** 복원한다.
        // 예전에는 위치를 안 보고 항상 복원해서, 서식 끄기 의도({bold:null})가 영영 남았다.
        // 그러면 getSelectionStyle 의 mergeAll 이 문서에 실제로 있는 서식까지 지워
        // 서식 글자에 커서를 둬도 툴바 버튼이 꺼진 채로 표시됐다.
        //
        // updateSelection(public)에서 상태를 바꾸는 방식은 쓰지 않는다. 그렇게 하면
        // iOS 에서 notify → updateRemote → IME 가 되쏘는 selection 폭주가 생겨
        // 글자 중간에 입력할 때 캐럿이 문장 끝으로 튀었다. (실기기 로그로 확인)
        // 여기는 원래도 toggledStyle 을 쓰던 자리라 알림이 늘지 않는다.
        // Android 는 예전 그대로(무조건 복원). 위 updateSelection 가드가 캐럿 이동을 맡는다.
        // ★ 사용자發 selection 변경일 때만 위치를 따진다.
        // replaceText 가 자기 편집 결과로 부르는 내부 갱신(타이핑·붙여넣기)까지 검사하면,
        // 삽입으로 캐럿이 이동한 것을 "사용자가 옮겼다" 로 오인해 서식 의도를 버린다.
        // (붙여넣기 후 켜둔 서식이 iOS 에서만 사라지던 증상)
        final atPendingOffset = !_selectionChangeFromUser ||
            defaultTargetPlatform != TargetPlatform.iOS ||
            _pendingInlineStyleOffset == null ||
            _pendingInlineStyleOffset == selection.baseOffset;
        if (!atPendingOffset) {
          // 캐럿이 그 의도가 세워진 자리를 떠났다. _onlyInlineToggledStyleStyle 이
          // toggledStyle 이 비면 _pendingInlineStyle 로 폴백하므로 여기서 정리해야
          // 옮긴 자리의 입력에 이전 서식이 따라붙지 않는다.
          //
          // 단, **끄기 의도(value == null)는 남긴다.** 끄기는 문서·캐시에 흔적이 없어
          // 여기서 잃으면 앞 글자의 서식을 그대로 상속해버린다. (T3: 배경색 OFF 후 입력)
          final offIntent = <String, Attribute>{
            for (final a in _pendingInlineStyle?.values ?? const <Attribute>[])
              if (a.value == null) a.key: a,
          };
          _pendingInlineStyle =
              offIntent.isNotEmpty ? Style.attr(offIntent) : null;
          _pendingInlineStyleOffset = null;
          // 위 setter 가 풀어놓은 표식을 여기서만 다시 세운다. (이월된 끄기 의도)
          _offIntentCarried = offIntent.isNotEmpty;
        }
        // ★ 이월된 끄기 의도(_offIntentCarried)는 toggledStyle 에 싣지 않는다.
        // 예전에는 실었는데, 위에서 _pendingInlineStyleOffset 을 null 로 비우므로
        // 이후 **모든** selection 이벤트가 atPendingOffset=true 로 판정되어
        // 끄기 의도가 무한히 복원됐다. 그러면 getSelectionStyle() 이 문서에 실제로 있는
        // 서식까지 지워 **캐럿을 어디에 놓아도 툴바가 전부 꺼진 채로 표시된다.**
        // (iOS 전용 — Android 는 updateSelection(public) 이 캐럿 이동 시 의도를 비운다)
        // 입력 경로는 _onlyInlineToggledStyleStyle() 가 _pendingInlineStyle 로 폴백하므로
        // 끄기 의도 자체는 그대로 유효하다. (T3: 배경색 OFF 후 입력)
        toggledStyle = (atPendingOffset && !_offIntentCarried)
            ? (_pendingInlineStyle ?? const Style())
            : const Style();
        _dbg(
          '[replaceText] updateSelection 2:$toggledStyle [!] $insertNewline, '
          '${selection.start} (pendingOffset=$_pendingInlineStyleOffset atPending=$atPendingOffset)',
        );
      }
    } else {
      if (_preserveToggledStyleOnNextSelection) {
        _preserveToggledStyleOnNextSelection = false;
        _dbg(
          '[replaceText] updateSelection preserve(noKeepStyle):$toggledStyle',
        );
      } else {
        // Android에서 포커스 이벤트가 여러 번 올 때 _pendingInlineStyle로 복원한다.
        toggledStyle = _pendingInlineStyle ?? const Style();
        _dbg(
          '[replaceText] updateSelection 3:$toggledStyle !keepStyleOnNewLine',
        );
      }
    }

    onSelectionChanged?.call(textSelection);
  }

  /// Given offset, find its leaf node in document
  Leaf? queryNode(int offset) {
    return document.querySegmentLeafNode(offset).leaf;
  }

  // Notify toolbar buttons directly with attributes
  Map<String, Attribute> toolbarButtonToggler = const {};

  /// Clipboard caches last copy to allow paste with styles. Static to allow paste between multiple instances of editor.
  static String _pastePlainText = '';
  static Delta _pasteDelta = Delta();
  static List<OffsetValue> _pasteStyleAndEmbed = <OffsetValue>[];

  String get pastePlainText => _pastePlainText;
  Delta get pasteDelta => _pasteDelta;
  List<OffsetValue> get pasteStyleAndEmbed => _pasteStyleAndEmbed;

  /// Whether the text can be changed.
  ///
  /// When this is set to `true`, the text cannot be modified
  /// by any shortcut or keyboard operation. The text is still selectable.
  ///
  /// Defaults to `false`.
  bool readOnly;

  ImageUrl? _copiedImageUrl;
  ImageUrl? get copiedImageUrl => _copiedImageUrl;

  set copiedImageUrl(ImageUrl? value) {
    _copiedImageUrl = value;
    Clipboard.setData(const ClipboardData(text: ''));
  }

  @experimental
  bool clipboardSelection(bool copy) {
    copiedImageUrl = null;

    /// Get the text for the selected region and expand the content of Embedded objects.
    _pastePlainText = document.getPlainText(
      selection.start,
      selection.end - selection.start,
      includeEmbeds: true,
    );

    /// Get the internal representation so it can be pasted into a QuillEditor with style retained.
    _pasteStyleAndEmbed = getAllIndividualSelectionStylesAndEmbed();

    /// Get the deltas for the selection so they can be pasted into a QuillEditor with styles and embeds retained.
    _pasteDelta = document.toDelta().slice(selection.start, selection.end);

    if (!selection.isCollapsed) {
      Clipboard.setData(ClipboardData(text: _pastePlainText));
      if (!copy) {
        if (readOnly) return false;
        final sel = selection;
        replaceText(
          sel.start,
          sel.end - sel.start,
          '',
          TextSelection.collapsed(offset: sel.start),
        );
      }
      return true;
    }
    return false;
  }

  /// Returns whether paste operation was handled here.
  /// [updateEditor] is called if paste operation was successful.
  @experimental
  Future<bool> clipboardPaste({void Function()? updateEditor}) async {
    if (readOnly || !selection.isValid) return true;

    final clipboardConfig = config.clipboardConfig;

    if (await clipboardConfig?.onClipboardPaste?.call() == true) {
      updateEditor?.call();
      return true;
    }

    final pasteInternalImageSuccess = await _pasteInternalImage();
    if (pasteInternalImageSuccess) {
      updateEditor?.call();
      return true;
    }

    const enableExternalRichPasteDefault = true;
    if (clipboardConfig?.enableExternalRichPaste ??
        enableExternalRichPasteDefault) {
      final pasteHtmlSuccess = await pasteHTML();
      if (pasteHtmlSuccess) {
        updateEditor?.call();
        return true;
      }

      final pasteMarkdownSuccess = await pasteMarkdown();
      if (pasteMarkdownSuccess) {
        updateEditor?.call();
        return true;
      }
    }

    final clipboardService = ClipboardServiceProvider.instance;

    final onImagePaste = clipboardConfig?.onImagePaste;
    if (onImagePaste != null) {
      final imageBytes = await clipboardService.getImageFile();

      if (imageBytes != null) {
        final imageUrl = await onImagePaste(imageBytes);
        if (imageUrl != null) {
          replaceText(
            plainTextEditingValue.selection.end,
            0,
            BlockEmbed.image(imageUrl),
            null,
          );
          updateEditor?.call();
          return true;
        }
      }
    }

    final onGifPaste = clipboardConfig?.onGifPaste;
    if (onGifPaste != null) {
      final gifBytes = await clipboardService.getGifFile();
      if (gifBytes != null) {
        final gifUrl = await onGifPaste(gifBytes);
        if (gifUrl != null) {
          replaceText(
            plainTextEditingValue.selection.end,
            0,
            BlockEmbed.image(gifUrl),
            null,
          );
          updateEditor?.call();
          return true;
        }
      }
    }

    // Only process plain text if no image/gif was pasted.
    // Snapshot the input before using `await`.
    // See https://github.com/flutter/flutter/issues/11427
    final plainText = (await Clipboard.getData(Clipboard.kTextPlain))?.text;

    if (plainText != null) {
      final plainTextToPaste = await getTextToPaste(plainText);
      if (await pastePlainTextOrDelta(
        plainTextToPaste,
        pastePlainText: _pastePlainText,
        pasteDelta: _pasteDelta,
      )) {
        updateEditor?.call();
        return true;
      }
    }

    final onUnprocessedPaste = clipboardConfig?.onUnprocessedPaste;
    if (onUnprocessedPaste != null) {
      if (await onUnprocessedPaste()) {
        updateEditor?.call();
        return true;
      }
    }

    return false;
  }

  /// Return `true` if can paste an internal image
  Future<bool> _pasteInternalImage() async {
    final copiedImageUrl = _copiedImageUrl;
    if (copiedImageUrl != null) {
      final index = selection.baseOffset;
      final length = selection.extentOffset - index;
      replaceText(index, length, BlockEmbed.image(copiedImageUrl.url), null);
      if (copiedImageUrl.styleString.isNotEmpty) {
        formatText(
          getEmbedNode(this, index + 1).offset,
          1,
          StyleAttribute(copiedImageUrl.styleString),
        );
      }
      _copiedImageUrl = null;
      await Clipboard.setData(const ClipboardData(text: ''));
      return true;
    }
    return false;
  }

  void replaceTextWithEmbeds(
    int index,
    int len,
    String insertedText,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    @experimental bool shouldNotifyListeners = true,
  }) {
    final containsEmbed = insertedText.codeUnits.contains(
      Embed.kObjectReplacementInt,
    );
    insertedText = containsEmbed
        ? _adjustInsertedText(insertedText)
        : insertedText;

    replaceText(
      index,
      len,
      insertedText,
      textSelection,
      ignoreFocus: ignoreFocus,
      shouldNotifyListeners: shouldNotifyListeners,
    );

    _applyPasteStyleAndEmbed(insertedText, index, containsEmbed);
  }

  void _applyPasteStyleAndEmbed(
    String insertedText,
    int start,
    bool containsEmbed,
  ) {
    if (insertedText == pastePlainText && pastePlainText != '' ||
        containsEmbed) {
      final pos = start;
      for (final p in pasteStyleAndEmbed) {
        final offset = p.offset;
        final styleAndEmbed = p.value;

        final local = pos + offset;
        if (styleAndEmbed is Embeddable) {
          replaceText(local, 0, styleAndEmbed, null);
        } else {
          final style = styleAndEmbed as Style;
          if (style.isInline) {
            formatTextStyle(local, p.length!, style);
          } else if (style.isBlock) {
            final node = document.queryChild(local).node;
            if (node != null && p.length == node.length - 1) {
              for (final attribute in style.values) {
                document.format(local, 0, attribute);
              }
            }
          }
        }
      }
    }
  }

  String _adjustInsertedText(String text) {
    final sb = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == Embed.kObjectReplacementInt) {
        continue;
      }
      sb.write(text[i]);
    }
    return sb.toString();
  }
}

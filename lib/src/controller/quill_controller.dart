import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
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
  })  : _document = document,
        _selection = selection;

  factory QuillController.basic({
    QuillControllerConfig config = const QuillControllerConfig(),
  }) =>
      QuillController(
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
  Style? _pendingInlineStyle;

  /// IME composing 중 mixin이 안정적으로 참조할 수 있도록 공개한다.
  /// toggledStyle은 selection 이벤트로 초기화될 수 있으므로, 이 값을 사용한다.
  Style? get pendingInlineStyle => _pendingInlineStyle;

  /// [raw_editor_actions] handling of backspace event may need to force the style displayed in the toolbar
  void forceToggledStyle(Style style) {
    toggledStyle = style;
    // _updateSelection이 나중에 toggledStyle을 리셋하더라도 _pendingInlineStyle로 복원되도록 함께 갱신한다.
    if (style.isNotEmpty) {
      _pendingInlineStyle = style;
    }
    _dbg('[replaceText] forceToggledStyle:$toggledStyle');
    notifyListeners();
  }

  bool ignoreFocusOnTextChange = false;

  /// Skip the keyboard request in [QuillRawEditorState.requestKeyboard].
  ///
  /// See also: [QuillRawEditorState._didChangeTextEditingValue]
  bool skipRequestKeyboard = false;

  /// True when this [QuillController] instance has been disposed.
  ///
  /// A safety mechanism to ensure that listeners don't crash when adding,
  /// removing or listeners to this instance.
  bool _isDisposed = false;

  Stream<DocChange> get changes => document.changes;

  TextEditingValue get plainTextEditingValue => TextEditingValue(
        text: document.toPlainText(),
        selection: selection,
      );

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
      final formatLength = math.min(
            style.offset + (style.length ?? 0),
            selection.end,
          ) -
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
        selection.start, selection.end - selection.start);
    return stylesAndEmbed;
  }

  /// Returns plain text for each node within selection
  String getPlainText() {
    final text =
        document.getPlainText(selection.start, selection.end - selection.start);
    return text;
  }

  /// Returns all styles for any character within the specified text range.
  List<Style> getAllSelectionStyles() {
    final styles = document.collectAllStyles(
        selection.start, selection.end - selection.start)
      ..add(toggledStyle);
    return styles;
  }

  void undo() {
    final result = document.undo();
    if (result.changed) {
      _handleHistoryChange(result.len);
    }
  }

  void _handleHistoryChange(int len) {
    updateSelection(
      TextSelection.collapsed(
        offset: len,
      ),
      ChangeSource.local,
    );
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
    replaceText(0, plainTextEditingValue.text.length - 1, '',
        const TextSelection.collapsed(offset: 0));
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
      style = Style.attr(Map<String, Attribute>.fromEntries(toggledStyle
          .attributes.entries
          .where((a) => a.value.scope != AttributeScope.block)));
      var shouldRetainDelta = style.isNotEmpty &&
          delta.isNotEmpty &&
          delta.length <= 2 &&
          delta.last.isInsert;
      if (shouldRetainDelta &&
          style.isNotEmpty &&
          delta.length == 2 &&
          delta.last.data == '\n') {
        // if all attributes are inline, shouldRetainDelta should be false
        final anyAttributeNotInline =
            style.values.any((attr) => !attr.isInline);
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
            insertNewline: data == '\n');
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

  Style? getCachedStyle(int index) {
    return _styleCacheByIndex[index] ?? _imePreservedStyles[index];
  }

  Style _onlyInlineToggledStyleStyle() {
    final sourceStyle = toggledStyle.isNotEmpty
        ? toggledStyle
        : (_pendingInlineStyle ?? const Style());
    final result = Map<String, Attribute>.fromEntries(
      sourceStyle.attributes.entries
          .where((a) => a.value.scope != AttributeScope.block),
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
          '[replaceText] retain[$newIndex] savedStyle: ${_styleCacheByIndex[newIndex]}');
    }
  }

  /// 버튼 클릭 후 호출: 현재 커서 위치에 사용자가 원하는 스타일을 캐시에 미리 저장한다.
  void forceImeStyle(int index, Style selectionStyle) {
    _styleCacheByIndex[index] = selectionStyle;
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

    if (isDeleteOnly) {
      cacheStyle(index, len);
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

    Delta? delta;
    if (len > 0 || data is! String || data.isNotEmpty) {
      delta = document.replace(index, len, data);

      final indexStyle = getCachedStyle(index);

      _dbg(
          '[replaceText] styleIndex=$index indexStyle=$indexStyle, $data replace[${delta.toJson()}]');

      // 순수 삽입: [retain, insert] 또는 [insert]
      final isPureInsert = delta.length <= 2 && delta.last.isInsert;
      // IME 조합 교체 (한국어 등): ㄱ→가 처럼 composing text를 교체하는 경우
      final isImeCompose = data is String && data.isNotEmpty && len > 0;
      var shouldRetainDelta = (activeStyle.isNotEmpty || indexStyle != null) &&
          delta.isNotEmpty &&
          (isPureInsert || isImeCompose);
      final isEnd = activeStyle.isNotEmpty &&
          delta.length == 2 &&
          delta.last.data == '\n';

      if (shouldRetainDelta && isEnd) {
        // if all attributes are inline, shouldRetainDelta should be false
        final anyAttributeNotInline =
            activeStyle.values.any((attr) => !attr.isInline);
        if (!anyAttributeNotInline) {
          shouldRetainDelta = false;
        }
      }

      final number = data is String ? data.length : 1;

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
            for (final activeAttr in activeStyle.values) {
              if (activeAttr.value == null &&
                  !attrs.containsKey(activeAttr.key)) {
                attrs[activeAttr.key] = activeAttr;
              }
            }
            charStyle = Style.attr(attrs);
          } else {
            charStyle = activeStyle;
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
            '[replaceText] retain[$index ~ $number] isEnd:$isEnd activeStyle=$activeStyle');

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
        }
      }
    }

    // 엔터('\n') 제외: 새 줄에서 toggledStyle이 iOS 다중 selection 이벤트에서도 유지되도록 한다.
    // 비어있으면 기존 값 유지: 한국어 IME 조합 중 document 일시 비워짐 등으로 유실 방지.
    if ((data is! String || data != '\n') && activeStyle.isNotEmpty) {
      _pendingInlineStyle = activeStyle;
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
        extentOffset: change.transformPosition(selection.extentOffset));
    if (selection != adjustedSelection) {
      _updateSelection(adjustedSelection);
    }
    if (shouldNotifyListeners) {
      notifyListeners();
    }
  }

  void formatSelection(Attribute? attribute,
      {@experimental bool shouldNotifyListeners = true}) {
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
    _updateSelection(textSelection);
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

  void _updateSelection(TextSelection textSelection,
      {bool insertNewline = false}) {
    _selection = textSelection;

    final end = document.length - 1;

    _selection = selection.copyWith(
        baseOffset: math.min(selection.baseOffset, end),
        extentOffset: math.min(selection.extentOffset, end));

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
        toggledStyle =
            inheritedStyle.mergeAll(_pendingInlineStyle ?? toggledStyle);
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
        _pendingInlineStyle =
            pendingMap.isNotEmpty ? Style.attr(pendingMap) : null;
        _preserveToggledStyleOnNextSelection = false;
        _dbg(
            '[replaceText] updateSelection 1:$toggledStyle [insertNewline && selection.start > 0] $insertNewline, ${selection.start}');
      } else if (_preserveToggledStyleOnNextSelection) {
        // 서식 적용 직후 최초 selection 변경(재포커스 탭 등)은 toggledStyle을 보존한다.
        _preserveToggledStyleOnNextSelection = false;
        _dbg('[replaceText] updateSelection preserve:$toggledStyle');
      } else {
        // Android에서 포커스 이벤트가 여러 번 올 때 _pendingInlineStyle로 복원한다.
        toggledStyle = _pendingInlineStyle ?? const Style();
        _dbg(
            '[replaceText] updateSelection 2:$toggledStyle [!] $insertNewline, ${selection.start}');
      }
    } else {
      if (_preserveToggledStyleOnNextSelection) {
        _preserveToggledStyleOnNextSelection = false;
        _dbg(
            '[replaceText] updateSelection preserve(noKeepStyle):$toggledStyle');
      } else {
        // Android에서 포커스 이벤트가 여러 번 올 때 _pendingInlineStyle로 복원한다.
        toggledStyle = _pendingInlineStyle ?? const Style();
        _dbg(
            '[replaceText] updateSelection 3:$toggledStyle !keepStyleOnNewLine');
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
        replaceText(sel.start, sel.end - sel.start, '',
            TextSelection.collapsed(offset: sel.start));
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
      if (await await pastePlainTextOrDelta(plainTextToPaste,
          pastePlainText: _pastePlainText, pasteDelta: _pasteDelta)) {
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
      replaceText(
        index,
        length,
        BlockEmbed.image(copiedImageUrl.url),
        null,
      );
      if (copiedImageUrl.styleString.isNotEmpty) {
        formatText(
          getEmbedNode(this, index + 1).offset,
          1,
          StyleAttribute(copiedImageUrl.styleString),
        );
      }
      _copiedImageUrl = null;
      await Clipboard.setData(
        const ClipboardData(text: ''),
      );
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
    final containsEmbed =
        insertedText.codeUnits.contains(Embed.kObjectReplacementInt);
    insertedText =
        containsEmbed ? _adjustInsertedText(insertedText) : insertedText;

    replaceText(index, len, insertedText, textSelection,
        ignoreFocus: ignoreFocus, shouldNotifyListeners: shouldNotifyListeners);

    _applyPasteStyleAndEmbed(insertedText, index, containsEmbed);
  }

  void _applyPasteStyleAndEmbed(
      String insertedText, int start, bool containsEmbed) {
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

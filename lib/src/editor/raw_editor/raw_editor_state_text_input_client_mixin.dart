import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../common/extensions/view_id_ext.dart';
import '../../delta/delta_diff.dart';
import '../../document/document.dart';
import '../editor.dart';
import 'raw_editor.dart';

void _dbg(String msg) {
  if (kDebugMode) debugPrint(msg);
}

mixin RawEditorStateTextInputClientMixin on EditorState implements TextInputClient {
  TextInputConnection? _textInputConnection;
  TextEditingValue? __lastKnownRemoteTextEditingValue;

  // updateEditingValue 처리 중임을 나타내는 플래그.
  // 처리 중에는 _lastKnownRemoteTextEditingValue가 실제 컨트롤러 상태보다
  // 앞서 있으므로, 중간에 발생하는 updateRemoteValueIfNeeded 호출을 억제한다.
  // (예: replaceText 내부 notifyListeners → updateRemoteValueIfNeeded가
  // _updateSelection 실행 전에 sel=old 상태로 spurious send를 일으킬 수 있음)
  bool _processingIMEEvent = false;

  // 삼성 일본어 IME는 변환 확정 전 composing이 활성 상태인 채로 변환 결과("()")를 먼저 보낸다.
  // 이후 composing을 해제하며 커서를 괄호 사이({1,1})로 이동하는 이벤트를 별도로 전송한다.
  // 이 플래그는 "composing active + 텍스트 교체" 처리 후 세워지고,
  // 다음 정상 처리 이벤트에서 내려진다. 세워진 동안에는 line 261 skip을 억제해
  // 括弧 사이 커서 이벤트가 정상 처리되도록 한다.
  bool _conversionPreviewActive = false;

  set _lastKnownRemoteTextEditingValue(TextEditingValue? value) {
    __lastKnownRemoteTextEditingValue = value;
    if (composingRange.value != value?.composing) {
      composingRange.value = value?.composing ?? TextRange.empty;
    }
  }

  TextEditingValue? get _lastKnownRemoteTextEditingValue => __lastKnownRemoteTextEditingValue;

  /// The range of text that is currently being composed.
  final ValueNotifier<TextRange> composingRange = ValueNotifier<TextRange>(
    TextRange.empty,
  );

  /// Whether to create an input connection with the platform for text editing
  /// or not.
  ///
  /// Read-only input fields do not need a connection with the platform since
  /// there's no need for text editing capabilities (e.g. virtual keyboard).
  ///
  /// On the web, we always need a connection because we want some browser
  /// functionalities to continue to work on read-only input fields like:
  ///
  /// - Relevant context menu.
  /// - cmd/ctrl+c shortcut to copy.
  /// - cmd/ctrl+a to select all.
  /// - Changing the selection using a physical keyboard.
  bool get shouldCreateInputConnection => kIsWeb || !widget.config.readOnly;

  /// Returns `true` if there is open input connection.
  bool get hasConnection => _textInputConnection != null && _textInputConnection!.attached;

  /// Opens or closes input connection based on the current state of
  /// [focusNode] and [value].
  void openOrCloseConnection() {
    if (widget.config.focusNode.hasFocus && widget.config.focusNode.consumeKeyboardToken()) {
      openConnectionIfNeeded();
    } else if (!widget.config.focusNode.hasFocus) {
      closeConnectionIfNeeded();
    }
  }

  /// This setting is only honored on iOS devices.
  @visibleForTesting
  @internal
  Brightness createKeyboardAppearance() =>
      widget.config.keyboardAppearance ?? CupertinoTheme.maybeBrightnessOf(context) ?? Theme.of(context).brightness;

  void openConnectionIfNeeded() {
    if (!shouldCreateInputConnection) {
      return;
    }

    if (!hasConnection) {
      _lastKnownRemoteTextEditingValue = textEditingValue;
      _textInputConnection = TextInput.attach(
        this,
        TextInputConfiguration(
          inputType: TextInputType.multiline,
          readOnly: widget.config.readOnly,
          inputAction: widget.config.textInputAction,
          enableSuggestions: !widget.config.readOnly,
          keyboardAppearance: createKeyboardAppearance(),
          textCapitalization: widget.config.textCapitalization,
          allowedMimeTypes: widget.config.contentInsertionConfiguration == null
              ? const <String>[]
              : widget.config.contentInsertionConfiguration!.allowedMimeTypes,
          viewId: context.getViewId(),
        ),
      );

      _updateSizeAndTransform();
      //update IME position for Windows
      _updateComposingRectIfNeeded();
      //update IME position for Macos
      _updateCaretRectIfNeeded();

      /// Trap selection extends off end of document
      if (_lastKnownRemoteTextEditingValue != null) {
        if (_lastKnownRemoteTextEditingValue!.selection.end > _lastKnownRemoteTextEditingValue!.text.length) {
          _lastKnownRemoteTextEditingValue = _lastKnownRemoteTextEditingValue!.copyWith(
              selection: _lastKnownRemoteTextEditingValue!.selection
                  .copyWith(extentOffset: _lastKnownRemoteTextEditingValue!.text.length));
        }
      }
      _textInputConnection!.setEditingState(_lastKnownRemoteTextEditingValue!);
    }
    _textInputConnection!.show();
  }

  void _updateComposingRectIfNeeded() {
    final composingRange = _lastKnownRemoteTextEditingValue?.composing ?? textEditingValue.composing;
    if (hasConnection) {
      assert(mounted);
      if (composingRange.isValid) {
        final offset = composingRange.start;
        final composingRect = renderEditor.getLocalRectForCaret(TextPosition(offset: offset));
        _textInputConnection!.setComposingRect(composingRect);
      }
      SchedulerBinding.instance.addPostFrameCallback((_) => _updateComposingRectIfNeeded());
    }
  }

  void _updateCaretRectIfNeeded() {
    if (hasConnection) {
      if (!dirty && renderEditor.selection.isValid && renderEditor.selection.isCollapsed) {
        final currentTextPosition = TextPosition(offset: renderEditor.selection.baseOffset);
        final caretRect = renderEditor.getLocalRectForCaret(currentTextPosition);
        _textInputConnection!.setCaretRect(caretRect);
      }
      SchedulerBinding.instance.addPostFrameCallback((_) => _updateCaretRectIfNeeded());
    }
  }

  /// Closes input connection if it's currently open. Otherwise does nothing.
  void closeConnectionIfNeeded() {
    if (!hasConnection) {
      return;
    }
    _textInputConnection!.close();
    _textInputConnection = null;
    _lastKnownRemoteTextEditingValue = null;
  }

  /// Updates remote value based on current state of [document] and
  /// [selection].
  ///
  /// This method may not actually send an update to native side if it thinks
  /// remote value is up to date or identical.
  void updateRemoteValueIfNeeded() {
    if (!hasConnection) {
      return;
    }
    // updateEditingValue 처리 중(_processingIMEEvent=true)에는 억제한다.
    // _lastKnownRemoteTextEditingValue가 incoming value로 먼저 업데이트되지만,
    // 컨트롤러 상태(document/selection)는 replaceText 완료 전이므로 불일치가 생긴다.
    // 이 시점의 notifyListeners로 인한 spurious send(sel=old 등)를 차단한다.
    if (_processingIMEEvent) {
      return;
    }

    final value = textEditingValue;

    // Since we don't keep track of the composing range in value provided
    // by the Controller we need to add it here manually before comparing
    // with the last known remote value.
    // It is important to prevent excessive remote updates as it can cause
    // race conditions.
    final composingRange = _lastKnownRemoteTextEditingValue!.composing;
    final actualValue = value.copyWith(
      // Ignore last known composing range if it exceeds current text length.
      composing: composingRange.end > value.text.length ? null : composingRange,
    );

    if (actualValue == _lastKnownRemoteTextEditingValue) {
      return;
    }

    // During active IME composing, skip cursor-only corrections.
    // Sending setEditingState with composing=(-1,-1) while Samsung is mid-conversion
    // cancels its candidate selection. If only the selection changed (text is same),
    // the IME already knows where its cursor is within the composing range.
    if (composingRange.isValid &&
        actualValue.text == _lastKnownRemoteTextEditingValue!.text) {
      _dbg('[IME] updateRemote suppressed: cursor-only change during composing '
          '(would send sel=${actualValue.selection.baseOffset})');
      return;
    }

    _dbg('[IME] → platform (updateRemote): text="${actualValue.text.replaceAll('\n', '↵')}" '
        'sel=${actualValue.selection.baseOffset}..${actualValue.selection.extentOffset} '
        'composing=${actualValue.composing}');
    _lastKnownRemoteTextEditingValue = actualValue;
    _textInputConnection!.setEditingState(
      // Set composing to (-1, -1), otherwise an exception will be thrown if
      // the values are different.
      actualValue.copyWith(composing: const TextRange(start: -1, end: -1)),
    );
  }

  // Start TextInputClient implementation
  @override
  TextEditingValue? get currentTextEditingValue => _lastKnownRemoteTextEditingValue;

  // autofill is not needed
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (!shouldCreateInputConnection) {
      return;
    }

    _dbg('[IME] ← platform: text="${value.text.replaceAll('\n', '↵')}" '
        'composing=${value.composing} sel=${value.selection.baseOffset}..${value.selection.extentOffset} '
        '| prev: text="${_lastKnownRemoteTextEditingValue?.text.replaceAll('\n', '↵')}" '
        'composing=${_lastKnownRemoteTextEditingValue?.composing} '
        'sel=${_lastKnownRemoteTextEditingValue?.selection.baseOffset}..'
        '${_lastKnownRemoteTextEditingValue?.selection.extentOffset}');

    if (_lastKnownRemoteTextEditingValue == value) {
      _dbg('[IME] ← skip: identical');
      return;
    }

    // 텍스트와 선택 영역이 같고 composing만 변한 경우 무시
    // Check if only composing range changed.
    if (_lastKnownRemoteTextEditingValue!.text == value.text &&
        _lastKnownRemoteTextEditingValue!.selection == value.selection) {
      // This update only modifies composing range. Since we don't keep track
      // of composing range we just need to update last known value here.
      // This check fixes an issue on Android when it sends
      // composing updates separately from regular changes for text and
      // selection.
      _dbg('[IME] ← skip: composing-only change');
      _lastKnownRemoteTextEditingValue = value;
      return;
    }

    // 텍스트가 같고 이전 상태에서 composing이 활성이었던 경우: IME 내부 cursor 재배치 이벤트.
    // 일본어/삼성 IME는 candidate 목록 표시 전 cursor를 composing 시작 위치로 이동시키는데,
    // composing을 해제((-1,-1))하면서 sel만 바꾸는 이벤트도 포함된다.
    //
    // 이 이벤트를 Quill selection 변경으로 처리하면:
    //   1) cursor가 글자 앞으로 이동
    //   2) notifyListeners → updateRemoteValueIfNeeded가 이전 텍스트("かっこ")로
    //      spurious setEditingState를 전송 → Samsung이 텍스트 변경으로 인식해 전체 삭제 cascade
    //
    // stored는 갱신하지 않는다. 갱신하면 actual.sel ≠ stored.sel 불일치가 생겨
    // updateRemoteValueIfNeeded가 spurious send를 유발한다.
    if (_lastKnownRemoteTextEditingValue!.text == value.text &&
        _lastKnownRemoteTextEditingValue!.composing.isValid &&
        !_conversionPreviewActive) {
      _dbg('[IME] ← skip: IME cursor reposition (text same, prev composing active; '
          'new composing=${value.composing})');
      return;
    }
    _conversionPreviewActive = false;

    // [maxLength] IME(일본어 자동완성 등) 입력을 문서에 반영(diff 적용)하기 전에
    // 최대 길이를 강제한다. 여기서 잘라내면 문서·IME·플랫폼이 항상 같은 길이로
    // 동기되므로, 문서를 사후에 줄일 때 발생하던 offset desync 크래시가 없다.
    final maxLength = widget.controller.maxLength;
    if (maxLength > 0) {
      final capped = _capValueToMaxLength(value, maxLength);
      if (capped != value) {
        value = capped;
        // 플랫폼 IME 가 초과분을 유지/재주장하지 못하도록 capped 상태를 즉시 전송한다.
        if (hasConnection) {
          _textInputConnection!.setEditingState(value);
        }
        widget.controller.onMaxLengthExceeded?.call();
      }
    }

    // 이후 처리에서 _lastKnownRemoteTextEditingValue를 incoming value로 먼저 업데이트하고
    // replaceText/forceToggledStyle의 notifyListeners가 중간에 updateRemoteValueIfNeeded를
    // 호출하더라도 spurious send가 발생하지 않도록 플래그를 세운다.
    _processingIMEEvent = true;
    try {

    final effectiveLastKnownValue = _lastKnownRemoteTextEditingValue!;
    _lastKnownRemoteTextEditingValue = value;
    final oldText = effectiveLastKnownValue.text;
    final text = value.text;
    final cursorPosition = value.selection.extentOffset;

    // getDiff를 통해 변경 범위 계산
    final diff = getDiff(oldText, text, cursorPosition);

    if (diff.deleted.isEmpty && diff.inserted.isEmpty) {
      _dbg('[IME] ← selection-only: sel → ${value.selection.baseOffset}..${value.selection.extentOffset}');
      widget.controller.updateSelection(value.selection, ChangeSource.local);
    } else {
      // Android/iOS IME composing 중 toggledStyle 유실 방지:
      // toggledStyle은 selection 이벤트로 먼저 리셋될 수 있으므로,
      // pendingInlineStyle(더 안정적)을 우선 사용하고 toggledStyle을 fallback으로 쓴다.
      final effectiveStyle = widget.controller.pendingInlineStyle ??
          (widget.controller.toggledStyle.isNotEmpty ? widget.controller.toggledStyle : null);
      // composing.isValid뿐 아니라, 직전 상태에서 composing이 활성이었던 경우도 포함:
      // 한국어 IME에서 ㄱ→가 완성 시 최종 '가'가 composing 없이 전송될 수 있음.
      final wasComposing = effectiveLastKnownValue.composing.isValid;
      final composingStyle = ((value.composing.isValid || wasComposing) && effectiveStyle != null)
          ? effectiveStyle
          : null;

      // 삼성 일본어 IME 등은 かっこ→() 변환 시 커서를 괄호 뒤(offset=2)로 전송한다.
      // replaceText에 전달하기 전에 커서를 괄호 사이(start+1)로 조정한다.
      // 별도 updateSelection 호출을 피해 추가적인 notifyListeners 연쇄를 막는다.
      // 2자 괄호쌍이 단일 이벤트로 삽입된 경우는 항상 사이로 이동하는 것이 올바른 동작이므로
      // IME가 보낸 커서 위치에 관계없이 적용한다.
      final effectiveSelection = (diff.inserted.length == 2 &&
              _isBracketPair(diff.inserted) &&
              value.selection.isCollapsed)
          ? TextSelection.collapsed(offset: diff.start + 1)
          : value.selection;

      if (effectiveSelection != value.selection) {
        _dbg('[IME] bracket-pair detected "${diff.inserted}": cursor ${value.selection.extentOffset} → ${diff.start + 1}');
        // _lastKnownRemoteTextEditingValue도 조정된 sel로 갱신해 force-confirm이 올바른 sel을 쓰도록 한다.
        _lastKnownRemoteTextEditingValue = _lastKnownRemoteTextEditingValue!.copyWith(
          selection: effectiveSelection,
        );
      }

      _dbg('[mixin] diff="${diff.deleted}"→"${diff.inserted}" '
          'composing=${value.composing} wasComposing=$wasComposing '
          'pendingInlineStyle=${widget.controller.pendingInlineStyle} '
          'toggledStyle=${widget.controller.toggledStyle} '
          'effectiveStyle=$effectiveStyle composingStyle=$composingStyle');

      widget.controller.replaceText(
        diff.start,
        diff.deleted.length,
        diff.inserted,
        effectiveSelection,
      );

      if (composingStyle != null) {
        // replaceText 내부의 retain 로직이 위치별(cachedChar 기반)로 스타일을 이미 적용한다.
        // 여기서 formatText로 전체 범위에 다시 적용하면 앞 글자의 원래 서식을 덮어쓰므로 제거.
        // forceToggledStyle만 호출해 다음 IME 이벤트에서 toggledStyle 상태를 유지한다.
        widget.controller.forceToggledStyle(composingStyle);
      }

      // composing active 상태에서 텍스트 교체(変換プレビュー)가 발생한 경우,
      // 다음 이벤트에서 커서가 괄호 사이 등 최종 위치로 이동하는 별도 이벤트를 보낸다.
      // skip 조건(line 268)이 이 이벤트를 억제하지 않도록 플래그를 세운다.
      if (value.composing.isValid && diff.deleted.isNotEmpty && diff.inserted.isNotEmpty) {
        _conversionPreviewActive = true;
      }

      // 삼성 등 일부 IME는 변환 확정 후에도 내부적으로 composing 세션을 유지한다.
      // 다음 입력 시 변환 전 소스를 기반으로 새 composing을 확장해 오동작을 일으킨다.
      // setEditingState를 명시적으로 전송해 Android IME의 composing span을 해제한다.
      //
      // 아래 두 경우에 force-confirm을 전송한다:
      //   1. 기존: wasComposing 상태에서 텍스트 교체(かっこ→() 등)
      //   2. 추가: 括弧쌍 삽입 — wasComposing 없이 후보목록에서 ()를 직접 선택해도
      //            Samsung은 내부 composing span을 유지해 다음 입력으로 괄호를 교체한다.
      final isBracketPairInserted =
          diff.inserted.length == 2 && _isBracketPair(diff.inserted);
      if (hasConnection &&
          !value.composing.isValid &&
          ((wasComposing && diff.deleted.isNotEmpty && diff.inserted.isNotEmpty) ||
              isBracketPairInserted)) {
        final confirmedValue = textEditingValue.copyWith(
          composing: const TextRange(start: -1, end: -1),
        );
        _dbg('[IME] → platform (force-confirm): text="${confirmedValue.text.replaceAll('\n', '↵')}" '
            'sel=${confirmedValue.selection.baseOffset}..${confirmedValue.selection.extentOffset}');
        _lastKnownRemoteTextEditingValue = confirmedValue;
        _textInputConnection!.setEditingState(confirmedValue);
      }
    }

    } finally {
      _processingIMEEvent = false;
    }
  }

  /// [value] 의 텍스트를 grapheme(이모지 안전) 기준 [maxLength] 까지 자른 새 값을
  /// 반환한다. '\n' 은 길이에서 제외한다. 한도 이내이면 [value] 를 그대로 반환한다.
  /// 잘린 경우 커서를 끝으로 두고 composing 을 비운다.
  TextEditingValue _capValueToMaxLength(TextEditingValue value, int maxLength) {
    final text = value.text;
    var count = 0;
    var cutIndex = text.length;
    var pos = 0;
    for (final gc in text.characters) {
      if (gc != '\n') {
        if (count >= maxLength) {
          cutIndex = pos;
          break;
        }
        count++;
      }
      pos += gc.length;
    }
    if (cutIndex >= text.length) return value; // 한도 이내
    final newText = text.substring(0, cutIndex);
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
      composing: TextRange.empty,
    );
  }

  @override
  void performAction(TextInputAction action) {
    widget.config.onPerformAction?.call(action);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // no-op
  }

  // The time it takes for the floating cursor to snap to the text aligned
  // cursor position after the user has finished placing it.
  static const Duration _floatingCursorResetTime = Duration(milliseconds: 125);

  // The original position of the caret on FloatingCursorDragState.start.
  Rect? _startCaretRect;

  // The most recent text position as determined by the location of the floating
  // cursor.
  TextPosition? _lastTextPosition;

  // The offset of the floating cursor as determined from the start call.
  Offset? _pointOffsetOrigin;

  // The most recent position of the floating cursor.
  Offset? _lastBoundedOffset;

  // Because the center of the cursor is preferredLineHeight / 2 below the touch
  // origin, but the touch origin is used to determine which line the cursor is
  // on, we need this offset to correctly render and move the cursor.
  Offset _floatingCursorOffset(TextPosition textPosition) =>
      Offset(0, renderEditor.preferredLineHeight(textPosition) / 2);

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    switch (point.state) {
      case FloatingCursorDragState.Start:
        if (floatingCursorResetController.isAnimating) {
          floatingCursorResetController.stop();
          onFloatingCursorResetTick();
        }
        // We want to send in points that are centered around a (0,0) origin, so
        // we cache the position.
        _pointOffsetOrigin = point.offset;

        final currentTextPosition = TextPosition(offset: renderEditor.selection.baseOffset);
        _startCaretRect = renderEditor.getLocalRectForCaret(currentTextPosition);

        _lastBoundedOffset = _startCaretRect!.center - _floatingCursorOffset(currentTextPosition);
        _lastTextPosition = currentTextPosition;
        renderEditor.setFloatingCursor(point.state, _lastBoundedOffset!, _lastTextPosition!);
        break;
      case FloatingCursorDragState.Update:
        assert(_lastTextPosition != null, 'Last text position was not set');
        final floatingCursorOffset = _floatingCursorOffset(_lastTextPosition!);
        final centeredPoint = point.offset! - _pointOffsetOrigin!;
        final rawCursorOffset = _startCaretRect!.center + centeredPoint - floatingCursorOffset;

        final preferredLineHeight = renderEditor.preferredLineHeight(_lastTextPosition!);
        _lastBoundedOffset = renderEditor.calculateBoundedFloatingCursorOffset(
          rawCursorOffset,
          preferredLineHeight,
        );
        _lastTextPosition =
            renderEditor.getPositionForOffset(renderEditor.localToGlobal(_lastBoundedOffset! + floatingCursorOffset));
        renderEditor.setFloatingCursor(point.state, _lastBoundedOffset!, _lastTextPosition!);
        final newSelection =
            TextSelection.collapsed(offset: _lastTextPosition!.offset, affinity: _lastTextPosition!.affinity);
        // Setting selection as floating cursor moves will have scroll view
        // bring background cursor into view
        renderEditor.onSelectionChanged(newSelection, SelectionChangedCause.forcePress);
        break;
      case FloatingCursorDragState.End:
        // We skip animation if no update has happened.
        if (_lastTextPosition != null && _lastBoundedOffset != null) {
          floatingCursorResetController
            ..value = 0.0
            ..animateTo(1, duration: _floatingCursorResetTime, curve: Curves.decelerate);
        }
        break;
    }
  }

  /// Specifies the floating cursor dimensions and position based
  /// the animation controller value.
  /// The floating cursor is resized
  /// (see [RenderAbstractEditor.setFloatingCursor])
  /// and repositioned (linear interpolation between position of floating cursor
  /// and current position of background cursor)
  void onFloatingCursorResetTick() {
    final finalPosition =
        renderEditor.getLocalRectForCaret(_lastTextPosition!).centerLeft - _floatingCursorOffset(_lastTextPosition!);
    if (floatingCursorResetController.isCompleted) {
      renderEditor.setFloatingCursor(FloatingCursorDragState.End, finalPosition, _lastTextPosition!);
      _startCaretRect = null;
      _lastTextPosition = null;
      _pointOffsetOrigin = null;
      _lastBoundedOffset = null;
    } else {
      final lerpValue = floatingCursorResetController.value;
      final lerpX = lerpDouble(_lastBoundedOffset!.dx, finalPosition.dx, lerpValue)!;
      final lerpY = lerpDouble(_lastBoundedOffset!.dy, finalPosition.dy, lerpValue)!;

      renderEditor.setFloatingCursor(FloatingCursorDragState.Update, Offset(lerpX, lerpY), _lastTextPosition!,
          resetLerpValue: lerpValue);
    }
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // this is called VERY OFTEN when editing a document, no longer throw
    // an exception
  }

  @override
  bool onFocusReceived() {
    if (mounted && !widget.config.focusNode.hasFocus && widget.config.focusNode.canRequestFocus) {
      widget.config.focusNode.requestFocus();
      return true;
    }
    return false;
  }

  @override
  void connectionClosed() {
    if (!hasConnection) {
      return;
    }
    _textInputConnection!.connectionClosedReceived();
    _textInputConnection = null;
    _lastKnownRemoteTextEditingValue = null;
  }

  void _updateSizeAndTransform() {
    if (hasConnection) {
      // Asking for renderEditor.size here can cause errors if layout hasn't
      // occurred yet. So we schedule a post frame callback instead.
      final size = renderEditor.size;
      final transform = renderEditor.getTransformTo(null);
      _textInputConnection?.setEditableSizeAndTransform(size, transform);
      SchedulerBinding.instance.addPostFrameCallback((_) => _updateSizeAndTransform());
    }
  }

  static const Map<String, String> _bracketPairs = {
    '(': ')', '[': ']', '{': '}',
    '（': '）', '「': '」', '『': '』',
    '【': '】', '《': '》', '〈': '〉',
    '〔': '〕', '［': '］', '｛': '｝',
    '｢': '｣', // halfwidth corner brackets (Samsung IME sends these for かぎかっこ)
  };

  static bool _isBracketPair(String s) =>
      s.length == 2 && _bracketPairs[s[0]] == s[1];
}

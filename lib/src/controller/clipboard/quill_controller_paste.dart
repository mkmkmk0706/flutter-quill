@internal
library;

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../../../flutter_quill.dart';
import '../../../quill_delta.dart';
import 'quill_controller_rich_paste.dart';

extension QuillControllerPaste on QuillController {
  @internal
  Future<bool> pastePlainTextOrDelta(
    String? clipboardText, {
    required String pastePlainText,
    required Delta pasteDelta,
  }) async {
    if (clipboardText != null) {
      /// Internal copy-paste preserves styles and embeds
      if (clipboardText == pastePlainText && pastePlainText.isNotEmpty && pasteDelta.isNotEmpty) {
        replaceText(
            selection.start,
            selection.end - selection.start,
            // [Fix] onRichTextPaste
            // pasteDelta,
            await getDeltaToPaste(pasteDelta, isExternal: false),
            TextSelection.collapsed(offset: selection.end));
      } else {
        replaceText(selection.start, selection.end - selection.start, clipboardText,
            TextSelection.collapsed(offset: selection.end + clipboardText.length));
      }
      return true;
    }
    return false;
  }

  Future<String> getTextToPaste(String clipboardPlainText) async {
    final onPlainTextPaste = config.clipboardConfig?.onPlainTextPaste;
    if (onPlainTextPaste != null) {
      final plainText = await onPlainTextPaste(clipboardPlainText);
      if (plainText != null) {
        return plainText;
      }
    }
    return clipboardPlainText;
  }
}

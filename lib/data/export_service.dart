import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// Hands a generated file to the platform: the native share sheet on Android
/// and iOS, and on web `navigator.share` with an automatic download fallback.
class ExportService {
  const ExportService();

  Future<void> shareText({
    required String filename,
    required String contents,
    required String mimeType,
    Rect? originRect,
  }) async {
    final file = XFile.fromData(
      utf8.encode(contents),
      mimeType: mimeType,
      name: filename,
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [file],
        fileNameOverrides: [filename],
        subject: filename,
        // iPad and macOS anchor the popover to whatever the user tapped.
        sharePositionOrigin: originRect,
      ),
    );
  }
}

/// The rect of the widget that triggered a share, in global coordinates.
/// iPadOS throws without one; every other platform ignores it.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

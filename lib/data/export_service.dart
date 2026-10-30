import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'browser_download.dart';

/// Hands a generated file to the platform.
///
/// Two intents, kept apart on purpose:
///
/// * [shareText] / [shareBytes] SAVE the file. In a browser that is a straight
///   download to Downloads. On Android and iOS there is no Downloads folder an
///   app can write to, so it opens the share sheet, which carries "Save to
///   Files" and the like.
/// * [shareBytesWithApps] offers the file to other apps through the system
///   share sheet, everywhere. Only the explicit "Share" option uses it.
///
/// These used to be one path, through share_plus, which in a browser opens
/// the system share sheet whenever one exists. Chrome and Safari on macOS have
/// one, and it cannot save a file, so "Download PDF" and every CSV export
/// opened a menu of Mail and Messages and saved nothing.
class ExportService {
  const ExportService();

  Future<void> shareText({
    required String filename,
    required String contents,
    required String mimeType,
    Rect? originRect,
  }) => shareBytes(
    filename: filename,
    bytes: Uint8List.fromList(utf8.encode(contents)),
    mimeType: mimeType,
    originRect: originRect,
  );

  /// Saves a file that is not text — a generated PDF or spreadsheet.
  Future<void> shareBytes({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
    Rect? originRect,
  }) async {
    if (canDownloadInBrowser) {
      await downloadInBrowser(
        bytes: bytes,
        filename: filename,
        mimeType: mimeType,
      );
      return;
    }
    await shareBytesWithApps(
      filename: filename,
      bytes: bytes,
      mimeType: mimeType,
      originRect: originRect,
    );
  }

  /// Offers the file to other apps through the system share sheet. Where a
  /// browser has no share sheet, share_plus downloads it instead.
  Future<void> shareBytesWithApps({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
    Rect? originRect,
  }) {
    return SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: mimeType, name: filename)],
        fileNameOverrides: [filename],
        subject: filename,
        // iPad and macOS anchor the popover to whatever the user tapped.
        sharePositionOrigin: originRect,
      ),
    );
  }
}

/// What became of a file handed to [ExportService.shareFile].
enum FileShareOutcome {
  /// Given to the system share sheet.
  shared,

  /// The sheet was closed without choosing anywhere.
  dismissed,

  /// This browser cannot share files, so it was downloaded instead.
  downloaded,
}

extension FileSharing on ExportService {
  /// Shares the FILE — the same PDF that Download saves — never a text
  /// message about it. Where the browser cannot share files, downloads it.
  ///
  /// Call it as soon after the tap as possible: a browser only allows a share
  /// while the tap is recent, which is why callers build the file in advance.
  Future<FileShareOutcome> shareFile({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
    Rect? originRect,
  }) async {
    if (canDownloadInBrowser &&
        !canShareFilesInBrowser(
          bytes: bytes,
          filename: filename,
          mimeType: mimeType,
        )) {
      await downloadInBrowser(
        bytes: bytes,
        filename: filename,
        mimeType: mimeType,
      );
      return FileShareOutcome.downloaded;
    }
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: mimeType, name: filename)],
        fileNameOverrides: [filename],
        sharePositionOrigin: originRect,
      ),
    );
    return result.status == ShareResultStatus.dismissed
        ? FileShareOutcome.dismissed
        : FileShareOutcome.shared;
  }
}

/// The rect of the widget that triggered a share, in global coordinates.
/// iPadOS throws without one; every other platform ignores it.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

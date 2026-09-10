import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';

/// Why a chosen file could not be used as a logo.
enum LogoProblem {
  /// Over [LogoService.maxBytes].
  tooLarge,

  /// Not a PNG or a JPEG, whatever the file was called.
  unsupportedFormat,

  /// The bytes claim to be an image but no decoder would take them.
  unreadable,
}

/// The outcome of choosing a logo.
sealed class LogoResult {
  const LogoResult();
}

/// A validated, downscaled logo, base64-encoded and ready to store.
class LogoAccepted extends LogoResult {
  const LogoAccepted({
    required this.encoded,
    required this.width,
    required this.height,
    required this.originalBytes,
    required this.storedBytes,
  });

  final String encoded;
  final int width;
  final int height;

  /// What the user picked, and what is actually being kept — the difference
  /// is worth showing, because it is usually an order of magnitude.
  final int originalBytes;
  final int storedBytes;
}

/// Rejected, with a sentence that can go straight on screen.
class LogoRejected extends LogoResult {
  const LogoRejected(this.problem, this.message);

  final LogoProblem problem;
  final String message;
}

/// The picker was dismissed.
class LogoCancelled extends LogoResult {
  const LogoCancelled();
}

/// Picks, validates and normalises a company logo.
///
/// Validation is done on the **bytes**, not on the file name. A file-type
/// filter in the picker is a convenience for the user, not a guarantee: it is
/// trivially bypassed by renaming, and on some platforms it is only a hint. So
/// the signature is checked here, and the size is measured rather than taken
/// from whatever metadata the platform offered.
class LogoService {
  const LogoService();

  /// 5 MB, measured against the file the user chose.
  static const int maxBytes = 5 * 1024 * 1024;

  /// What the picker offers and what the signature check accepts. Kept in one
  /// place so the two cannot drift apart.
  static const List<String> allowedExtensions = ['jpg', 'jpeg', 'png'];

  /// Longest edge kept after downscaling.
  ///
  /// A letterhead prints the logo about 120pt wide, so 512px is already
  /// generous at print resolution — and the encoded image lives inline in the
  /// settings row, which is not the place for a two-megapixel original.
  static const int maxEdge = 512;

  Future<LogoResult> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (file == null) return const LogoCancelled();

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return const LogoRejected(
        LogoProblem.unreadable,
        'That file could not be read. Try choosing it again.',
      );
    }

    return validate(bytes);
  }

  /// The validation and normalisation half, without the picker.
  ///
  /// Separate so it can be tested against real bytes rather than mocked out.
  Future<LogoResult> validate(Uint8List bytes) async {
    if (bytes.length > maxBytes) {
      return LogoRejected(
        LogoProblem.tooLarge,
        'That image is ${formatBytes(bytes.length)}. The largest a logo can '
        'be is ${formatBytes(maxBytes)} — try a smaller file.',
      );
    }
    if (bytes.isEmpty) {
      return const LogoRejected(LogoProblem.unreadable, 'That file is empty.');
    }

    final format = detectFormat(bytes);
    if (format == null) {
      return const LogoRejected(
        LogoProblem.unsupportedFormat,
        'Logos must be a JPEG or a PNG. That file is neither, whatever its '
        'name says.',
      );
    }

    try {
      return await _normalise(bytes);
    } catch (_) {
      return const LogoRejected(
        LogoProblem.unreadable,
        'That image could not be opened. It may be damaged — try exporting it '
        'again.',
      );
    }
  }

  /// Downscales to [maxEdge] and re-encodes as PNG.
  ///
  /// PNG rather than keeping the original: a logo usually has a transparent
  /// background, and JPEG cannot carry one — it would come out with a white
  /// box around it on the letterhead.
  Future<LogoResult> _normalise(Uint8List bytes) async {
    // Decoded once at full size purely to learn the aspect, so the scale is
    // applied to whichever edge is actually the longer one. Targeting width
    // unconditionally would leave a tall, narrow logo far bigger than asked.
    final probe = await ui.instantiateImageCodec(bytes);
    final probeFrame = await probe.getNextFrame();
    final sourceWidth = probeFrame.image.width;
    final sourceHeight = probeFrame.image.height;
    probeFrame.image.dispose();
    probe.dispose();

    if (sourceWidth == 0 || sourceHeight == 0) {
      return const LogoRejected(
        LogoProblem.unreadable,
        'That image has no dimensions.',
      );
    }

    final longest = sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
    final codec = longest <= maxEdge
        ? await ui.instantiateImageCodec(bytes)
        : await ui.instantiateImageCodec(
            bytes,
            targetWidth: sourceWidth >= sourceHeight ? maxEdge : null,
            targetHeight: sourceHeight > sourceWidth ? maxEdge : null,
          );

    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final width = image.width;
    final height = image.height;
    image.dispose();
    codec.dispose();

    final encoded = data?.buffer.asUint8List();
    if (encoded == null) {
      return const LogoRejected(
        LogoProblem.unreadable,
        'That image could not be converted.',
      );
    }

    return LogoAccepted(
      encoded: base64Encode(encoded),
      width: width,
      height: height,
      originalBytes: bytes.length,
      storedBytes: encoded.length,
    );
  }

  /// The file's real format, from its signature, or null if it is neither.
  ///
  /// Eight bytes for PNG's full magic number and three for JPEG's
  /// start-of-image marker — enough to be sure without decoding.
  static String? detectFormat(Uint8List bytes) {
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length >= png.length) {
      var matches = true;
      for (var i = 0; i < png.length; i++) {
        if (bytes[i] != png[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return 'png';
    }

    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpeg';
    }

    return null;
  }
}

/// Byte counts as a person would say them.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

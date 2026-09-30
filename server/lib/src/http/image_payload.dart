import 'dart:convert';
import 'dart:typed_data';

import 'api_error.dart';

/// The most a single stored image may decode to.
///
/// The client already downscales to well under this; the cap is here because
/// the client is the half an attacker skips.
const maxImageBytes = 5 * 1024 * 1024;

/// Checks that a stored image really is one.
///
/// ITEM PHOTOS AND THE COMPANY LOGO ARE KEPT AS BARE BASE64 ON THE ROW, and
/// nothing on the server ever looked at what was inside. The field accepted
/// any string up to the body limit, which made it an arbitrary data store
/// sitting inside the business record — five megabytes per item, writable by
/// anyone who can edit an item, never inspected, and carried into every
/// backup. The logo screen does sniff magic bytes, but that is the client, and
/// the client is precisely what a forged request does not run.
///
/// Checked by MAGIC BYTES rather than by a declared type, because the
/// declaration is attacker-controlled and the bytes are the thing that later
/// gets decoded into an image widget and embedded in a PDF. SVG fails this by
/// construction — it is XML, has no magic number, and is the one image format
/// that can carry script — which is the outcome wanted.
///
/// Returns the value unchanged when it is acceptable. An absent field is not
/// this function's business; an empty one means "no picture" and is allowed,
/// because that is how a photo is removed.
String validatedImage(Object? raw, {required String field}) {
  if (raw == null) return '';
  if (raw is! String) {
    throw ApiError.badRequest('$field must be a base64 image.');
  }

  final value = raw.trim();
  if (value.isEmpty) return '';

  // A data URI is not what this app stores, but it is what a hand-written
  // client would most likely send, so the prefix is stripped rather than
  // rejected — the bytes behind it still have to pass.
  final payload = value.startsWith('data:')
      ? value.substring(value.indexOf(',') + 1)
      : value;

  final Uint8List bytes;
  try {
    bytes = base64Decode(payload);
  } on FormatException {
    throw ApiError.badRequest('$field is not valid base64.');
  }

  if (bytes.length > maxImageBytes) {
    final mb = (maxImageBytes / (1024 * 1024)).round();
    throw ApiError.badRequest('$field is larger than ${mb}MB.');
  }

  if (!_looksLikeImage(bytes)) {
    throw ApiError.badRequest(
      '$field is not an image this app can read. PNG, JPEG, GIF and WebP '
      'are accepted.',
    );
  }

  return value;
}

/// Whether [bytes] open with the signature of a format we can actually render.
bool _looksLikeImage(Uint8List bytes) =>
    _startsWith(bytes, _png) ||
    _startsWith(bytes, _jpeg) ||
    _startsWith(bytes, _gif87) ||
    _startsWith(bytes, _gif89) ||
    _isWebp(bytes);

// The eight-byte PNG signature, deliberately including the CR/LF pair that
// catches a file mangled by an ASCII-mode transfer.
const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

// SOI plus the first marker byte. Every JPEG variant starts this way.
const _jpeg = [0xFF, 0xD8, 0xFF];

const _gif87 = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61];
const _gif89 = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];

/// RIFF....WEBP — the size sits between the two tags, so this is two checks.
bool _isWebp(Uint8List bytes) {
  if (bytes.length < 12) return false;
  const riff = [0x52, 0x49, 0x46, 0x46];
  const webp = [0x57, 0x45, 0x42, 0x50];
  for (var i = 0; i < 4; i++) {
    if (bytes[i] != riff[i]) return false;
    if (bytes[8 + i] != webp[i]) return false;
  }
  return true;
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}

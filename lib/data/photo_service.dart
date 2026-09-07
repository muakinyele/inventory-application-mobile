import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

/// Captures or picks a photo and downscales it before it is stored.
///
/// Item photos live inline in the JSON database, so a full-resolution camera
/// frame would blow the storage quota after a handful of items.
class PhotoService {
  const PhotoService();

  static const _maxEdge = 640;

  Future<String?> pick(ImageSource source) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: source,
      maxWidth: _maxEdge.toDouble(),
      maxHeight: _maxEdge.toDouble(),
      imageQuality: 80,
    );
    if (file == null) return null;
    return _encode(await file.readAsBytes());
  }

  /// `image_picker` ignores maxWidth/imageQuality on web, so re-encode here
  /// to keep the stored payload small on every platform.
  Future<String> _encode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: _maxEdge);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();

    // If PNG re-encoding somehow grew the file, keep the smaller original.
    final encoded = data?.buffer.asUint8List();
    if (encoded == null || encoded.length > bytes.length) {
      return base64Encode(bytes);
    }
    return base64Encode(encoded);
  }
}

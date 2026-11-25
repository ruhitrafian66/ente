// Offline fork: image decode for the picture check of the "Compress images"
// tool. Only dart:ui, so that a test can run it.

import "dart:typed_data";
import "dart:ui" as ui;

import "package:photos/services/image_compress_core.dart";

/// Decodes an encoded image to upright 8-bit RGBA. The engine applies the
/// EXIF orientation and decodes on its own worker threads. Returns null when
/// the image has more than [maxPixels] pixels or cannot be decoded.
Future<DecodedRgba?> decodeUprightRgba(
  ui.ImmutableBuffer buffer, {
  required int maxPixels,
}) async {
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width * descriptor.height > maxPixels) return null;
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return DecodedRgba(
      rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      width: image.width,
      height: image.height,
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<DecodedRgba?> decodeUprightRgbaFromBytes(
  Uint8List bytes, {
  required int maxPixels,
}) async {
  return decodeUprightRgba(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    maxPixels: maxPixels,
  );
}

Future<DecodedRgba?> decodeUprightRgbaFromPath(
  String path, {
  required int maxPixels,
}) async {
  return decodeUprightRgba(
    await ui.ImmutableBuffer.fromFilePath(path),
    maxPixels: maxPixels,
  );
}

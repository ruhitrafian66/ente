// Offline fork: PNG and JPEG helper functions (PNG header, transparency,
// JPEG dimensions, capture-time EXIF, output names).
//
// The "Compress images" tool (image_compress_core.dart) uses these helpers.
// The separate "Convert PNG to JPG" tool was merged into that tool on
// 2026-11-25: its screens and its device service are gone, and the
// [PngToJpgConverter] state machine below has no caller in the app any more.
// It stays with its unit tests until someone removes both together.
//
// This file must stay free of Flutter, plugin and app imports so that the unit
// tests can run it in isolation.

import "dart:typed_data";

import "package:image/image.dart" as img;
import "package:path/path.dart" as p;

/// Default JPEG quality, and the values the page offers.
const int kPngToJpgDefaultQuality = 90;
const List<int> kPngToJpgQualityOptions = [80, 90, 95];

/// A JPEG is kept only if it is at least this much smaller than the PNG.
const double kPngToJpgMinSavingFraction = 0.10;

/// How many bytes of a PNG are read to inspect the chunks before the pixels.
const int kPngHeaderPrefixBytes = 256 * 1024;

const List<int> _pngSignature = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

// ---------------------------------------------------------------------------
// PNG detection
// ---------------------------------------------------------------------------

bool hasPngSignature(Uint8List bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

bool hasPngExtension(String? title) {
  if (title == null) return false;
  return p.extension(title).toLowerCase() == ".png";
}

/// Cheap pre-filter from what the media library exposes. A reported mime type
/// wins over the file name. The real format is confirmed later from the file
/// signature ([parsePngHeader]).
bool looksLikePng({String? title, String? mimeType}) {
  final mime = mimeType?.trim().toLowerCase();
  if (mime != null && mime.isNotEmpty) {
    return mime == "image/png";
  }
  return hasPngExtension(title);
}

/// What the chunks before the first IDAT say about a PNG.
class PngHeaderInfo {
  final int width;
  final int height;
  final int bitDepth;

  /// 0 grey, 2 RGB, 3 palette, 4 grey + alpha, 6 RGBA.
  final int colorType;
  final bool hasTrns;
  final bool hasIccProfile;

  /// APNG. A conversion would keep only the first frame.
  final bool isAnimated;

  /// False when the inspected prefix ended before the first IDAT chunk, so a
  /// tRNS / iCCP / acTL chunk could have been missed.
  final bool sawAllHeaderChunks;

  const PngHeaderInfo({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.hasTrns,
    required this.hasIccProfile,
    required this.isAnimated,
    required this.sawAllHeaderChunks,
  });

  bool get hasAlphaChannel => colorType == 4 || colorType == 6;

  /// True when the pixels must be inspected to know if the image is opaque.
  /// Unknown is treated as "may have alpha".
  bool get mayHaveTransparency =>
      hasAlphaChannel || hasTrns || !sawAllHeaderChunks;

  bool get is16Bit => bitDepth == 16;
}

/// Parses a PNG (or a prefix of one). Returns null if [bytes] is not a PNG.
PngHeaderInfo? parsePngHeader(Uint8List bytes) {
  if (!hasPngSignature(bytes)) return null;
  final data = ByteData.sublistView(bytes);
  var offset = 8;
  int? width, height, bitDepth, colorType;
  var hasTrns = false;
  var hasIcc = false;
  var isAnimated = false;
  var sawIdat = false;

  while (offset + 8 <= bytes.length) {
    final length = data.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    final dataStart = offset + 8;
    if (type == "IHDR") {
      if (length < 13 || dataStart + 13 > bytes.length) return null;
      width = data.getUint32(dataStart);
      height = data.getUint32(dataStart + 4);
      bitDepth = bytes[dataStart + 8];
      colorType = bytes[dataStart + 9];
    } else if (type == "tRNS") {
      hasTrns = true;
    } else if (type == "iCCP") {
      hasIcc = true;
    } else if (type == "acTL") {
      isAnimated = true;
    } else if (type == "IDAT" || type == "IEND") {
      sawIdat = true;
      break;
    }
    // length + type + data + crc
    offset = dataStart + length + 4;
  }

  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return PngHeaderInfo(
    width: width,
    height: height,
    bitDepth: bitDepth!,
    colorType: colorType!,
    hasTrns: hasTrns,
    hasIccProfile: hasIcc,
    isAnimated: isAnimated,
    sawAllHeaderChunks: sawIdat,
  );
}

// ---------------------------------------------------------------------------
// Alpha detection
// ---------------------------------------------------------------------------

/// True if any pixel of an 8-bit RGBA buffer (R, G, B, A byte order) is not
/// fully opaque. Works for straight and for premultiplied alpha.
bool rgbaHasTransparency(Uint8List rgba) {
  final pixelCount = rgba.length ~/ 4;
  if (rgba.offsetInBytes % 4 == 0 && Endian.host == Endian.little) {
    final words = rgba.buffer.asUint32List(rgba.offsetInBytes, pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      if (words[i] < 0xFF000000) return true;
    }
    return false;
  }
  for (var i = 3; i < pixelCount * 4; i += 4) {
    if (rgba[i] != 0xFF) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Size rules and estimate
// ---------------------------------------------------------------------------

/// The "keep only if smaller" rule.
bool isJpegWorthKeeping({
  required int pngBytes,
  required int jpegBytes,
  double minSavingFraction = kPngToJpgMinSavingFraction,
}) {
  if (pngBytes <= 0 || jpegBytes <= 0) return false;
  return jpegBytes <= pngBytes * (1 - minSavingFraction);
}

/// Rough JPEG size from the pixel count. The bits-per-pixel values are typical
/// for screenshots; real results change a lot with the content.
int estimateJpegBytes({
  required int width,
  required int height,
  required int quality,
}) {
  final double bitsPerPixel;
  if (quality >= 95) {
    bitsPerPixel = 2.2;
  } else if (quality >= 90) {
    bitsPerPixel = 1.4;
  } else {
    bitsPerPixel = 0.9;
  }
  return (width * height * bitsPerPixel / 8).round();
}

/// Rough saving for one PNG. Zero when the rule in [isJpegWorthKeeping] would
/// probably reject the result.
int estimateSavingBytes({
  required int pngBytes,
  required int width,
  required int height,
  required int quality,
}) {
  if (width <= 0 || height <= 0) return pngBytes ~/ 2;
  final jpegBytes = estimateJpegBytes(
    width: width,
    height: height,
    quality: quality,
  );
  if (!isJpegWorthKeeping(pngBytes: pngBytes, jpegBytes: jpegBytes)) return 0;
  return pngBytes - jpegBytes;
}

// ---------------------------------------------------------------------------
// Output naming
// ---------------------------------------------------------------------------

const Set<String> _imageExtensions = {
  ".png",
  ".jpg",
  ".jpeg",
  ".jpe",
  ".jfif",
  ".webp",
  ".heic",
  ".gif",
  ".bmp",
};

/// "Screenshot_1.png" -> "Screenshot_1.jpg". A PNG with a wrong extension
/// ("photo.jpg") also gives "photo.jpg"; [pickJpgName] then adds a counter,
/// because the original still has that name.
String jpgNameForPng(String pngTitle) {
  final base = _imageExtensions.contains(p.extension(pngTitle).toLowerCase())
      ? p.basenameWithoutExtension(pngTitle)
      : pngTitle;
  return "${base.isEmpty ? "image" : base}.jpg";
}

/// Picks "name.jpg", or "name (1).jpg", "name (2).jpg", ... when the name is
/// already used in the folder.
Future<String> pickJpgName(
  String pngTitle,
  Future<bool> Function(String name) isTaken,
) async {
  final first = jpgNameForPng(pngTitle);
  if (!await isTaken(first)) return first;
  final base = p.basenameWithoutExtension(first);
  for (var i = 1; i < 1000; i++) {
    final name = "$base ($i).jpg";
    if (!await isTaken(name)) return name;
  }
  throw StateError("No free file name for $pngTitle");
}

// ---------------------------------------------------------------------------
// JPEG helpers
// ---------------------------------------------------------------------------

typedef ImageDimensions = ({int width, int height});

/// Reads the dimensions from the start-of-frame marker of a JPEG.
ImageDimensions? parseJpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) return null;
    final marker = bytes[offset + 1];
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 1) {
      offset += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null;
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) return null;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (offset + 9 > bytes.length) return null;
      final height = (bytes[offset + 5] << 8) | bytes[offset + 6];
      final width = (bytes[offset + 7] << 8) | bytes[offset + 8];
      if (width == 0 || height == 0) return null;
      return (width: width, height: height);
    }
    offset += 2 + length;
  }
  return null;
}

String _two(int v) => v.toString().padLeft(2, "0");

/// "2024:03:09 18:05:42", the EXIF date format, in the time zone of [time].
String exifDateTimeString(DateTime time) {
  return "${time.year.toString().padLeft(4, "0")}:${_two(time.month)}:"
      "${_two(time.day)} ${_two(time.hour)}:${_two(time.minute)}:"
      "${_two(time.second)}";
}

/// "+05:30", the EXIF OffsetTime format.
String exifOffsetString(Duration offset) {
  final sign = offset.isNegative ? "-" : "+";
  final minutes = offset.inMinutes.abs();
  return "$sign${_two(minutes ~/ 60)}:${_two(minutes % 60)}";
}

/// Returns a copy of [jpeg] with an EXIF block that carries [captureTime] as
/// DateTimeOriginal / DateTimeDigitized / DateTime plus the matching offset
/// tags. The pixel data is not touched. Returns null if [jpeg] is not a JPEG.
Uint8List? jpegWithCaptureTime(Uint8List jpeg, DateTime captureTime) {
  final local = captureTime.toLocal();
  final dateTime = exifDateTimeString(local);
  final offset = exifOffsetString(local.timeZoneOffset);
  final exif = img.ExifData();
  exif.imageIfd[0x0132] = img.IfdValueAscii(dateTime); // DateTime
  exif.exifIfd[0x9003] = img.IfdValueAscii(dateTime); // DateTimeOriginal
  exif.exifIfd[0x9004] = img.IfdValueAscii(dateTime); // DateTimeDigitized
  exif.exifIfd[0x9010] = img.IfdValueAscii(offset); // OffsetTime
  exif.exifIfd[0x9011] = img.IfdValueAscii(offset); // OffsetTimeOriginal
  exif.exifIfd[0x9012] = img.IfdValueAscii(offset); // OffsetTimeDigitized
  return img.injectJpgExif(jpeg, exif);
}

// ---------------------------------------------------------------------------
// Conversion state machine
// ---------------------------------------------------------------------------

/// One PNG on the device.
class PngCandidate {
  /// Media library id (`EnteFile.localID`).
  final String id;
  final String title;

  /// Absolute path of the PNG.
  final String path;
  final int sizeBytes;
  final int width;
  final int height;
  final DateTime captureTime;

  /// MediaStore RELATIVE_PATH of the folder, for example "DCIM/Screenshots/".
  final String? relativePath;

  const PngCandidate({
    required this.id,
    required this.title,
    required this.path,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.captureTime,
    required this.relativePath,
  });
}

/// A JPEG that the tool wrote to the media library.
class SavedJpeg {
  final String id;
  final String path;
  final String name;

  const SavedJpeg({required this.id, required this.path, required this.name});
}

enum PngConversionStatus {
  /// JPEG saved and verified, PNG removed.
  converted,

  /// JPEG saved and verified, but the device did not remove the PNG (for
  /// example the user denied the system prompt). Both files exist.
  originalKept,

  /// The JPEG that was written for an [originalKept] file was removed again.
  rolledBack,
  skippedTransparency,
  skippedNoSaving,
  skippedAnimated,
  skippedNotPng,
  failed,
}

class PngConversionResult {
  final PngCandidate candidate;
  final PngConversionStatus status;
  final int jpegBytes;
  final SavedJpeg? saved;
  final String? message;

  /// The PNG had an ICC profile. The JPEG has none.
  final bool droppedIccProfile;

  const PngConversionResult({
    required this.candidate,
    required this.status,
    this.jpegBytes = 0,
    this.saved,
    this.message,
    this.droppedIccProfile = false,
  });

  PngConversionResult withStatus(PngConversionStatus status) {
    return PngConversionResult(
      candidate: candidate,
      status: status,
      jpegBytes: jpegBytes,
      saved: saved,
      message: message,
      droppedIccProfile: droppedIccProfile,
    );
  }

  int get savedBytes => status == PngConversionStatus.converted
      ? candidate.sizeBytes - jpegBytes
      : 0;
}

class PngRunSummary {
  final List<PngConversionResult> results;

  /// Selected files that were not started because the user cancelled.
  final int notProcessed;

  const PngRunSummary({required this.results, required this.notProcessed});

  int count(PngConversionStatus status) =>
      results.where((r) => r.status == status).length;

  int get savedBytes => results.fold(0, (sum, r) => sum + r.savedBytes);

  List<PngConversionResult> get originalsKept => results
      .where((r) => r.status == PngConversionStatus.originalKept)
      .toList();

  int get droppedIccProfiles => results
      .where(
        (r) =>
            r.droppedIccProfile &&
            (r.status == PngConversionStatus.converted ||
                r.status == PngConversionStatus.originalKept),
      )
      .length;
}

/// Device operations. Every method may throw; the converter turns a throw
/// into a failed file and keeps the PNG.
abstract class PngToJpgIo {
  /// The first [maxBytes] bytes of the file.
  Future<Uint8List> readPrefix(String path, int maxBytes);

  /// The decoded image as 8-bit RGBA, or null if it cannot be decoded.
  Future<Uint8List?> decodeRgba(String path);

  /// Full-resolution JPEG of the PNG at [path].
  Future<Uint8List> encodeJpeg(String path, int quality);

  Future<bool> fileExists(String path);

  /// Writes [bytes] as a new media library image next to [source].
  Future<SavedJpeg> saveJpeg(
    Uint8List bytes, {
    required String name,
    required PngCandidate source,
  });

  /// The bytes of the saved file as the device now has them. An empty list or
  /// a throw means the file is not there.
  Future<Uint8List> readSaved(SavedJpeg saved);

  /// Fully decodes [bytes] and returns the dimensions, or null on failure.
  Future<ImageDimensions?> decodeDimensions(Uint8List bytes);

  /// Removes a JPEG that this tool wrote.
  Future<void> discardJpeg(SavedJpeg saved);

  /// Removes the given PNGs in one batch (one system prompt). Returns the ids
  /// that are gone.
  Future<Set<String>> deleteOriginals(List<PngCandidate> originals);
}

typedef PngProgressCallback =
    void Function(int done, int total, PngCandidate? current);

class PngToJpgConverter {
  final PngToJpgIo io;

  PngToJpgConverter(this.io);

  /// Converts [candidates] one at a time, then removes the PNGs of all
  /// verified conversions in one batch.
  ///
  /// [isCancelled] is checked before each file. A cancel never interrupts a
  /// file, and the PNGs of the files that are already done are still removed.
  Future<PngRunSummary> run(
    List<PngCandidate> candidates, {
    required int quality,
    PngProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final results = <PngConversionResult>[];
    final pendingDelete = <int>[];
    var notProcessed = 0;

    for (var i = 0; i < candidates.length; i++) {
      if (isCancelled?.call() ?? false) {
        notProcessed = candidates.length - i;
        break;
      }
      final candidate = candidates[i];
      onProgress?.call(i, candidates.length, candidate);
      final result = await convertOne(candidate, quality: quality);
      if (result.status == PngConversionStatus.originalKept) {
        pendingDelete.add(results.length);
      }
      results.add(result);
    }
    onProgress?.call(candidates.length - notProcessed, candidates.length, null);

    await _deleteVerified(results, pendingDelete);
    return PngRunSummary(results: results, notProcessed: notProcessed);
  }

  /// Asks again to remove the PNGs that are still on the device.
  Future<PngRunSummary> retryDelete(PngRunSummary summary) async {
    final results = List<PngConversionResult>.of(summary.results);
    final pending = <int>[
      for (var i = 0; i < results.length; i++)
        if (results[i].status == PngConversionStatus.originalKept) i,
    ];
    await _deleteVerified(results, pending);
    return PngRunSummary(results: results, notProcessed: summary.notProcessed);
  }

  /// Removes the new JPEGs whose PNG is still on the device, so that no
  /// duplicate stays behind.
  Future<PngRunSummary> rollBack(PngRunSummary summary) async {
    final results = List<PngConversionResult>.of(summary.results);
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      if (result.status != PngConversionStatus.originalKept) continue;
      try {
        await io.discardJpeg(result.saved!);
        results[i] = result.withStatus(PngConversionStatus.rolledBack);
      } catch (_) {
        // Both files stay. The status stays originalKept.
      }
    }
    return PngRunSummary(results: results, notProcessed: summary.notProcessed);
  }

  Future<void> _deleteVerified(
    List<PngConversionResult> results,
    List<int> pending,
  ) async {
    if (pending.isEmpty) return;
    // Only files with a saved and verified JPEG reach this point.
    final originals = [
      for (final index in pending)
        if (results[index].status == PngConversionStatus.originalKept &&
            results[index].saved != null)
          results[index].candidate,
    ];
    Set<String> removed;
    try {
      removed = await io.deleteOriginals(originals);
    } catch (_) {
      removed = const <String>{};
    }
    for (final index in pending) {
      final result = results[index];
      if (result.saved != null && removed.contains(result.candidate.id)) {
        results[index] = result.withStatus(PngConversionStatus.converted);
      }
    }
  }

  /// encode -> write -> verify. Returns [PngConversionStatus.originalKept]
  /// when the JPEG is saved and verified; the PNG is never removed here.
  Future<PngConversionResult> convertOne(
    PngCandidate candidate, {
    required int quality,
  }) async {
    PngConversionResult done(PngConversionStatus status, {String? message}) {
      return PngConversionResult(
        candidate: candidate,
        status: status,
        message: message,
      );
    }

    SavedJpeg? saved;
    try {
      final header = parsePngHeader(
        await io.readPrefix(candidate.path, kPngHeaderPrefixBytes),
      );
      if (header == null) {
        return done(PngConversionStatus.skippedNotPng);
      }
      if (header.isAnimated) {
        return done(PngConversionStatus.skippedAnimated);
      }
      if (header.mayHaveTransparency) {
        final rgba = await io.decodeRgba(candidate.path);
        if (rgba == null) {
          return done(
            PngConversionStatus.failed,
            message: "Could not decode the PNG to check for transparency",
          );
        }
        if (rgbaHasTransparency(rgba)) {
          return done(PngConversionStatus.skippedTransparency);
        }
      }

      final encoded = await io.encodeJpeg(candidate.path, quality);
      final encodedSize = parseJpegDimensions(encoded);
      if (encodedSize == null ||
          encodedSize.width != header.width ||
          encodedSize.height != header.height) {
        return done(
          PngConversionStatus.failed,
          message: "Encoder output does not match the PNG dimensions",
        );
      }
      final jpeg = jpegWithCaptureTime(encoded, candidate.captureTime);
      if (jpeg == null) {
        return done(
          PngConversionStatus.failed,
          message: "Could not write the capture date",
        );
      }
      if (!isJpegWorthKeeping(
        pngBytes: candidate.sizeBytes,
        jpegBytes: jpeg.length,
      )) {
        return PngConversionResult(
          candidate: candidate,
          status: PngConversionStatus.skippedNoSaving,
          jpegBytes: jpeg.length,
        );
      }

      final folder = p.dirname(candidate.path);
      final name = await pickJpgName(
        candidate.title,
        (name) => io.fileExists(p.join(folder, name)),
      );
      saved = await io.saveJpeg(jpeg, name: name, source: candidate);

      final problem = await _verify(saved, jpeg, header, folder);
      if (problem != null) {
        await _discardQuietly(saved);
        return done(PngConversionStatus.failed, message: problem);
      }

      return PngConversionResult(
        candidate: candidate,
        status: PngConversionStatus.originalKept,
        jpegBytes: jpeg.length,
        saved: saved,
        droppedIccProfile: header.hasIccProfile,
      );
    } catch (e) {
      if (saved != null) {
        await _discardQuietly(saved);
      }
      return done(PngConversionStatus.failed, message: e.toString());
    }
  }

  /// Returns null if the saved JPEG is good, else the reason.
  Future<String?> _verify(
    SavedJpeg saved,
    Uint8List written,
    PngHeaderInfo header,
    String expectedFolder,
  ) async {
    if (saved.id.isEmpty) return "The device did not register the JPEG";
    if (p.dirname(saved.path) != expectedFolder) {
      return "The JPEG was saved in a different folder";
    }
    final onDevice = await io.readSaved(saved);
    if (onDevice.isEmpty) return "The saved JPEG is empty";
    if (onDevice.length != written.length) {
      return "The saved JPEG has the wrong size";
    }
    final headerSize = parseJpegDimensions(onDevice);
    final decodedSize = await io.decodeDimensions(onDevice);
    if (headerSize == null || decodedSize == null) {
      return "The saved JPEG does not decode";
    }
    if (decodedSize.width != header.width ||
        decodedSize.height != header.height ||
        headerSize.width != header.width ||
        headerSize.height != header.height) {
      return "The saved JPEG has different dimensions";
    }
    return null;
  }

  Future<void> _discardQuietly(SavedJpeg saved) async {
    try {
      await io.discardJpeg(saved);
    } catch (_) {
      // Nothing more can be done; the PNG is untouched in every case.
    }
  }
}

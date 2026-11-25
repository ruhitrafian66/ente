// Offline fork: pure logic for the "Recompress large JPGs" tool.
//
// This file must stay free of Flutter, plugin and app imports so that the unit
// tests can run it in isolation. All device work (decode, encode, MediaStore
// save, delete) goes through [JpegRecompressIo], which the app implements in
// jpeg_recompress_service.dart and the tests replace with fakes.
//
// The tool finds JPEG files that use many more bytes than their pixel count
// needs, and encodes them again at a normal quality. Unlike the video tool,
// it measures the result: the new image is decoded and compared with the
// original pixel by pixel (PSNR), and it is kept only when the difference is
// below a limit and the file is clearly smaller.

import "dart:math" as math;
import "dart:typed_data";

import "package:path/path.dart" as p;
import "package:photos/services/png_to_jpg_core.dart"
    show ImageDimensions, SavedJpeg, jpegWithCaptureTime, parseJpegDimensions;

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

/// A JPEG is "large for its pixels" from this many bits per pixel. A phone
/// camera photo has about 2 to 3.5.
const double kJpegRecompressMinBitsPerPixel = 4.0;

/// Smaller files are not worth the work.
const int kJpegRecompressMinBytes = 300 * 1024;

/// Default quality, and the values the page offers.
const int kJpegRecompressDefaultQuality = 90;
const List<int> kJpegRecompressQualityOptions = [85, 90, 95];

/// When the first quality fails the picture check, this one is tried.
const int kJpegRecompressFallbackQuality = 95;

/// Minimum PSNR (dB, over the RGB channels) between the original and the new
/// image. 40 dB is a difference that is not visible at normal viewing size.
const double kJpegRecompressMinPsnr = 40.0;

/// A new file is kept only if it is at least this much smaller.
const double kJpegRecompressMinSavingFraction = 0.25;

/// A source whose own quality is below this value is large because of its
/// content (noise, fine detail), not because of a wasteful quality setting.
const int kJpegRecompressMinSourceQuality = 92;

/// Bytes after the end of the image that are tolerated. More than this means
/// embedded data (motion photo video, HDR gain map, depth map), which a
/// re-encode would delete.
const int kJpegRecompressMaxTrailerBytes = 64 * 1024;

/// Images above this pixel count are not checked (two RGBA buffers of this
/// size would need more than 320 MB).
const int kJpegRecompressMaxPixels = 40 * 1000 * 1000;

/// How many bytes of a JPEG are read to inspect the segments before the
/// pixel data.
const int kJpegHeaderPrefixBytes = 512 * 1024;

/// Android lets an app create an image only below these top-level folders.
const Set<String> kJpegRecompressWritableRoots = {"dcim", "pictures"};

// Standard JPEG luminance quantization table (quality 50).
const List<int> _standardLumaTable = [
  16, 11, 10, 16, 24, 40, 51, 61, //
  12, 12, 14, 19, 26, 58, 60, 55, //
  14, 13, 16, 24, 40, 57, 69, 56, //
  14, 17, 22, 29, 51, 87, 80, 62, //
  18, 22, 37, 56, 68, 109, 103, 77, //
  24, 35, 55, 64, 81, 104, 113, 92, //
  49, 64, 78, 87, 103, 121, 120, 101, //
  72, 92, 95, 98, 112, 100, 103, 99, //
];

// ---------------------------------------------------------------------------
// JPEG structure
// ---------------------------------------------------------------------------

bool hasJpegExtension(String? title) {
  if (title == null) return false;
  final extension = p.extension(title).toLowerCase();
  return extension == ".jpg" || extension == ".jpeg";
}

/// Cheap pre-filter from what the media library exposes. A reported mime type
/// wins over the file name. The real format is confirmed from the file
/// signature ([parseJpegHeader]).
bool looksLikeJpeg({String? title, String? mimeType}) {
  final mime = mimeType?.trim().toLowerCase();
  if (mime != null && mime.isNotEmpty) {
    return mime == "image/jpeg" || mime == "image/jpg";
  }
  return hasJpegExtension(title);
}

/// What the segments before the pixel data say about a JPEG.
class JpegHeaderInfo {
  /// Stored pixels, before the EXIF orientation is applied.
  final int width;
  final int height;

  /// 1 grey, 3 colour, 4 CMYK.
  final int components;

  /// EXIF orientation, 1 to 8. 1 when there is none.
  final int orientation;

  /// The quality (1 to 100) that gives the luminance table of this file with
  /// the standard encoder, or null when the table was not found.
  final int? estimatedQuality;
  final bool hasIccProfile;

  /// The EXIF segments, each from its 0xFF marker to its last byte.
  final List<Uint8List> exifSegments;

  const JpegHeaderInfo({
    required this.width,
    required this.height,
    required this.components,
    required this.orientation,
    required this.estimatedQuality,
    required this.hasIccProfile,
    required this.exifSegments,
  });

  bool get _isQuarterTurned => orientation >= 5 && orientation <= 8;

  /// The size of the image as a viewer shows it.
  ImageDimensions get displaySize => _isQuarterTurned
      ? (width: height, height: width)
      : (width: width, height: height);
}

bool _startsWith(Uint8List bytes, int offset, String ascii) {
  if (offset + ascii.length > bytes.length) return false;
  for (var i = 0; i < ascii.length; i++) {
    if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
  }
  return true;
}

bool _isStartOfFrame(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;

/// Parses a JPEG (or a prefix of one) up to the first scan. Returns null if
/// [bytes] is not a JPEG or the frame header is not in the prefix.
JpegHeaderInfo? parseJpegHeader(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  int? width, height, components, quality;
  var orientation = 1;
  var hasIcc = false;
  final exifSegments = <Uint8List>[];

  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) return null;
    final marker = bytes[offset + 1];
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) break;
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) return null;
    final dataStart = offset + 4;
    final end = offset + 2 + length;
    final isComplete = end <= bytes.length;

    if (_isStartOfFrame(marker)) {
      if (dataStart + 6 > bytes.length) return null;
      height = (bytes[dataStart + 1] << 8) | bytes[dataStart + 2];
      width = (bytes[dataStart + 3] << 8) | bytes[dataStart + 4];
      components = bytes[dataStart + 5];
    } else if (marker == 0xE1 && _startsWith(bytes, dataStart, "Exif")) {
      if (isComplete) {
        final segment = Uint8List.sublistView(bytes, offset, end);
        exifSegments.add(Uint8List.fromList(segment));
        orientation = exifOrientationOf(segment) ?? orientation;
      }
    } else if (marker == 0xE2 && _startsWith(bytes, dataStart, "ICC_PROFILE")) {
      hasIcc = true;
    } else if (marker == 0xDB && isComplete) {
      quality ??= _qualityFromTables(bytes, dataStart, end);
    }
    offset = end;
  }

  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return JpegHeaderInfo(
    width: width,
    height: height,
    components: components ?? 3,
    orientation: orientation,
    estimatedQuality: quality,
    hasIccProfile: hasIcc,
    exifSegments: exifSegments,
  );
}

/// Reads the luminance table (id 0) of a DQT segment and returns the quality
/// that the standard encoder needs to produce it.
int? _qualityFromTables(Uint8List bytes, int start, int end) {
  var offset = start;
  while (offset < end) {
    final info = bytes[offset];
    final is16Bit = (info >> 4) != 0;
    final id = info & 0x0F;
    final size = is16Bit ? 128 : 64;
    if (offset + 1 + size > end) return null;
    if (id == 0) {
      var sum = 0;
      for (var i = 0; i < 64; i++) {
        sum += is16Bit
            ? (bytes[offset + 1 + i * 2] << 8) | bytes[offset + 2 + i * 2]
            : bytes[offset + 1 + i];
      }
      return jpegQualityFromLumaSum(sum);
    }
    offset += 1 + size;
  }
  return null;
}

/// The order of the 64 values does not change their sum, so the estimate
/// needs no zigzag conversion.
int jpegQualityFromLumaSum(int sum) {
  final standardSum = _standardLumaTable.fold(0, (a, b) => a + b);
  final scale = sum * 100 / standardSum;
  final quality = scale <= 100 ? (200 - scale) / 2 : 5000 / scale;
  return quality.round().clamp(1, 100);
}

/// The offset after the end-of-image marker of the first image in [bytes],
/// or null when the file is cut off. Bytes after that offset are a trailer
/// (motion photo video, HDR gain map, depth map, vendor data).
int? findJpegPrimaryEnd(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var offset = 2;
  var inScan = false;
  while (offset + 1 < bytes.length) {
    if (bytes[offset] != 0xFF) {
      if (!inScan) return null;
      offset++;
      continue;
    }
    final marker = bytes[offset + 1];
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    if (marker == 0x00 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0x01) {
      offset += 2;
      continue;
    }
    if (marker == 0xD9) return offset + 2;
    if (marker == 0xD8) {
      offset += 2;
      continue;
    }
    if (offset + 4 > bytes.length) return null;
    final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) return null;
    inScan = marker == 0xDA;
    offset += 2 + length;
  }
  return null;
}

// ---------------------------------------------------------------------------
// EXIF
// ---------------------------------------------------------------------------

const int _exifTiffOffset = 10; // FF E1, length (2), "Exif\0\0"

/// The file offset of the 2-byte orientation value inside an EXIF segment,
/// and the byte order. Null when the segment has no orientation tag.
({int offset, Endian endian})? _orientationField(Uint8List segment) {
  const tiff = _exifTiffOffset;
  if (segment.length < tiff + 8) return null;
  final Endian endian;
  if (segment[tiff] == 0x49 && segment[tiff + 1] == 0x49) {
    endian = Endian.little;
  } else if (segment[tiff] == 0x4D && segment[tiff + 1] == 0x4D) {
    endian = Endian.big;
  } else {
    return null;
  }
  final data = ByteData.sublistView(segment);
  if (data.getUint16(tiff + 2, endian) != 42) return null;
  final ifd = tiff + data.getUint32(tiff + 4, endian);
  if (ifd + 2 > segment.length) return null;
  final count = data.getUint16(ifd, endian);
  for (var i = 0; i < count; i++) {
    final entry = ifd + 2 + i * 12;
    if (entry + 12 > segment.length) return null;
    if (data.getUint16(entry, endian) == 0x0112 &&
        data.getUint16(entry + 2, endian) == 3) {
      return (offset: entry + 8, endian: endian);
    }
  }
  return null;
}

/// The EXIF orientation (1 to 8) of an EXIF segment, or null.
int? exifOrientationOf(Uint8List segment) {
  final field = _orientationField(segment);
  if (field == null) return null;
  final value = ByteData.sublistView(
    segment,
  ).getUint16(field.offset, field.endian);
  return value >= 1 && value <= 8 ? value : null;
}

/// A copy of [segment] whose orientation tag says "upright". Every other
/// byte (date, GPS, camera data, maker notes) stays as it is.
Uint8List exifSegmentUpright(Uint8List segment) {
  final copy = Uint8List.fromList(segment);
  final field = _orientationField(copy);
  if (field != null) {
    ByteData.sublistView(copy).setUint16(field.offset, 1, field.endian);
  }
  return copy;
}

/// Returns [jpeg] with [exifSegments] inserted after the start marker.
/// Existing EXIF segments of [jpeg] are removed. Null if [jpeg] is no JPEG.
Uint8List? jpegWithExifSegments(Uint8List jpeg, List<Uint8List> exifSegments) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
  final out = BytesBuilder(copy: false);
  out.add(const [0xFF, 0xD8]);
  for (final segment in exifSegments) {
    out.add(segment);
  }
  var offset = 2;
  while (offset + 4 <= jpeg.length && jpeg[offset] == 0xFF) {
    final marker = jpeg[offset + 1];
    if (marker == 0xDA || marker == 0xD9 || marker < 0xC0) break;
    final length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    final end = offset + 2 + length;
    if (length < 2 || end > jpeg.length) return null;
    final isExif = marker == 0xE1 && _startsWith(jpeg, offset + 4, "Exif");
    if (!isExif) {
      out.add(Uint8List.sublistView(jpeg, offset, end));
    }
    offset = end;
  }
  out.add(Uint8List.sublistView(jpeg, offset));
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// Picture check
// ---------------------------------------------------------------------------

/// Peak signal-to-noise ratio (dB) over the R, G and B channels of two 8-bit
/// RGBA buffers of the same size. Infinity when the pixels are equal.
double rgbPsnr(Uint8List a, Uint8List b) {
  if (a.length != b.length || a.length < 4) {
    throw ArgumentError("The two images have different sizes");
  }
  var sum = 0;
  final pixels = a.length ~/ 4;
  for (var i = 0; i < pixels * 4; i += 4) {
    final dr = a[i] - b[i];
    final dg = a[i + 1] - b[i + 1];
    final db = a[i + 2] - b[i + 2];
    sum += dr * dr + dg * dg + db * db;
  }
  if (sum == 0) return double.infinity;
  final mse = sum / (pixels * 3);
  return 10 * math.log(255 * 255 / mse) / math.ln10;
}

// ---------------------------------------------------------------------------
// Decision for one file
// ---------------------------------------------------------------------------

bool isImageFolderWritable(String? relativePath) {
  if (relativePath == null) return false;
  final parts = relativePath.split("/").where((part) => part.isNotEmpty);
  if (parts.isEmpty) return false;
  return kJpegRecompressWritableRoots.contains(parts.first.toLowerCase());
}

double jpegBitsPerPixel({
  required int sizeBytes,
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0) return 0;
  return sizeBytes * 8 / (width * height);
}

/// Rough bits per pixel of a photo at [quality]. Real results change a lot
/// with the content; the tool measures each file after the encode.
double estimatedBitsPerPixel(int quality) {
  if (quality >= 95) return 3.0;
  if (quality >= 90) return 2.0;
  return 1.6;
}

enum JpegSkipReason {
  embeddedData("Motion photo, HDR or depth data"),
  alreadyCompressed("Large because of detail, not quality"),
  unsupportedColour("Colour format is not supported"),
  tooManyPixels("Too many pixels to check"),
  folderNotWritable("Folder does not accept new images");

  final String label;

  const JpegSkipReason(this.label);
}

/// One JPEG on the device that is large for its pixel count.
class JpegCandidate {
  /// Media library id (`EnteFile.localID`).
  final String id;
  final String title;
  final String path;
  final int sizeBytes;

  /// Stored pixels, before the EXIF orientation is applied.
  final int width;
  final int height;
  final int components;
  final int? estimatedQuality;

  /// Bytes after the end of the first image in the file.
  final int trailerBytes;
  final DateTime captureTime;

  /// MediaStore RELATIVE_PATH of the folder, for example "DCIM/Camera/".
  final String? relativePath;

  const JpegCandidate({
    required this.id,
    required this.title,
    required this.path,
    required this.sizeBytes,
    required this.width,
    required this.height,
    this.components = 3,
    this.estimatedQuality,
    this.trailerBytes = 0,
    required this.captureTime,
    required this.relativePath,
  });

  double get bitsPerPixel =>
      jpegBitsPerPixel(sizeBytes: sizeBytes, width: width, height: height);

  /// Null when the file can be recompressed.
  JpegSkipReason? get skipReason {
    if (trailerBytes > kJpegRecompressMaxTrailerBytes) {
      return JpegSkipReason.embeddedData;
    }
    if (components != 1 && components != 3) {
      return JpegSkipReason.unsupportedColour;
    }
    if (width * height > kJpegRecompressMaxPixels) {
      return JpegSkipReason.tooManyPixels;
    }
    final quality = estimatedQuality;
    if (quality != null && quality < kJpegRecompressMinSourceQuality) {
      return JpegSkipReason.alreadyCompressed;
    }
    if (!isImageFolderWritable(relativePath)) {
      return JpegSkipReason.folderNotWritable;
    }
    return null;
  }

  /// Rough saving at [quality]. Zero when the rule in
  /// [isRecompressedJpegWorthKeeping] would probably reject the result.
  int estimatedSavingBytes(int quality) {
    final output = (width * height * estimatedBitsPerPixel(quality) / 8)
        .round();
    if (!isRecompressedJpegWorthKeeping(
      sourceBytes: sizeBytes,
      outputBytes: output,
    )) {
      return 0;
    }
    return sizeBytes - output;
  }
}

/// True when a JPEG of this size and pixel count is worth a closer look.
bool isLargeForItsPixels({
  required int sizeBytes,
  required int width,
  required int height,
}) {
  if (sizeBytes < kJpegRecompressMinBytes) return false;
  return jpegBitsPerPixel(sizeBytes: sizeBytes, width: width, height: height) >=
      kJpegRecompressMinBitsPerPixel;
}

/// The "keep only if smaller" rule.
bool isRecompressedJpegWorthKeeping({
  required int sourceBytes,
  required int outputBytes,
  double minSavingFraction = kJpegRecompressMinSavingFraction,
}) {
  if (sourceBytes <= 0 || outputBytes <= 0) return false;
  return outputBytes <= sourceBytes * (1 - minSavingFraction);
}

// ---------------------------------------------------------------------------
// Output naming
// ---------------------------------------------------------------------------

/// "IMG_1.jpg" -> "IMG_1_small.jpg". The original still exists when the new
/// file is saved, so the name must differ.
String recompressedNameFor(String title, [int attempt = 0]) {
  final base = hasJpegExtension(title)
      ? p.basenameWithoutExtension(title)
      : title;
  final suffix = attempt == 0 ? "" : " ($attempt)";
  return "${base.isEmpty ? "image" : base}_small$suffix.jpg";
}

Future<String> pickRecompressedName(
  String title,
  Future<bool> Function(String name) isTaken,
) async {
  for (var i = 0; i < 1000; i++) {
    final name = recompressedNameFor(title, i);
    if (!await isTaken(name)) return name;
  }
  throw StateError("No free file name for $title");
}

// ---------------------------------------------------------------------------
// Conversion state machine
// ---------------------------------------------------------------------------

/// Decoded pixels as 8-bit RGBA, upright (EXIF orientation applied).
class DecodedRgba {
  final Uint8List rgba;
  final int width;
  final int height;

  const DecodedRgba({
    required this.rgba,
    required this.width,
    required this.height,
  });
}

enum JpegRecompressStatus {
  /// New file saved and verified, original removed.
  recompressed,

  /// New file saved and verified, but the device did not remove the original
  /// (for example the user denied the system prompt). Both files exist.
  originalKept,

  /// The new file of an [originalKept] image was removed again.
  rolledBack,
  skippedNotEligible,

  /// No tried quality passed the picture check.
  skippedQualityLoss,
  skippedNoSaving,
  failed,
}

class JpegRecompressResult {
  final JpegCandidate candidate;
  final JpegRecompressStatus status;
  final int outputBytes;

  /// The quality of the kept result, and its measured PSNR.
  final int? quality;
  final double? psnr;
  final SavedJpeg? saved;
  final String? message;

  /// The original had an ICC profile. The new file is sRGB without one.
  final bool droppedIccProfile;

  const JpegRecompressResult({
    required this.candidate,
    required this.status,
    this.outputBytes = 0,
    this.quality,
    this.psnr,
    this.saved,
    this.message,
    this.droppedIccProfile = false,
  });

  JpegRecompressResult withStatus(JpegRecompressStatus status) {
    return JpegRecompressResult(
      candidate: candidate,
      status: status,
      outputBytes: outputBytes,
      quality: quality,
      psnr: psnr,
      saved: saved,
      message: message,
      droppedIccProfile: droppedIccProfile,
    );
  }

  int get savedBytes => status == JpegRecompressStatus.recompressed
      ? candidate.sizeBytes - outputBytes
      : 0;
}

class JpegRecompressSummary {
  final List<JpegRecompressResult> results;

  /// Selected files that were not started because the user cancelled.
  final int notProcessed;

  const JpegRecompressSummary({
    required this.results,
    required this.notProcessed,
  });

  int count(JpegRecompressStatus status) =>
      results.where((r) => r.status == status).length;

  int get savedBytes => results.fold(0, (sum, r) => sum + r.savedBytes);

  List<JpegRecompressResult> get originalsKept => results
      .where((r) => r.status == JpegRecompressStatus.originalKept)
      .toList();

  int get droppedIccProfiles => results
      .where(
        (r) =>
            r.droppedIccProfile &&
            (r.status == JpegRecompressStatus.recompressed ||
                r.status == JpegRecompressStatus.originalKept),
      )
      .length;
}

/// Device operations. Every method may throw; the recompressor turns a throw
/// into a failed file and keeps the original.
abstract class JpegRecompressIo {
  /// The first [maxBytes] bytes of the file.
  Future<Uint8List> readPrefix(String path, int maxBytes);

  /// The decoded, upright image of the file at [path], or null if it cannot
  /// be decoded.
  Future<DecodedRgba?> decodeFile(String path);

  /// The decoded, upright image of [bytes], with the same decoder as
  /// [decodeFile], or null.
  Future<DecodedRgba?> decodeBytes(Uint8List bytes);

  /// Full-resolution, upright sRGB JPEG of the image at [path].
  Future<Uint8List> encodeJpeg(String path, int quality);

  Future<bool> fileExists(String path);

  /// Writes [bytes] as a new media library image next to [source].
  Future<SavedJpeg> saveJpeg(
    Uint8List bytes, {
    required String name,
    required JpegCandidate source,
  });

  /// The bytes of the saved file as the device now has them. An empty list or
  /// a throw means the file is not there.
  Future<Uint8List> readSaved(SavedJpeg saved);

  /// Removes a JPEG that this tool wrote.
  Future<void> discardJpeg(SavedJpeg saved);

  /// Removes the given originals in one batch (one system prompt). Returns
  /// the ids that are gone.
  Future<Set<String>> deleteOriginals(List<JpegCandidate> originals);
}

typedef JpegProgressCallback =
    void Function(int done, int total, JpegCandidate? current);

class JpegRecompressor {
  final JpegRecompressIo io;

  JpegRecompressor(this.io);

  /// Recompresses [candidates] one at a time, then removes the originals of
  /// all verified results in one batch.
  ///
  /// [isCancelled] is checked before each file. A cancel never interrupts a
  /// file, and the originals of the files that are already done are still
  /// removed.
  Future<JpegRecompressSummary> run(
    List<JpegCandidate> candidates, {
    required int quality,
    JpegProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final results = <JpegRecompressResult>[];
    final pendingDelete = <int>[];
    var notProcessed = 0;

    for (var i = 0; i < candidates.length; i++) {
      if (isCancelled?.call() ?? false) {
        notProcessed = candidates.length - i;
        break;
      }
      final candidate = candidates[i];
      onProgress?.call(i, candidates.length, candidate);
      final result = await recompressOne(candidate, quality: quality);
      if (result.status == JpegRecompressStatus.originalKept) {
        pendingDelete.add(results.length);
      }
      results.add(result);
    }
    onProgress?.call(candidates.length - notProcessed, candidates.length, null);

    await _deleteVerified(results, pendingDelete);
    return JpegRecompressSummary(results: results, notProcessed: notProcessed);
  }

  /// Asks again to remove the originals that are still on the device.
  Future<JpegRecompressSummary> retryDelete(
    JpegRecompressSummary summary,
  ) async {
    final results = List<JpegRecompressResult>.of(summary.results);
    final pending = <int>[
      for (var i = 0; i < results.length; i++)
        if (results[i].status == JpegRecompressStatus.originalKept) i,
    ];
    await _deleteVerified(results, pending);
    return JpegRecompressSummary(
      results: results,
      notProcessed: summary.notProcessed,
    );
  }

  /// Removes the new files whose original is still on the device, so that no
  /// duplicate stays behind.
  Future<JpegRecompressSummary> rollBack(JpegRecompressSummary summary) async {
    final results = List<JpegRecompressResult>.of(summary.results);
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      if (result.status != JpegRecompressStatus.originalKept) continue;
      try {
        await io.discardJpeg(result.saved!);
        results[i] = result.withStatus(JpegRecompressStatus.rolledBack);
      } catch (_) {
        // Both files stay. The status stays originalKept.
      }
    }
    return JpegRecompressSummary(
      results: results,
      notProcessed: summary.notProcessed,
    );
  }

  Future<void> _deleteVerified(
    List<JpegRecompressResult> results,
    List<int> pending,
  ) async {
    if (pending.isEmpty) return;
    // Only files with a saved and verified copy reach this point.
    final originals = [
      for (final index in pending)
        if (results[index].status == JpegRecompressStatus.originalKept &&
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
        results[index] = result.withStatus(JpegRecompressStatus.recompressed);
      }
    }
  }

  /// encode -> compare -> save -> verify. Returns
  /// [JpegRecompressStatus.originalKept] when the new file is saved and
  /// verified; the original is never removed here.
  Future<JpegRecompressResult> recompressOne(
    JpegCandidate candidate, {
    required int quality,
  }) async {
    JpegRecompressResult done(
      JpegRecompressStatus status, {
      String? message,
      int outputBytes = 0,
      double? psnr,
    }) {
      return JpegRecompressResult(
        candidate: candidate,
        status: status,
        message: message,
        outputBytes: outputBytes,
        psnr: psnr,
      );
    }

    final skipReason = candidate.skipReason;
    if (skipReason != null) {
      return done(
        JpegRecompressStatus.skippedNotEligible,
        message: skipReason.label,
      );
    }

    SavedJpeg? saved;
    try {
      final header = parseJpegHeader(
        await io.readPrefix(candidate.path, kJpegHeaderPrefixBytes),
      );
      if (header == null) {
        return done(
          JpegRecompressStatus.failed,
          message: "The file is not a readable JPEG",
        );
      }
      final expected = header.displaySize;
      final original = await io.decodeFile(candidate.path);
      if (original == null) {
        return done(
          JpegRecompressStatus.failed,
          message: "Could not decode the original",
        );
      }
      if (original.width != expected.width ||
          original.height != expected.height) {
        return done(
          JpegRecompressStatus.failed,
          message: "The decoder gives an unexpected image size",
        );
      }

      // Try the requested quality, then the fallback. Keep the first result
      // that passes the picture check.
      final qualities = [
        quality,
        if (quality < kJpegRecompressFallbackQuality)
          kJpegRecompressFallbackQuality,
      ];
      Uint8List? accepted;
      int? acceptedQuality;
      double? acceptedPsnr;
      double? bestPsnr;
      for (final tryQuality in qualities) {
        final encoded = await io.encodeJpeg(candidate.path, tryQuality);
        final encodedSize = parseJpegDimensions(encoded);
        if (encodedSize == null ||
            encodedSize.width != expected.width ||
            encodedSize.height != expected.height) {
          return done(
            JpegRecompressStatus.failed,
            message: "Encoder output does not match the image dimensions",
          );
        }
        if (!isRecompressedJpegWorthKeeping(
          sourceBytes: candidate.sizeBytes,
          outputBytes: encoded.length,
        )) {
          // A higher quality only gives a larger file.
          return done(
            JpegRecompressStatus.skippedNoSaving,
            outputBytes: encoded.length,
            psnr: bestPsnr,
          );
        }
        final decoded = await io.decodeBytes(encoded);
        if (decoded == null ||
            decoded.width != original.width ||
            decoded.height != original.height) {
          return done(
            JpegRecompressStatus.failed,
            message: "The new image does not decode to the same size",
          );
        }
        final psnr = rgbPsnr(original.rgba, decoded.rgba);
        if (bestPsnr == null || psnr > bestPsnr) bestPsnr = psnr;
        if (psnr >= kJpegRecompressMinPsnr) {
          accepted = encoded;
          acceptedQuality = tryQuality;
          acceptedPsnr = psnr;
          break;
        }
      }
      if (accepted == null) {
        return done(
          JpegRecompressStatus.skippedQualityLoss,
          psnr: bestPsnr,
          message:
              "The picture check failed "
              "(${bestPsnr?.toStringAsFixed(1)} dB)",
        );
      }

      // Keep the metadata of the original. The encoder output is upright,
      // so the orientation tag must say "upright".
      final Uint8List? jpeg = header.exifSegments.isEmpty
          ? jpegWithCaptureTime(accepted, candidate.captureTime)
          : jpegWithExifSegments(
              accepted,
              header.exifSegments.map(exifSegmentUpright).toList(),
            );
      if (jpeg == null) {
        return done(
          JpegRecompressStatus.failed,
          message: "Could not write the metadata",
        );
      }
      if (!isRecompressedJpegWorthKeeping(
        sourceBytes: candidate.sizeBytes,
        outputBytes: jpeg.length,
      )) {
        return done(
          JpegRecompressStatus.skippedNoSaving,
          outputBytes: jpeg.length,
          psnr: acceptedPsnr,
        );
      }

      final folder = p.dirname(candidate.path);
      final name = await pickRecompressedName(
        candidate.title,
        (name) => io.fileExists(p.join(folder, name)),
      );
      saved = await io.saveJpeg(jpeg, name: name, source: candidate);

      final problem = await _verify(saved, jpeg, expected, folder);
      if (problem != null) {
        await _discardQuietly(saved);
        return done(JpegRecompressStatus.failed, message: problem);
      }

      return JpegRecompressResult(
        candidate: candidate,
        status: JpegRecompressStatus.originalKept,
        outputBytes: jpeg.length,
        quality: acceptedQuality,
        psnr: acceptedPsnr,
        saved: saved,
        droppedIccProfile: header.hasIccProfile,
      );
    } catch (e) {
      if (saved != null) {
        await _discardQuietly(saved);
      }
      return done(JpegRecompressStatus.failed, message: e.toString());
    }
  }

  /// Returns null if the saved JPEG is good, else the reason.
  Future<String?> _verify(
    SavedJpeg saved,
    Uint8List written,
    ImageDimensions expected,
    String expectedFolder,
  ) async {
    if (saved.id.isEmpty) return "The device did not register the new JPG";
    if (p.dirname(saved.path) != expectedFolder) {
      return "The new JPG was saved in a different folder";
    }
    final onDevice = await io.readSaved(saved);
    if (onDevice.isEmpty) return "The saved JPG is empty";
    if (onDevice.length != written.length) {
      return "The saved JPG has the wrong size";
    }
    final size = parseJpegDimensions(onDevice);
    if (size == null) return "The saved JPG is not readable";
    if (size.width != expected.width || size.height != expected.height) {
      return "The saved JPG has different dimensions";
    }
    return null;
  }

  Future<void> _discardQuietly(SavedJpeg saved) async {
    try {
      await io.discardJpeg(saved);
    } catch (_) {
      // Nothing more can be done; the original is untouched in every case.
    }
  }
}

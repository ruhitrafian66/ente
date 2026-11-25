import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:photos/services/image_compress_core.dart";
import "package:photos/services/image_compress_decode.dart";
import "package:photos/services/png_to_jpg_core.dart"
    show SavedJpeg, parseJpegDimensions;

const _folder = "/storage/emulated/0/DCIM/Test";

/// Smooth gradients: a JPEG of this image at quality 90 is very near to the
/// source.
img.Image _smooth({int width = 160, int height = 120}) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = pixel.x * 255 ~/ width
      ..g = pixel.y * 255 ~/ height
      ..b = (pixel.x + pixel.y) * 255 ~/ (width + height);
  }
  return image;
}

/// Photo-like: gradients with light noise. A PNG of it is large, and a JPEG
/// is much smaller and still very near to it.
img.Image _photo({int width = 160, int height = 120}) {
  final image = _smooth(width: width, height: height);
  var seed = 99;
  int noise() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return (seed >> 8) % 4;
  }

  for (final pixel in image) {
    pixel
      ..r = (pixel.r.toInt() + noise()).clamp(0, 255)
      ..g = (pixel.g.toInt() + noise()).clamp(0, 255)
      ..b = (pixel.b.toInt() + noise()).clamp(0, 255);
  }
  return image;
}

/// Random pixels: no JPEG quality reproduces this well.
img.Image _noise({int width = 160, int height = 120}) {
  final image = img.Image(width: width, height: height);
  var seed = 4242;
  int next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return (seed >> 8) & 0xFF;
  }

  for (final pixel in image) {
    pixel
      ..r = next()
      ..g = next()
      ..b = next();
  }
  return image;
}

Uint8List _jpeg(img.Image image, {int quality = 100, int? orientation}) {
  if (orientation != null) {
    image.exif.imageIfd.orientation = orientation;
    image.exif.exifIfd[0x9003] = img.IfdValueAscii("2024:03:09 18:05:42");
  }
  return img.encodeJpg(image, quality: quality);
}

DecodedRgba? _decode(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  final rgba = upright.convert(numChannels: 4);
  return DecodedRgba(
    rgba: rgba.getBytes(order: img.ChannelOrder.rgba),
    width: upright.width,
    height: upright.height,
  );
}

class _FakeIo implements ImageCompressIo {
  final Map<String, Uint8List> files = {};

  /// Quality that the fake encoder really uses for a requested quality.
  final Map<int, int> realQuality = {};
  bool refuseDelete = false;
  bool corruptSaved = false;
  final List<int> encodeCalls = [];
  final Map<String, Uint8List> savedBytes = {};
  final List<SavedJpeg> discarded = [];
  final List<List<String>> deleteRequests = [];

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) async {
    final bytes = files[path]!;
    return Uint8List.sublistView(
      bytes,
      0,
      bytes.length < maxBytes ? bytes.length : maxBytes,
    );
  }

  @override
  Future<DecodedRgba?> decodeFile(String path) async => _decode(files[path]!);

  @override
  Future<DecodedRgba?> decodeBytes(Uint8List bytes) async => _decode(bytes);

  @override
  Future<Uint8List> encodeJpeg(String path, int quality) async {
    encodeCalls.add(quality);
    final upright = img.bakeOrientation(img.decodeImage(files[path]!)!);
    upright.exif = img.ExifData();
    return img.encodeJpg(upright, quality: realQuality[quality] ?? quality);
  }

  @override
  Future<bool> fileExists(String path) async =>
      files.containsKey(path) || savedBytes.containsKey(path);

  @override
  Future<SavedJpeg> saveJpeg(
    Uint8List bytes, {
    required String name,
    required ImageCandidate source,
  }) async {
    final saved = SavedJpeg(
      id: "new_${source.id}",
      path: "$_folder/$name",
      name: name,
    );
    savedBytes[saved.path] = corruptSaved
        ? Uint8List.sublistView(bytes, 0, bytes.length ~/ 2)
        : bytes;
    return saved;
  }

  @override
  Future<Uint8List> readSaved(SavedJpeg saved) async => savedBytes[saved.path]!;

  @override
  Future<void> discardJpeg(SavedJpeg saved) async {
    discarded.add(saved);
    savedBytes.remove(saved.path);
  }

  @override
  Future<Set<String>> deleteOriginals(List<ImageCandidate> originals) async {
    deleteRequests.add(originals.map((o) => o.id).toList());
    if (refuseDelete) return {};
    return originals.map((o) => o.id).toSet();
  }

  ImageCandidate add(
    String id,
    Uint8List bytes, {
    String? relativePath,
    String extension = "jpg",
  }) {
    final title = "img_$id.$extension";
    final path = "$_folder/$title";
    files[path] = bytes;
    final format = sniffImageFormat(bytes)!;
    final header = format == "JPG" ? parseJpegHeader(bytes)! : null;
    final decoded = img.decodeImage(bytes)!;
    return ImageCandidate(
      id: id,
      title: title,
      path: path,
      sizeBytes: bytes.length,
      format: format,
      width: header?.width ?? decoded.width,
      height: header?.height ?? decoded.height,
      components: header?.components ?? 3,
      estimatedQuality: header?.estimatedQuality,
      trailerBytes: header == null
          ? 0
          : bytes.length - findJpegPrimaryEnd(bytes)!,
      captureTime: DateTime(2024, 3, 9, 18, 5, 42),
      relativePath: relativePath ?? "DCIM/Test/",
    );
  }
}

ImageCandidate _candidate({
  int sizeBytes = 5 * 1024 * 1024,
  int width = 2000,
  int height = 2000,
  int components = 3,
  int? quality = 100,
  int trailerBytes = 0,
  String? relativePath = "DCIM/Camera/",
  String format = "JPG",
  bool isAnimated = false,
}) {
  return ImageCandidate(
    id: "1",
    format: format,
    isAnimated: isAnimated,
    title: "a.jpg",
    path: "/storage/emulated/0/DCIM/Camera/a.jpg",
    sizeBytes: sizeBytes,
    width: width,
    height: height,
    components: components,
    estimatedQuality: quality,
    trailerBytes: trailerBytes,
    captureTime: DateTime(2024),
    relativePath: relativePath,
  );
}

void main() {
  group("parseJpegHeader", () {
    test("reads the size and estimates the quality", () {
      for (final quality in [100, 95, 90, 75, 50]) {
        final header = parseJpegHeader(_jpeg(_smooth(), quality: quality))!;
        expect(header.width, 160);
        expect(header.height, 120);
        expect(header.components, 3);
        expect(header.orientation, 1);
        expect(header.estimatedQuality, closeTo(quality, 2));
      }
    });

    test("reads the EXIF orientation and the displayed size", () {
      final header = parseJpegHeader(_jpeg(_smooth(), orientation: 6))!;
      expect(header.orientation, 6);
      expect(header.exifSegments, hasLength(1));
      expect(header.displaySize, (width: 120, height: 160));
    });

    test("rejects other data", () {
      expect(parseJpegHeader(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
      expect(
        parseJpegHeader(Uint8List.sublistView(_jpeg(_smooth()), 0, 12)),
        isNull,
      );
    });
  });

  group("sniffImageFormat", () {
    test("names the real format of the data", () {
      expect(sniffImageFormat(_jpeg(_smooth())), "JPG");
      expect(sniffImageFormat(img.encodePng(_photo())), "PNG");
      expect(sniffImageFormat(img.encodeGif(_smooth())), "GIF");
      expect(sniffImageFormat(img.encodeBmp(_smooth())), "BMP");
      expect(
        sniffImageFormat(
          Uint8List.fromList("RIFF\x00\x00\x00\x00WEBPVP8 ".codeUnits),
        ),
        "WebP",
      );
      expect(
        sniffImageFormat(
          Uint8List.fromList("\x00\x00\x00\x18ftypheic".codeUnits),
        ),
        "HEIC or AVIF",
      );
      expect(sniffImageFormat(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(sniffImageFormat(Uint8List(0)), isNull);
    });

    test("a PNG is not readable as a JPEG", () {
      expect(parseJpegHeader(img.encodePng(_photo())), isNull);
    });
  });

  group("findJpegPrimaryEnd", () {
    test("is the file length for a plain JPEG", () {
      final bytes = _jpeg(_noise(), quality: 100);
      expect(findJpegPrimaryEnd(bytes), bytes.length);
    });

    test("finds the end before an appended video or second image", () {
      final first = _jpeg(_noise(), quality: 100);
      final withTrailer = Uint8List.fromList([
        ...first,
        ..._jpeg(_smooth(), quality: 80),
        ...List.filled(1000, 0x42),
      ]);
      expect(findJpegPrimaryEnd(withTrailer), first.length);
    });

    test("returns null for a cut file", () {
      final bytes = _jpeg(_noise(), quality: 100);
      expect(
        findJpegPrimaryEnd(Uint8List.sublistView(bytes, 0, bytes.length - 10)),
        isNull,
      );
    });
  });

  group("EXIF", () {
    test("the orientation is set upright and the rest stays", () {
      final source = _jpeg(_smooth(), orientation: 6);
      final segment = parseJpegHeader(source)!.exifSegments.single;
      final upright = exifSegmentUpright(segment);
      expect(exifOrientationOf(segment), 6);
      expect(exifOrientationOf(upright), 1);
      expect(upright.length, segment.length);
      var changed = 0;
      for (var i = 0; i < segment.length; i++) {
        if (segment[i] != upright[i]) changed++;
      }
      expect(changed, 1);
    });

    test("the segments move into another JPEG", () {
      final source = _jpeg(_smooth(), orientation: 6);
      final segments = parseJpegHeader(
        source,
      )!.exifSegments.map(exifSegmentUpright).toList();
      final target = _jpeg(_smooth(width: 120, height: 160), quality: 90);
      final merged = jpegWithExifSegments(target, segments)!;

      expect(merged.length, target.length + segments.single.length);
      expect(parseJpegDimensions(merged), (width: 120, height: 160));
      final exif = img.decodeJpgExif(merged)!;
      expect(exif.imageIfd.orientation, 1);
      expect(exif.exifIfd[0x9003]!.toString(), "2024:03:09 18:05:42");
      expect(img.decodeJpg(merged), isNotNull);
    });

    test("an old EXIF segment of the target is replaced", () {
      final source = _jpeg(_smooth(), orientation: 6);
      final segments = parseJpegHeader(source)!.exifSegments;
      final merged = jpegWithExifSegments(
        _jpeg(_smooth(), orientation: 3),
        segments,
      )!;
      expect(parseJpegHeader(merged)!.exifSegments, hasLength(1));
      expect(parseJpegHeader(merged)!.orientation, 6);
    });
  });

  group("rgbPsnr", () {
    test("is infinite for equal images", () {
      final a = Uint8List.fromList([1, 2, 3, 255, 4, 5, 6, 255]);
      expect(rgbPsnr(a, Uint8List.fromList(a)), double.infinity);
    });

    test("ignores alpha and falls with the error", () {
      final a = Uint8List.fromList([10, 10, 10, 255]);
      expect(rgbPsnr(a, Uint8List.fromList([10, 10, 10, 0])), double.infinity);
      final small = rgbPsnr(a, Uint8List.fromList([11, 11, 11, 255]));
      final large = rgbPsnr(a, Uint8List.fromList([20, 20, 20, 255]));
      expect(small, closeTo(48.13, 0.01));
      expect(large, lessThan(small));
    });

    test("refuses different sizes", () {
      expect(() => rgbPsnr(Uint8List(4), Uint8List(8)), throwsArgumentError);
    });
  });

  group("candidate rules", () {
    test("a 4 MP file of 5 MB is large for its pixels", () {
      expect(
        isLargeForItsPixels(
          sizeBytes: 5 * 1024 * 1024,
          width: 1536,
          height: 2752,
        ),
        isTrue,
      );
    });

    test("a normal 12 MP camera photo is not", () {
      expect(
        isLargeForItsPixels(
          sizeBytes: 4 * 1024 * 1024,
          width: 4000,
          height: 3000,
        ),
        isFalse,
      );
    });

    test("a small file is not, whatever its ratio", () {
      expect(
        isLargeForItsPixels(sizeBytes: 100 * 1024, width: 200, height: 200),
        isFalse,
      );
    });

    test("skip reasons", () {
      expect(_candidate().skipReason, isNull);
      expect(_candidate(quality: null).skipReason, isNull);
      expect(
        _candidate(trailerBytes: 3 * 1024 * 1024).skipReason,
        ImageSkipReason.embeddedData,
      );
      expect(_candidate(trailerBytes: 500).skipReason, isNull);
      expect(
        _candidate(quality: 85).skipReason,
        ImageSkipReason.alreadyCompressed,
      );
      expect(
        _candidate(components: 4).skipReason,
        ImageSkipReason.unsupportedColour,
      );
      expect(
        _candidate(width: 9000, height: 9000).skipReason,
        ImageSkipReason.tooManyPixels,
      );
      expect(
        _candidate(relativePath: "Download/").skipReason,
        ImageSkipReason.folderNotWritable,
      );
      expect(_candidate(relativePath: "Pictures/a/").skipReason, isNull);
      expect(_candidate(format: "PNG", quality: null).skipReason, isNull);
      expect(_candidate(format: "WebP", quality: null).skipReason, isNull);
      expect(
        _candidate(format: "GIF").skipReason,
        ImageSkipReason.unsupportedFormat,
      );
      expect(
        _candidate(format: "HEIC or AVIF").skipReason,
        ImageSkipReason.unsupportedFormat,
      );
      expect(
        _candidate(format: "PNG", isAnimated: true).skipReason,
        ImageSkipReason.animated,
      );
    });

    test("the estimate is zero when the rule would reject the result", () {
      expect(_candidate().estimatedSavingBytes(90), greaterThan(3000000));
      expect(_candidate(sizeBytes: 1100 * 1024).estimatedSavingBytes(90), 0);
    });

    test("an animated WebP is recognised", () {
      Uint8List webp(int flags) => Uint8List.fromList([
        ..."RIFF".codeUnits,
        0,
        0,
        0,
        0,
        ..."WEBPVP8X".codeUnits,
        10,
        0,
        0,
        0,
        flags,
      ]);
      expect(isAnimatedWebp(webp(0x02)), isTrue);
      expect(isAnimatedWebp(webp(0x10)), isFalse);
      expect(isAnimatedWebp(Uint8List(4)), isFalse);
    });
  });

  group("ImageCompressor", () {
    test(
      "recompresses, keeps the EXIF data and deletes the original",
      () async {
        final io = _FakeIo();
        final candidate = io.add("1", _jpeg(_smooth(), orientation: 6));
        final summary = await ImageCompressor(io).run([candidate], quality: 90);

        final result = summary.results.single;
        expect(result.status, ImageCompressStatus.compressed);
        expect(result.quality, 90);
        expect(result.psnr, greaterThanOrEqualTo(kImageCompressMinPsnr));
        expect(summary.savedBytes, candidate.sizeBytes - result.outputBytes);
        expect(io.encodeCalls, [90]);
        expect(io.deleteRequests, [
          ["1"],
        ]);

        // The original still has the name "img_1.jpg".
        final saved = io.savedBytes["$_folder/img_1 (1).jpg"]!;
        // The pixels are upright now, and the tag says so.
        expect(parseJpegDimensions(saved), (width: 120, height: 160));
        final exif = img.decodeJpgExif(saved)!;
        expect(exif.imageIfd.orientation, 1);
        expect(exif.exifIfd[0x9003]!.toString(), "2024:03:09 18:05:42");
      },
    );

    test("a PNG becomes a JPG with the same base name", () async {
      final io = _FakeIo();
      final candidate = io.add("1", img.encodePng(_photo()), extension: "png");
      expect(candidate.format, "PNG");
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      final result = summary.results.single;
      expect(result.status, ImageCompressStatus.compressed);
      expect(result.saved!.name, "img_1.jpg");
      expect(result.psnr, greaterThanOrEqualTo(kImageCompressMinPsnr));
      final saved = io.savedBytes["$_folder/img_1.jpg"]!;
      expect(sniffImageFormat(saved), "JPG");
      expect(parseJpegDimensions(saved), (width: 160, height: 120));
      expect(
        img.decodeJpgExif(saved)!.exifIfd[0x9003]!.toString(),
        "2024:03:09 18:05:42",
      );
      expect(io.deleteRequests, [
        ["1"],
      ]);
    });

    test("the name of the file does not matter, only its data", () async {
      final io = _FakeIo();
      // PNG data in a file with a JPG name.
      final candidate = io.add("1", img.encodePng(_photo()));
      expect(candidate.title, "img_1.jpg");
      expect(candidate.format, "PNG");
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      final result = summary.results.single;
      expect(result.status, ImageCompressStatus.compressed);
      expect(result.saved!.name, "img_1 (1).jpg");
    });

    test("an image with transparent pixels is kept as it is", () async {
      final io = _FakeIo();
      final image = _photo().convert(numChannels: 4);
      image.getPixel(3, 3).a = 0;
      final candidate = io.add("1", img.encodePng(image), extension: "png");
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      expect(
        summary.results.single.status,
        ImageCompressStatus.skippedTransparency,
      );
      expect(io.encodeCalls, isEmpty);
      expect(io.savedBytes, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test("an opaque image with an alpha channel is compressed", () async {
      final io = _FakeIo();
      final image = _photo().convert(numChannels: 4);
      final candidate = io.add("1", img.encodePng(image), extension: "png");
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      expect(summary.results.single.status, ImageCompressStatus.compressed);
    });

    test("a format that cannot be converted is not touched", () async {
      final io = _FakeIo();
      final candidate = io.add("1", img.encodeGif(_smooth()), extension: "gif");
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      expect(
        summary.results.single.status,
        ImageCompressStatus.skippedNotEligible,
      );
      expect(io.encodeCalls, isEmpty);
    });

    test("a source without EXIF gets the capture time", () async {
      final io = _FakeIo();
      final candidate = io.add("1", _jpeg(_smooth()));
      await ImageCompressor(io).run([candidate], quality: 90);

      final exif = img.decodeJpgExif(io.savedBytes.values.single)!;
      expect(exif.exifIfd[0x9003]!.toString(), "2024:03:09 18:05:42");
    });

    test("uses the fallback quality when the first one loses detail", () async {
      final io = _FakeIo()..realQuality[90] = 5;
      final candidate = io.add("1", _jpeg(_smooth()));
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      final result = summary.results.single;
      expect(result.status, ImageCompressStatus.compressed);
      expect(result.quality, kImageCompressFallbackQuality);
      expect(io.encodeCalls, [90, 95]);
    });

    test("keeps the original when every quality loses detail", () async {
      final io = _FakeIo()
        ..realQuality[90] = 5
        ..realQuality[95] = 8;
      final candidate = io.add("1", _jpeg(_smooth()));
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      final result = summary.results.single;
      expect(result.status, ImageCompressStatus.skippedQualityLoss);
      expect(result.psnr, lessThan(kImageCompressMinPsnr));
      expect(io.savedBytes, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test("keeps the original when the saving is too small", () async {
      final io = _FakeIo();
      final candidate = io.add("1", _jpeg(_noise(), quality: 92));
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      expect(
        summary.results.single.status,
        ImageCompressStatus.skippedNoSaving,
      );
      expect(io.savedBytes, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test("does not touch a file with embedded data", () async {
      final io = _FakeIo();
      final bytes = Uint8List.fromList([
        ..._jpeg(_smooth()),
        ...List.filled(kImageCompressMaxTrailerBytes + 1, 7),
      ]);
      final candidate = io.add("1", bytes);
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      expect(
        summary.results.single.status,
        ImageCompressStatus.skippedNotEligible,
      );
      expect(io.encodeCalls, isEmpty);
    });

    test("removes a saved copy that fails the check", () async {
      final io = _FakeIo()..corruptSaved = true;
      final candidate = io.add("1", _jpeg(_smooth()));
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      expect(summary.results.single.status, ImageCompressStatus.failed);
      expect(io.discarded, hasLength(1));
      expect(io.deleteRequests, isEmpty);
    });

    test(
      "a refused delete keeps both files, then retry or roll back",
      () async {
        final io = _FakeIo()..refuseDelete = true;
        final recompressor = ImageCompressor(io);
        final candidate = io.add("1", _jpeg(_smooth()));
        final summary = await recompressor.run([candidate], quality: 90);

        expect(summary.results.single.status, ImageCompressStatus.originalKept);
        expect(summary.savedBytes, 0);

        final rolledBack = await recompressor.rollBack(summary);
        expect(
          rolledBack.results.single.status,
          ImageCompressStatus.rolledBack,
        );
        expect(io.discarded, hasLength(1));

        io.refuseDelete = false;
        final retried = await recompressor.retryDelete(summary);
        expect(retried.results.single.status, ImageCompressStatus.compressed);
      },
    );

    test("a cancel stops before the next file", () async {
      final io = _FakeIo();
      final first = io.add("1", _jpeg(_smooth()));
      final second = io.add("2", _jpeg(_smooth()));
      var calls = 0;
      final summary = await ImageCompressor(
        io,
      ).run([first, second], quality: 90, isCancelled: () => calls++ >= 1);

      expect(summary.results, hasLength(1));
      expect(summary.notProcessed, 1);
      expect(io.deleteRequests, [
        ["1"],
      ]);
    });

    test("a file chosen by hand ignores the source quality rule", () async {
      final io = _FakeIo();
      final candidate = io.add("1", _jpeg(_smooth(), quality: 85));
      expect(candidate.skipReason, ImageSkipReason.alreadyCompressed);
      expect(candidate.skipReasonFor(ignoreSourceQuality: true), isNull);

      final recompressor = ImageCompressor(io);
      final scanned = await recompressor.compressOne(candidate, quality: 90);
      expect(scanned.status, ImageCompressStatus.skippedNotEligible);
      expect(io.encodeCalls, isEmpty);

      // The saving rule still protects the file: quality 90 is not smaller.
      final manual = await recompressor.compressOne(
        candidate,
        quality: 90,
        ignoreSourceQuality: true,
      );
      expect(manual.status, ImageCompressStatus.skippedNoSaving);
      expect(io.savedBytes, isEmpty);
    });

    test("uses the next free name in the folder", () async {
      final io = _FakeIo();
      final candidate = io.add("1", _jpeg(_smooth()));
      io.files["$_folder/img_1 (1).jpg"] = Uint8List(1);
      final summary = await ImageCompressor(io).run([candidate], quality: 90);

      expect(summary.results.single.saved!.name, "img_1 (2).jpg");
    });
  });

  group("decodeUprightRgba (engine decoder)", () {
    testWidgets("applies the EXIF orientation", (tester) async {
      final jpeg = _jpeg(_smooth(width: 64, height: 32), orientation: 6);
      final decoded = await tester.runAsync(
        () => decodeUprightRgbaFromBytes(jpeg, maxPixels: 1000000),
      );
      expect(decoded!.width, 32);
      expect(decoded.height, 64);
      expect(decoded.rgba.length, 32 * 64 * 4);
    });

    testWidgets("gives the same pixels as the source for a good copy", (
      tester,
    ) async {
      final source = _jpeg(_smooth(), quality: 100);
      final copy = _jpeg(_smooth(), quality: 90);
      final psnr = await tester.runAsync(() async {
        final a = await decodeUprightRgbaFromBytes(source, maxPixels: 1000000);
        final b = await decodeUprightRgbaFromBytes(copy, maxPixels: 1000000);
        return rgbPsnr(a!.rgba, b!.rgba);
      });
      expect(psnr, greaterThan(kImageCompressMinPsnr));
    });

    testWidgets("refuses an image above the pixel limit", (tester) async {
      final jpeg = _jpeg(_smooth());
      final decoded = await tester.runAsync(
        () => decodeUprightRgbaFromBytes(jpeg, maxPixels: 100),
      );
      expect(decoded, isNull);
    });
  });
}

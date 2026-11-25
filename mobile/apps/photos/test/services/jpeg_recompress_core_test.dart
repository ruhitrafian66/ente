import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:photos/services/jpeg_recompress_core.dart";
import "package:photos/services/jpeg_recompress_decode.dart";
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
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  final rgba = upright.convert(numChannels: 4);
  return DecodedRgba(
    rgba: rgba.getBytes(order: img.ChannelOrder.rgba),
    width: upright.width,
    height: upright.height,
  );
}

class _FakeIo implements JpegRecompressIo {
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
    final upright = img.bakeOrientation(img.decodeJpg(files[path]!)!);
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
    required JpegCandidate source,
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
  Future<Set<String>> deleteOriginals(List<JpegCandidate> originals) async {
    deleteRequests.add(originals.map((o) => o.id).toList());
    if (refuseDelete) return {};
    return originals.map((o) => o.id).toSet();
  }

  JpegCandidate add(String id, Uint8List bytes, {String? relativePath}) {
    final title = "img_$id.jpg";
    final path = "$_folder/$title";
    files[path] = bytes;
    final header = parseJpegHeader(bytes)!;
    return JpegCandidate(
      id: id,
      title: title,
      path: path,
      sizeBytes: bytes.length,
      width: header.width,
      height: header.height,
      components: header.components,
      estimatedQuality: header.estimatedQuality,
      trailerBytes: bytes.length - findJpegPrimaryEnd(bytes)!,
      captureTime: DateTime(2024, 3, 9, 18, 5, 42),
      relativePath: relativePath ?? "DCIM/Test/",
    );
  }
}

JpegCandidate _candidate({
  int sizeBytes = 5 * 1024 * 1024,
  int width = 2000,
  int height = 2000,
  int components = 3,
  int? quality = 100,
  int trailerBytes = 0,
  String? relativePath = "DCIM/Camera/",
}) {
  return JpegCandidate(
    id: "1",
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
      expect(sniffImageFormat(img.encodePng(_smooth())), "PNG");
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
      expect(parseJpegHeader(img.encodePng(_smooth())), isNull);
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
        JpegSkipReason.embeddedData,
      );
      expect(_candidate(trailerBytes: 500).skipReason, isNull);
      expect(
        _candidate(quality: 85).skipReason,
        JpegSkipReason.alreadyCompressed,
      );
      expect(
        _candidate(components: 4).skipReason,
        JpegSkipReason.unsupportedColour,
      );
      expect(
        _candidate(width: 9000, height: 9000).skipReason,
        JpegSkipReason.tooManyPixels,
      );
      expect(
        _candidate(relativePath: "Download/").skipReason,
        JpegSkipReason.folderNotWritable,
      );
      expect(_candidate(relativePath: "Pictures/a/").skipReason, isNull);
    });

    test("the estimate is zero when the rule would reject the result", () {
      expect(_candidate().estimatedSavingBytes(90), greaterThan(3000000));
      expect(_candidate(sizeBytes: 1100 * 1024).estimatedSavingBytes(90), 0);
    });

    test("names", () async {
      expect(recompressedNameFor("IMG_1.jpg"), "IMG_1_small.jpg");
      expect(recompressedNameFor("IMG_1.JPEG", 2), "IMG_1_small (2).jpg");
      expect(
        await pickRecompressedName(
          "a.jpg",
          (name) async => name == "a_small.jpg",
        ),
        "a_small (1).jpg",
      );
    });
  });

  group("JpegRecompressor", () {
    test(
      "recompresses, keeps the EXIF data and deletes the original",
      () async {
        final io = _FakeIo();
        final candidate = io.add("1", _jpeg(_smooth(), orientation: 6));
        final summary = await JpegRecompressor(
          io,
        ).run([candidate], quality: 90);

        final result = summary.results.single;
        expect(result.status, JpegRecompressStatus.recompressed);
        expect(result.quality, 90);
        expect(result.psnr, greaterThanOrEqualTo(kJpegRecompressMinPsnr));
        expect(summary.savedBytes, candidate.sizeBytes - result.outputBytes);
        expect(io.encodeCalls, [90]);
        expect(io.deleteRequests, [
          ["1"],
        ]);

        final saved = io.savedBytes["$_folder/img_1_small.jpg"]!;
        // The pixels are upright now, and the tag says so.
        expect(parseJpegDimensions(saved), (width: 120, height: 160));
        final exif = img.decodeJpgExif(saved)!;
        expect(exif.imageIfd.orientation, 1);
        expect(exif.exifIfd[0x9003]!.toString(), "2024:03:09 18:05:42");
      },
    );

    test("a source without EXIF gets the capture time", () async {
      final io = _FakeIo();
      final candidate = io.add("1", _jpeg(_smooth()));
      await JpegRecompressor(io).run([candidate], quality: 90);

      final exif = img.decodeJpgExif(io.savedBytes.values.single)!;
      expect(exif.exifIfd[0x9003]!.toString(), "2024:03:09 18:05:42");
    });

    test("uses the fallback quality when the first one loses detail", () async {
      final io = _FakeIo()..realQuality[90] = 5;
      final candidate = io.add("1", _jpeg(_smooth()));
      final summary = await JpegRecompressor(io).run([candidate], quality: 90);

      final result = summary.results.single;
      expect(result.status, JpegRecompressStatus.recompressed);
      expect(result.quality, kJpegRecompressFallbackQuality);
      expect(io.encodeCalls, [90, 95]);
    });

    test("keeps the original when every quality loses detail", () async {
      final io = _FakeIo()
        ..realQuality[90] = 5
        ..realQuality[95] = 8;
      final candidate = io.add("1", _jpeg(_smooth()));
      final summary = await JpegRecompressor(io).run([candidate], quality: 90);

      final result = summary.results.single;
      expect(result.status, JpegRecompressStatus.skippedQualityLoss);
      expect(result.psnr, lessThan(kJpegRecompressMinPsnr));
      expect(io.savedBytes, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test("keeps the original when the saving is too small", () async {
      final io = _FakeIo();
      final candidate = io.add("1", _jpeg(_noise(), quality: 92));
      final summary = await JpegRecompressor(io).run([candidate], quality: 90);

      expect(
        summary.results.single.status,
        JpegRecompressStatus.skippedNoSaving,
      );
      expect(io.savedBytes, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test("does not touch a file with embedded data", () async {
      final io = _FakeIo();
      final bytes = Uint8List.fromList([
        ..._jpeg(_smooth()),
        ...List.filled(kJpegRecompressMaxTrailerBytes + 1, 7),
      ]);
      final candidate = io.add("1", bytes);
      final summary = await JpegRecompressor(io).run([candidate], quality: 90);

      expect(
        summary.results.single.status,
        JpegRecompressStatus.skippedNotEligible,
      );
      expect(io.encodeCalls, isEmpty);
    });

    test("removes a saved copy that fails the check", () async {
      final io = _FakeIo()..corruptSaved = true;
      final candidate = io.add("1", _jpeg(_smooth()));
      final summary = await JpegRecompressor(io).run([candidate], quality: 90);

      expect(summary.results.single.status, JpegRecompressStatus.failed);
      expect(io.discarded, hasLength(1));
      expect(io.deleteRequests, isEmpty);
    });

    test(
      "a refused delete keeps both files, then retry or roll back",
      () async {
        final io = _FakeIo()..refuseDelete = true;
        final recompressor = JpegRecompressor(io);
        final candidate = io.add("1", _jpeg(_smooth()));
        final summary = await recompressor.run([candidate], quality: 90);

        expect(
          summary.results.single.status,
          JpegRecompressStatus.originalKept,
        );
        expect(summary.savedBytes, 0);

        final rolledBack = await recompressor.rollBack(summary);
        expect(
          rolledBack.results.single.status,
          JpegRecompressStatus.rolledBack,
        );
        expect(io.discarded, hasLength(1));

        io.refuseDelete = false;
        final retried = await recompressor.retryDelete(summary);
        expect(
          retried.results.single.status,
          JpegRecompressStatus.recompressed,
        );
      },
    );

    test("a cancel stops before the next file", () async {
      final io = _FakeIo();
      final first = io.add("1", _jpeg(_smooth()));
      final second = io.add("2", _jpeg(_smooth()));
      var calls = 0;
      final summary = await JpegRecompressor(
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
      expect(candidate.skipReason, JpegSkipReason.alreadyCompressed);
      expect(candidate.skipReasonFor(ignoreSourceQuality: true), isNull);

      final recompressor = JpegRecompressor(io);
      final scanned = await recompressor.recompressOne(candidate, quality: 90);
      expect(scanned.status, JpegRecompressStatus.skippedNotEligible);
      expect(io.encodeCalls, isEmpty);

      // The saving rule still protects the file: quality 90 is not smaller.
      final manual = await recompressor.recompressOne(
        candidate,
        quality: 90,
        ignoreSourceQuality: true,
      );
      expect(manual.status, JpegRecompressStatus.skippedNoSaving);
      expect(io.savedBytes, isEmpty);
    });

    test("uses the next free name in the folder", () async {
      final io = _FakeIo();
      final candidate = io.add("1", _jpeg(_smooth()));
      io.files["$_folder/img_1_small.jpg"] = Uint8List(1);
      final summary = await JpegRecompressor(io).run([candidate], quality: 90);

      expect(summary.results.single.saved!.name, "img_1_small (1).jpg");
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
      expect(psnr, greaterThan(kJpegRecompressMinPsnr));
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

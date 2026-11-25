import "dart:typed_data";

import "package:exif_reader/exif_reader.dart";
import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;
import "package:path/path.dart" as p;
import "package:photos/services/png_to_jpg_core.dart";

// ---------------------------------------------------------------------------
// In-memory PNG builders
// ---------------------------------------------------------------------------

/// A photo-like image (gradients plus light noise): the PNG is large and the
/// JPEG is clearly smaller.
img.Image _noisy({
  int width = 64,
  int height = 48,
  int channels = 3,
  int bits = 8,
}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: channels,
    format: bits == 16 ? img.Format.uint16 : img.Format.uint8,
  );
  final scale = bits == 16 ? 257 : 1;
  var seed = 12345;
  int noise() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return (seed >> 8) % 6;
  }

  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 200 ~/ width + noise()) * scale
      ..g = (pixel.y * 200 ~/ height + noise()) * scale
      ..b = ((pixel.x + pixel.y) * 100 ~/ (width + height) + noise()) * scale;
    if (channels == 4) pixel.a = 255 * scale;
  }
  return image;
}

/// A flat image: the PNG is tiny, so a JPEG gives no saving.
img.Image _flat({int width = 64, int height = 48}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(20, 120, 220));
  return image;
}

Uint8List _png(img.Image image) => img.encodePng(image);

Uint8List _chunk(String type, List<int> data) {
  final out = BytesBuilder();
  final length = ByteData(4)..setUint32(0, data.length);
  out
    ..add(length.buffer.asUint8List())
    ..add(type.codeUnits)
    ..add(data)
    ..add([0, 0, 0, 0]); // CRC, not checked by the header parser.
  return out.toBytes();
}

/// Only the chunks before the pixel data; enough for [parsePngHeader].
Uint8List _headerOnlyPng({
  required int colorType,
  int bitDepth = 8,
  int width = 10,
  int height = 20,
  List<Uint8List> extraChunks = const [],
  bool withIdat = true,
}) {
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, bitDepth)
    ..setUint8(9, colorType);
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk("IHDR", ihdr.buffer.asUint8List()));
  for (final chunk in extraChunks) {
    out.add(chunk);
  }
  if (withIdat) out.add(_chunk("IDAT", [1, 2, 3]));
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// Fake device
// ---------------------------------------------------------------------------

class _FakeIo implements PngToJpgIo {
  final Map<String, Uint8List> files = {};
  final List<String> log = [];

  bool failEncode = false;
  bool failSave = false;
  bool denyDelete = false;
  bool throwOnDelete = false;
  bool failDiscard = false;

  /// Changes what the "device" reports for the saved file.
  Uint8List Function(Uint8List written)? corruptSaved;
  bool savedDoesNotDecode = false;
  ImageDimensions? forcedDecodedSize;
  String? saveIntoFolder;
  Uint8List Function(Uint8List png, int quality)? encoder;

  final List<List<String>> deleteRequests = [];
  final Map<String, SavedJpeg> savedByName = {};
  int _nextId = 100;

  void Function(String step)? onStep;

  void _note(String step) {
    log.add(step);
    onStep?.call(step);
  }

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) async {
    _note("readPrefix");
    final bytes = files[path];
    if (bytes == null) throw StateError("missing $path");
    return Uint8List.sublistView(
      bytes,
      0,
      bytes.length < maxBytes ? bytes.length : maxBytes,
    );
  }

  @override
  Future<Uint8List?> decodeRgba(String path) async {
    _note("decodeRgba");
    final image = img.decodePng(files[path]!);
    if (image == null) return null;
    return image
        .convert(format: img.Format.uint8, numChannels: 4)
        .getBytes(order: img.ChannelOrder.rgba);
  }

  @override
  Future<Uint8List> encodeJpeg(String path, int quality) async {
    _note("encode");
    if (failEncode) throw StateError("encoder failed");
    final png = files[path]!;
    if (encoder != null) return encoder!(png, quality);
    final image = img
        .decodePng(png)!
        .convert(format: img.Format.uint8, numChannels: 3);
    return img.encodeJpg(image, quality: quality);
  }

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<SavedJpeg> saveJpeg(
    Uint8List bytes, {
    required String name,
    required PngCandidate source,
  }) async {
    _note("save");
    if (failSave) throw StateError("media store refused");
    final folder = saveIntoFolder ?? p.dirname(source.path);
    final path = p.join(folder, name);
    files[path] = corruptSaved == null ? bytes : corruptSaved!(bytes);
    final saved = SavedJpeg(id: "${_nextId++}", path: path, name: name);
    savedByName[name] = saved;
    return saved;
  }

  @override
  Future<Uint8List> readSaved(SavedJpeg saved) async {
    _note("readSaved");
    return files[saved.path] ?? Uint8List(0);
  }

  @override
  Future<ImageDimensions?> decodeDimensions(Uint8List bytes) async {
    _note("decodeSaved");
    if (savedDoesNotDecode) return null;
    if (forcedDecodedSize != null) return forcedDecodedSize;
    final image = img.decodeJpg(bytes);
    if (image == null) return null;
    return (width: image.width, height: image.height);
  }

  @override
  Future<void> discardJpeg(SavedJpeg saved) async {
    _note("discard");
    if (failDiscard) throw StateError("cannot discard");
    files.remove(saved.path);
  }

  @override
  Future<Set<String>> deleteOriginals(List<PngCandidate> originals) async {
    _note("delete");
    deleteRequests.add(originals.map((o) => o.id).toList());
    if (throwOnDelete) throw StateError("delete crashed");
    if (denyDelete) return {};
    for (final original in originals) {
      files.remove(original.path);
    }
    return originals.map((o) => o.id).toSet();
  }

  PngCandidate add(
    String id,
    String title,
    Uint8List bytes, {
    String folder = "/storage/emulated/0/DCIM/Screenshots",
  }) {
    final path = p.join(folder, title);
    files[path] = bytes;
    final header = parsePngHeader(bytes);
    return PngCandidate(
      id: id,
      title: title,
      path: path,
      sizeBytes: bytes.length,
      width: header?.width ?? 0,
      height: header?.height ?? 0,
      captureTime: DateTime(2023, 4, 5, 6, 7, 8),
      relativePath: "DCIM/Screenshots/",
    );
  }
}

void main() {
  group("PNG detection", () {
    test("uses the mime type first, then the extension", () {
      expect(looksLikePng(title: "a.png", mimeType: "image/png"), isTrue);
      expect(looksLikePng(title: "a.PNG", mimeType: null), isTrue);
      expect(looksLikePng(title: "a.png", mimeType: ""), isTrue);
      expect(looksLikePng(title: "a.jpg", mimeType: "IMAGE/PNG"), isTrue);
      expect(looksLikePng(title: "a.png", mimeType: "image/jpeg"), isFalse);
      expect(looksLikePng(title: "a.jpg", mimeType: null), isFalse);
      expect(looksLikePng(title: "png", mimeType: null), isFalse);
      expect(looksLikePng(title: null, mimeType: null), isFalse);
    });

    test("confirms the real format from the signature", () {
      final png = _png(_noisy());
      final jpg = img.encodeJpg(_noisy());
      expect(hasPngSignature(png), isTrue);
      expect(hasPngSignature(jpg), isFalse);
      expect(hasPngSignature(Uint8List(3)), isFalse);
      expect(parsePngHeader(jpg), isNull);
      expect(parsePngHeader(Uint8List(0)), isNull);
    });

    test("reads dimensions, bit depth and colour type", () {
      final rgb = parsePngHeader(_png(_noisy(width: 31, height: 17)))!;
      expect((rgb.width, rgb.height), (31, 17));
      expect(rgb.colorType, 2);
      expect(rgb.bitDepth, 8);
      expect(rgb.sawAllHeaderChunks, isTrue);

      final rgba16 = parsePngHeader(_png(_noisy(channels: 4, bits: 16)))!;
      expect(rgba16.colorType, 6);
      expect(rgba16.is16Bit, isTrue);
    });

    test("finds iCCP and acTL chunks", () {
      final header = parsePngHeader(
        _headerOnlyPng(
          colorType: 2,
          extraChunks: [
            _chunk("iCCP", [1, 2, 3, 4]),
            _chunk("acTL", [0, 0, 0, 2, 0, 0, 0, 0]),
          ],
        ),
      )!;
      expect(header.hasIccProfile, isTrue);
      expect(header.isAnimated, isTrue);
      expect(header.hasTrns, isFalse);
    });
  });

  group("alpha detection", () {
    test("RGB needs no pixel scan", () {
      final header = parsePngHeader(_png(_noisy(channels: 3)))!;
      expect(header.hasAlphaChannel, isFalse);
      expect(header.mayHaveTransparency, isFalse);
    });

    test("RGBA needs a pixel scan", () {
      final header = parsePngHeader(_png(_noisy(channels: 4)))!;
      expect(header.hasAlphaChannel, isTrue);
      expect(header.mayHaveTransparency, isTrue);
    });

    test("palette with tRNS needs a pixel scan, without tRNS does not", () {
      final plain = parsePngHeader(
        _headerOnlyPng(
          colorType: 3,
          extraChunks: [
            _chunk("PLTE", [0, 0, 0, 255, 255, 255]),
          ],
        ),
      )!;
      expect(plain.mayHaveTransparency, isFalse);

      final withTrns = parsePngHeader(
        _headerOnlyPng(
          colorType: 3,
          extraChunks: [
            _chunk("PLTE", [0, 0, 0, 255, 255, 255]),
            _chunk("tRNS", [0, 255]),
          ],
        ),
      )!;
      expect(withTrns.hasTrns, isTrue);
      expect(withTrns.mayHaveTransparency, isTrue);
    });

    test("an incomplete header is treated as possible transparency", () {
      final header = parsePngHeader(
        _headerOnlyPng(colorType: 2, withIdat: false),
      )!;
      expect(header.sawAllHeaderChunks, isFalse);
      expect(header.mayHaveTransparency, isTrue);
    });

    test("opaque RGBA pixels are not transparent", () {
      final rgba = _noisy(channels: 4).getBytes(order: img.ChannelOrder.rgba);
      expect(rgbaHasTransparency(rgba), isFalse);
    });

    test("one transparent pixel is found", () {
      final image = _noisy(channels: 4);
      image.getPixel(63, 47).a = 254;
      final rgba = image.getBytes(order: img.ChannelOrder.rgba);
      expect(rgbaHasTransparency(rgba), isTrue);
    });

    test("works on an unaligned view", () {
      final opaque = Uint8List.fromList([9, 1, 2, 3, 255, 4, 5, 6, 255]);
      expect(rgbaHasTransparency(Uint8List.sublistView(opaque, 1)), isFalse);
      final clear = Uint8List.fromList([9, 1, 2, 3, 255, 4, 5, 6, 0]);
      expect(rgbaHasTransparency(Uint8List.sublistView(clear, 1)), isTrue);
    });
  });

  group("keep only if smaller", () {
    test("needs at least a 10% saving", () {
      expect(isJpegWorthKeeping(pngBytes: 1000, jpegBytes: 900), isTrue);
      expect(isJpegWorthKeeping(pngBytes: 1000, jpegBytes: 901), isFalse);
      expect(isJpegWorthKeeping(pngBytes: 1000, jpegBytes: 1000), isFalse);
      expect(isJpegWorthKeeping(pngBytes: 1000, jpegBytes: 2000), isFalse);
      expect(isJpegWorthKeeping(pngBytes: 1000, jpegBytes: 100), isTrue);
      expect(isJpegWorthKeeping(pngBytes: 0, jpegBytes: 0), isFalse);
      expect(isJpegWorthKeeping(pngBytes: 1000, jpegBytes: 0), isFalse);
    });

    test("the estimate is zero when no saving is expected", () {
      expect(
        estimateSavingBytes(
          pngBytes: 1000,
          width: 1000,
          height: 1000,
          quality: 90,
        ),
        0,
      );
      final saving = estimateSavingBytes(
        pngBytes: 3000000,
        width: 1080,
        height: 2340,
        quality: 90,
      );
      expect(saving, greaterThan(0));
      expect(saving, lessThan(3000000));
      expect(
        estimateJpegBytes(width: 100, height: 100, quality: 80),
        lessThan(estimateJpegBytes(width: 100, height: 100, quality: 95)),
      );
    });
  });

  group("output naming", () {
    test("keeps the base name", () {
      expect(jpgNameForPng("Screenshot_20240101-101010.png"), endsWith(".jpg"));
      expect(jpgNameForPng("Shot.PNG"), "Shot.jpg");
      expect(jpgNameForPng("a.b.png"), "a.b.jpg");
      expect(jpgNameForPng("noext"), "noext.jpg");
      // A PNG that has a JPG name keeps its base name.
      expect(jpgNameForPng("photo.jpg"), "photo.jpg");
      expect(jpgNameForPng("photo.JPEG"), "photo.jpg");
    });

    test("a PNG with a JPG name gets a counter, not its own name", () async {
      expect(
        await pickJpgName("photo.jpg", (n) async => n == "photo.jpg"),
        "photo (1).jpg",
      );
    });

    test("adds a counter when the name is taken", () async {
      final taken = {"Shot.jpg", "Shot (1).jpg"};
      expect(await pickJpgName("Shot.png", (n) async => false), "Shot.jpg");
      expect(
        await pickJpgName("Shot.png", (n) async => taken.contains(n)),
        "Shot (2).jpg",
      );
    });
  });

  group("JPEG helpers", () {
    test("reads the dimensions from the frame header", () {
      final jpg = img.encodeJpg(_noisy(width: 33, height: 21));
      expect(parseJpegDimensions(jpg), (width: 33, height: 21));
      expect(parseJpegDimensions(_png(_noisy())), isNull);
      expect(parseJpegDimensions(Uint8List.sublistView(jpg, 0, 10)), isNull);
    });

    test("writes the capture date and keeps the image", () async {
      final jpg = img.encodeJpg(_noisy(width: 33, height: 21));
      final time = DateTime(2021, 12, 31, 23, 59, 58);
      final tagged = jpegWithCaptureTime(jpg, time)!;

      expect(parseJpegDimensions(tagged), (width: 33, height: 21));
      expect(img.decodeJpg(tagged)!.width, 33);

      final exif = (await readExifFromBytes(tagged)).tags;
      expect("${exif["EXIF DateTimeOriginal"]}", "2021:12:31 23:59:58");
      expect("${exif["EXIF DateTimeDigitized"]}", "2021:12:31 23:59:58");
      expect("${exif["Image DateTime"]}", "2021:12:31 23:59:58");
      expect(
        "${exif["EXIF OffsetTimeOriginal"]}",
        exifOffsetString(time.timeZoneOffset),
      );
      expect(jpegWithCaptureTime(_png(_noisy()), time), isNull);
    });

    test("formats the EXIF offset", () {
      expect(exifOffsetString(const Duration(hours: 5, minutes: 30)), "+05:30");
      expect(exifOffsetString(const Duration(hours: -8)), "-08:00");
      expect(exifOffsetString(Duration.zero), "+00:00");
    });
  });

  group("conversion state machine", () {
    late _FakeIo io;
    late PngToJpgConverter converter;

    setUp(() {
      io = _FakeIo();
      converter = PngToJpgConverter(io);
    });

    test("encode, save, verify, then delete", () async {
      final c = io.add("1", "Shot.png", _png(_noisy()));
      final summary = await converter.run([c], quality: 90);

      expect(io.log, [
        "readPrefix",
        "encode",
        "save",
        "readSaved",
        "decodeSaved",
        "delete",
      ]);
      final result = summary.results.single;
      expect(result.status, PngConversionStatus.converted);
      expect(result.saved!.name, "Shot.jpg");
      expect(
        result.saved!.path,
        "/storage/emulated/0/DCIM/Screenshots/Shot.jpg",
      );
      expect(io.files.containsKey(c.path), isFalse);
      expect(summary.savedBytes, c.sizeBytes - result.jpegBytes);
      expect(summary.savedBytes, greaterThan(0));

      final exif = (await readExifFromBytes(
        io.files[result.saved!.path]!,
      )).tags;
      expect("${exif["EXIF DateTimeOriginal"]}", "2023:04:05 06:07:08");
    });

    test("an opaque RGBA PNG is converted after a pixel scan", () async {
      final c = io.add("1", "Shot.png", _png(_noisy(channels: 4)));
      final summary = await converter.run([c], quality: 90);
      expect(io.log.take(3), ["readPrefix", "decodeRgba", "encode"]);
      expect(summary.results.single.status, PngConversionStatus.converted);
    });

    test("a 16-bit PNG is converted", () async {
      final c = io.add("1", "Deep.png", _png(_noisy(channels: 3, bits: 16)));
      final summary = await converter.run([c], quality: 90);
      expect(summary.results.single.status, PngConversionStatus.converted);
    });

    test(
      "one transparent pixel: skipped, nothing written or deleted",
      () async {
        final image = _noisy(channels: 4);
        image.getPixel(3, 3).a = 0;
        final c = io.add("1", "Logo.png", _png(image));
        final summary = await converter.run([c], quality: 90);

        expect(
          summary.results.single.status,
          PngConversionStatus.skippedTransparency,
        );
        expect(io.log, ["readPrefix", "decodeRgba"]);
        expect(io.deleteRequests, isEmpty);
        expect(io.files.keys, [c.path]);
      },
    );

    test("a palette PNG with a transparent entry is skipped", () async {
      final image = img.Image(
        width: 16,
        height: 16,
        numChannels: 4,
        withPalette: true,
      );
      image.palette!
        ..setRgba(0, 255, 0, 0, 255)
        ..setRgba(1, 0, 255, 0, 0);
      for (final pixel in image) {
        pixel.index = pixel.x == 5 && pixel.y == 5 ? 1 : 0;
      }
      final bytes = _png(image);
      final header = parsePngHeader(bytes)!;
      expect(header.colorType, 3);
      expect(header.hasTrns, isTrue);

      final c = io.add("1", "Icon.png", bytes);
      final summary = await converter.run([c], quality: 90);
      expect(
        summary.results.single.status,
        PngConversionStatus.skippedTransparency,
      );
      expect(io.deleteRequests, isEmpty);
    });

    test("no saving: the PNG stays and no JPEG is written", () async {
      final c = io.add("1", "Flat.png", _png(_flat()));
      final summary = await converter.run([c], quality: 90);

      expect(
        summary.results.single.status,
        PngConversionStatus.skippedNoSaving,
      );
      expect(io.log, ["readPrefix", "encode"]);
      expect(io.files.keys, [c.path]);
    });

    test("not a PNG and animated PNG are skipped", () async {
      final fake = io.add("1", "Fake.png", img.encodeJpg(_noisy()));
      final animated = io.add(
        "2",
        "Anim.png",
        _headerOnlyPng(
          colorType: 2,
          extraChunks: [
            _chunk("acTL", [0, 0, 0, 2, 0, 0, 0, 0]),
          ],
        ),
      );
      final summary = await converter.run([fake, animated], quality: 90);
      expect(summary.results[0].status, PngConversionStatus.skippedNotPng);
      expect(summary.results[1].status, PngConversionStatus.skippedAnimated);
      expect(io.log, ["readPrefix", "readPrefix"]);
    });

    test("uses a free name when name.jpg exists in the folder", () async {
      final c = io.add("1", "Shot.png", _png(_noisy()));
      final existing = Uint8List.fromList([1, 2, 3]);
      io.files["/storage/emulated/0/DCIM/Screenshots/Shot.jpg"] = existing;

      final summary = await converter.run([c], quality: 90);
      expect(summary.results.single.saved!.name, "Shot (1).jpg");
      expect(
        io.files["/storage/emulated/0/DCIM/Screenshots/Shot.jpg"],
        existing,
      );
    });

    Future<void> expectVerifyFailure(void Function() arrange) async {
      final bad = io.add("1", "Bad.png", _png(_noisy()));
      arrange();
      final summary = await converter.run([bad], quality: 90);

      final result = summary.results.single;
      expect(result.status, PngConversionStatus.failed);
      expect(result.message, isNotNull);
      expect(io.log, contains("save"));
      expect(io.log, contains("discard"));
      expect(io.log, isNot(contains("delete")));
      expect(io.deleteRequests, isEmpty);
      // The PNG is the only file left.
      expect(io.files.keys, [bad.path]);
    }

    test("a truncated saved file never leads to a delete", () {
      return expectVerifyFailure(() {
        io.corruptSaved = (b) => Uint8List.sublistView(b, 0, b.length ~/ 2);
      });
    });

    test("an empty saved file never leads to a delete", () {
      return expectVerifyFailure(() => io.corruptSaved = (b) => Uint8List(0));
    });

    test("a saved file that does not decode never leads to a delete", () {
      return expectVerifyFailure(() => io.savedDoesNotDecode = true);
    });

    test("a saved file with other dimensions never leads to a delete", () {
      return expectVerifyFailure(() {
        io.forcedDecodedSize = (width: 32, height: 24);
      });
    });

    test("a file saved in another folder never leads to a delete", () {
      return expectVerifyFailure(() {
        io.saveIntoFolder = "/storage/emulated/0/Pictures";
      });
    });

    test(
      "encoder output with wrong dimensions is rejected before the save",
      () async {
        final c = io.add("1", "Shot.png", _png(_noisy()));
        io.encoder = (png, quality) =>
            img.encodeJpg(_noisy(width: 32, height: 24), quality: quality);
        final summary = await converter.run([c], quality: 90);

        expect(summary.results.single.status, PngConversionStatus.failed);
        expect(io.log, ["readPrefix", "encode"]);
        expect(io.files.keys, [c.path]);
      },
    );

    test("encoder and save failures keep the PNG", () async {
      final a = io.add("1", "A.png", _png(_noisy()));
      io.failEncode = true;
      var summary = await converter.run([a], quality: 90);
      expect(summary.results.single.status, PngConversionStatus.failed);

      io
        ..failEncode = false
        ..failSave = true;
      summary = await converter.run([a], quality: 90);
      expect(summary.results.single.status, PngConversionStatus.failed);
      expect(io.deleteRequests, isEmpty);
      expect(io.files.keys, [a.path]);
    });

    test("a missing source file is a failure", () async {
      final c = io.add("1", "Gone.png", _png(_noisy()));
      io.files.clear();
      final summary = await converter.run([c], quality: 90);
      expect(summary.results.single.status, PngConversionStatus.failed);
      expect(io.deleteRequests, isEmpty);
    });

    test("only verified files are in the single delete batch", () async {
      final good1 = io.add("1", "Good1.png", _png(_noisy()));
      final clear = _noisy(channels: 4)..getPixel(0, 0).a = 0;
      final transparent = io.add("2", "Clear.png", _png(clear));
      final flat = io.add("3", "Flat.png", _png(_flat()));
      final good2 = io.add("4", "Good2.png", _png(_noisy(width: 40)));
      final broken = io.add("5", "Broken.png", _png(_noisy(height: 40)));
      // Only the last file gets a damaged copy on the device.
      var saves = 0;
      io.onStep = (step) {
        if (step == "save") saves++;
        io.corruptSaved = saves >= 3 ? (b) => Uint8List(0) : null;
      };

      final progress = <int>[];
      final summary = await converter.run(
        [good1, transparent, flat, good2, broken],
        quality: 90,
        onProgress: (done, total, current) => progress.add(done),
      );

      expect(io.deleteRequests, [
        ["1", "4"],
      ]);
      expect(io.log.where((s) => s == "delete").length, 1);
      expect(io.log.last, "delete");
      expect(summary.results.map((r) => r.status), [
        PngConversionStatus.converted,
        PngConversionStatus.skippedTransparency,
        PngConversionStatus.skippedNoSaving,
        PngConversionStatus.converted,
        PngConversionStatus.failed,
      ]);
      expect(summary.count(PngConversionStatus.converted), 2);
      expect(progress, [0, 1, 2, 3, 4, 5]);
      expect(io.files.containsKey(transparent.path), isTrue);
      expect(io.files.containsKey(flat.path), isTrue);
      expect(io.files.containsKey(broken.path), isTrue);
    });

    test("no delete request when nothing was converted", () async {
      final flat = io.add("1", "Flat.png", _png(_flat()));
      await converter.run([flat], quality: 90);
      expect(io.log, isNot(contains("delete")));
    });

    test("a denied delete keeps both files, retry finishes the job", () async {
      final a = io.add("1", "A.png", _png(_noisy()));
      final b = io.add("2", "B.png", _png(_noisy(width: 40)));
      io.denyDelete = true;

      var summary = await converter.run([a, b], quality: 90);
      expect(summary.originalsKept.length, 2);
      expect(summary.savedBytes, 0);
      expect(io.files.containsKey(a.path), isTrue);
      expect(io.files.containsKey(summary.results.first.saved!.path), isTrue);

      io.denyDelete = false;
      summary = await converter.retryDelete(summary);
      expect(summary.originalsKept, isEmpty);
      expect(summary.count(PngConversionStatus.converted), 2);
      expect(io.deleteRequests, [
        ["1", "2"],
        ["1", "2"],
      ]);
      expect(io.files.containsKey(a.path), isFalse);
    });

    test("a delete that throws keeps both files", () async {
      final a = io.add("1", "A.png", _png(_noisy()));
      io.throwOnDelete = true;
      final summary = await converter.run([a], quality: 90);
      expect(summary.results.single.status, PngConversionStatus.originalKept);
      expect(io.files.containsKey(a.path), isTrue);
    });

    test("roll back removes the new JPEGs and never the PNGs", () async {
      final a = io.add("1", "A.png", _png(_noisy()));
      io.denyDelete = true;
      var summary = await converter.run([a], quality: 90);
      final jpegPath = summary.results.single.saved!.path;

      summary = await converter.rollBack(summary);
      expect(summary.results.single.status, PngConversionStatus.rolledBack);
      expect(io.files.containsKey(jpegPath), isFalse);
      expect(io.files.containsKey(a.path), isTrue);
      expect(io.deleteRequests.length, 1);

      // Nothing is left to delete or to roll back.
      await converter.retryDelete(summary);
      expect(io.deleteRequests.length, 1);
    });

    test("a failed roll back leaves the state unchanged", () async {
      final a = io.add("1", "A.png", _png(_noisy()));
      io.denyDelete = true;
      var summary = await converter.run([a], quality: 90);
      io.failDiscard = true;
      summary = await converter.rollBack(summary);
      expect(summary.results.single.status, PngConversionStatus.originalKept);
    });

    test(
      "cancel stops before the next file and finishes the done ones",
      () async {
        final a = io.add("1", "A.png", _png(_noisy()));
        final b = io.add("2", "B.png", _png(_noisy(width: 40)));
        final c = io.add("3", "C.png", _png(_noisy(height: 40)));
        var cancelled = false;
        // The request arrives in the middle of the first file.
        io.onStep = (step) {
          if (step == "encode") cancelled = true;
        };

        final summary = await converter.run(
          [a, b, c],
          quality: 90,
          isCancelled: () => cancelled,
        );

        expect(summary.results.length, 1);
        expect(summary.results.single.status, PngConversionStatus.converted);
        expect(summary.notProcessed, 2);
        expect(io.log.where((s) => s == "encode").length, 1);
        expect(io.deleteRequests, [
          ["1"],
        ]);
        expect(io.files.containsKey(b.path), isTrue);
        expect(io.files.containsKey(c.path), isTrue);
        // No partly written file: the folder has B, C and the JPEG of A.
        expect(io.files.length, 3);
      },
    );

    test("reports a dropped ICC profile", () async {
      // Insert an iCCP chunk into a real PNG, directly after IHDR.
      final png = _png(_noisy());
      const ihdrEnd = 8 + 8 + 13 + 4;
      final withIcc = BytesBuilder()
        ..add(Uint8List.sublistView(png, 0, ihdrEnd))
        ..add(_chunk("iCCP", [1, 2, 3, 4]))
        ..add(Uint8List.sublistView(png, ihdrEnd));
      final bytes = withIcc.toBytes();
      expect(parsePngHeader(bytes)!.hasIccProfile, isTrue);

      final c = io.add("1", "Wide.png", bytes);
      io.encoder = (_, quality) => img.encodeJpg(_noisy(), quality: quality);
      final summary = await converter.run([c], quality: 90);
      expect(summary.results.single.status, PngConversionStatus.converted);
      expect(summary.droppedIccProfiles, 1);
    });
  });
}

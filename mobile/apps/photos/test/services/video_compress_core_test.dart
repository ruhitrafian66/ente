import "package:flutter_test/flutter_test.dart";
import "package:photos/services/video_compress_core.dart";

const _mb = 1024 * 1024;

VideoFacts _facts({
  String? mime = "video/avc",
  int width = 1920,
  int height = 1080,
  int rotation = 0,
  int durationMs = 5000,
  double? frameRate = 24,
  int? frameCount,
  int? audioBitrate = 192000,
  int videoTracks = 1,
  int audioTracks = 1,
  int otherTracks = 0,
  bool isHdr = false,
}) {
  return VideoFacts(
    videoMimeType: mime,
    width: width,
    height: height,
    rotationDegrees: rotation,
    durationMs: durationMs,
    frameRate: frameRate,
    frameCount: frameCount,
    audioBitrate: audioBitrate,
    videoTrackCount: videoTracks,
    audioTrackCount: audioTracks,
    otherTrackCount: otherTracks,
    isHdr: isHdr,
  );
}

VideoCandidate _candidate({
  String id = "1",
  String title = "clip.mp4",
  int sizeBytes = 6 * _mb,
  String? relativePath = "DCIM/Camera/",
  VideoFacts? facts,
}) {
  return VideoCandidate(
    id: id,
    title: title,
    path: "/storage/emulated/0/DCIM/Camera/$title",
    sizeBytes: sizeBytes,
    captureTime: DateTime(2024, 3, 9, 18, 5, 42),
    relativePath: relativePath,
    facts: facts ?? _facts(),
  );
}

VideoFacts _hevcOf(VideoFacts source, {int? durationMs, int? frameCount}) {
  return VideoFacts(
    videoMimeType: "video/hevc",
    width: source.width,
    height: source.height,
    rotationDegrees: source.rotationDegrees,
    durationMs: durationMs ?? source.durationMs,
    frameRate: source.frameRate,
    frameCount: frameCount ?? source.frameCount,
    videoTrackCount: 1,
    audioTrackCount: source.audioTrackCount,
  );
}

class _FakeIo implements VideoCompressIo {
  /// Output size as a fraction of the source.
  double outputFraction = 0.5;
  bool reEncodes = true;
  bool cancelEncode = false;
  Object? encodeError;
  VideoFacts Function(VideoFacts source)? outputFacts;
  int? savedSizeOverride;
  String? savedFolderOverride;
  bool refuseDelete = false;
  final Set<String> existingNames = {};

  final List<int> bitrates = [];
  final List<String> discardedEncoded = [];
  final List<SavedVideo> saved = [];
  final List<SavedVideo> discardedSaved = [];
  final List<List<String>> deleteRequests = [];
  final Map<String, VideoFacts> _factsByPath = {};
  final Map<String, int> _sizeByPath = {};

  @override
  Future<EncodedVideo> encode(
    VideoCandidate candidate, {
    required int videoBitrate,
    void Function(double fraction)? onProgress,
  }) async {
    if (cancelEncode) throw const VideoEncodeCancelled();
    if (encodeError != null) throw encodeError!;
    bitrates.add(videoBitrate);
    onProgress?.call(0.5);
    final path = "/cache/encode_${candidate.id}.mp4";
    final size = (candidate.sizeBytes * outputFraction).round();
    _factsByPath[path] = (outputFacts ?? _hevcOf)(candidate.facts);
    _sizeByPath[path] = size;
    return EncodedVideo(
      path: path,
      sizeBytes: size,
      isVideoReEncoded: reEncodes,
    );
  }

  @override
  Future<VideoFacts> probe(String path) async => _factsByPath[path]!;

  @override
  Future<bool> fileExists(String path) async =>
      existingNames.contains(path.split("/").last);

  @override
  Future<SavedVideo> saveVideo(
    EncodedVideo encoded, {
    required String name,
    required VideoCandidate source,
  }) async {
    final folder =
        savedFolderOverride ??
        source.path.substring(0, source.path.lastIndexOf("/"));
    final result = SavedVideo(
      id: "new_${source.id}",
      path: "$folder/$name",
      name: name,
    );
    _factsByPath[result.path] = _factsByPath[encoded.path]!;
    _sizeByPath[result.path] = savedSizeOverride ?? encoded.sizeBytes;
    saved.add(result);
    return result;
  }

  @override
  Future<int> savedSize(SavedVideo saved) async => _sizeByPath[saved.path]!;

  @override
  Future<void> discardEncoded(String path) async => discardedEncoded.add(path);

  @override
  Future<void> discardSaved(SavedVideo saved) async =>
      discardedSaved.add(saved);

  @override
  Future<Set<String>> deleteOriginals(List<VideoCandidate> originals) async {
    deleteRequests.add(originals.map((o) => o.id).toList());
    if (refuseDelete) return {};
    return originals.map((o) => o.id).toSet();
  }
}

void main() {
  group("referenceHevcBitrate", () {
    test("is the reference value at 1080p30", () {
      expect(
        referenceHevcBitrate(width: 1920, height: 1080, frameRate: 30),
        kVideoCompressReferenceBitrate,
      );
    });

    test("grows slower than the pixel count", () {
      final uhd = referenceHevcBitrate(
        width: 3840,
        height: 2160,
        frameRate: 30,
      );
      expect(uhd, greaterThan(2 * kVideoCompressReferenceBitrate));
      expect(uhd, lessThan(4 * kVideoCompressReferenceBitrate));
    });

    test("is the same for portrait and landscape", () {
      expect(
        referenceHevcBitrate(width: 1080, height: 1920, frameRate: 30),
        referenceHevcBitrate(width: 1920, height: 1080, frameRate: 30),
      );
    });

    test("uses 30 frames per second when the rate is unknown", () {
      expect(
        referenceHevcBitrate(width: 1920, height: 1080),
        kVideoCompressReferenceBitrate,
      );
    });

    test("the higher-quality preset asks for more", () {
      expect(
        referenceHevcBitrate(
          width: 1920,
          height: 1080,
          frameRate: 30,
          preset: VideoCompressPreset.higherQuality,
        ),
        greaterThan(kVideoCompressReferenceBitrate),
      );
    });
  });

  group("planVideoCompression", () {
    VideoCompressPlan plan({
      String? title = "clip.mp4",
      String? relativePath = "DCIM/Camera/",
      int sizeBytes = 6 * _mb,
      VideoFacts? facts,
    }) {
      return planVideoCompression(
        title: title,
        relativePath: relativePath,
        sizeBytes: sizeBytes,
        facts: facts ?? _facts(),
      );
    }

    test("a 6 MB, 5 s, 1080p24 H.264 clip saves about half", () {
      final result = plan();
      expect(result.isEligible, isTrue);
      expect(result.targetVideoBitrate, inInclusiveRange(4000000, 5000000));
      expect(
        result.estimatedSavingBytes / (6 * _mb),
        inInclusiveRange(0.4, 0.6),
      );
    });

    test("a lean H.264 source is left alone", () {
      // 2 MB in 5 s is about 3.2 Mbit/s: below the HEVC reference.
      expect(
        plan(sizeBytes: 2 * _mb).skipReason,
        VideoSkipReason.alreadyCompact,
      );
    });

    test("the target is never above the codec ratio of an H.264 source", () {
      // About 6.5 Mbit/s of video: above the reference, below reference/0.65.
      final facts = _facts(durationMs: 10000);
      const size = 8370000;
      final result = plan(sizeBytes: size, facts: facts);
      final source = sourceVideoBitrate(sizeBytes: size, facts: facts);
      expect(result.isEligible, isTrue);
      expect(
        result.targetVideoBitrate,
        (source * kVideoCompressOldCodecRatio).round(),
      );
    });

    test("an HEVC source needs a much higher bitrate to be offered", () {
      final hevc = _facts(mime: "video/hevc");
      expect(
        plan(facts: hevc, sizeBytes: 4 * _mb).skipReason,
        VideoSkipReason.alreadyCompact,
      );
      expect(plan(facts: hevc, sizeBytes: 12 * _mb).isEligible, isTrue);
    });

    test("skips what a re-encode would damage", () {
      expect(plan(facts: _facts(isHdr: true)).skipReason, VideoSkipReason.hdr);
      expect(
        plan(facts: _facts(mime: "video/dolby-vision", isHdr: true)).skipReason,
        VideoSkipReason.hdr,
      );
      expect(
        plan(facts: _facts(otherTracks: 1)).skipReason,
        VideoSkipReason.extraTracks,
      );
      expect(
        plan(facts: _facts(audioTracks: 2)).skipReason,
        VideoSkipReason.extraTracks,
      );
      expect(
        plan(facts: _facts(frameRate: 240)).skipReason,
        VideoSkipReason.highFrameRate,
      );
      expect(
        plan(facts: _facts(mime: "video/x-motion-jpeg")).skipReason,
        VideoSkipReason.unsupportedCodec,
      );
      expect(
        plan(facts: _facts(durationMs: 400)).skipReason,
        VideoSkipReason.tooShort,
      );
    });

    test("skips containers and folders that cannot be written", () {
      expect(
        plan(title: "clip.mkv").skipReason,
        VideoSkipReason.unsupportedContainer,
      );
      expect(
        plan(relativePath: "Download/").skipReason,
        VideoSkipReason.folderNotWritable,
      );
      expect(
        plan(relativePath: null).skipReason,
        VideoSkipReason.folderNotWritable,
      );
      expect(plan(relativePath: "Movies/Trips/").isEligible, isTrue);
      expect(plan(relativePath: "Pictures/People/Ann/").isEligible, isTrue);
    });

    test("a video without audio is planned from the whole file", () {
      final result = plan(facts: _facts(audioTracks: 0, audioBitrate: null));
      expect(result.isEligible, isTrue);
      expect(
        result.estimatedOutputBytes,
        (result.targetVideoBitrate * 5 / 8).round(),
      );
    });
  });

  group("compareVideoFacts", () {
    final source = _facts(frameCount: 120);

    test("accepts a faithful HEVC copy", () {
      expect(
        compareVideoFacts(source: source, output: _hevcOf(source)),
        isNull,
      );
    });

    test("accepts a copy with the rotation moved into the pixels", () {
      final portrait = _facts(rotation: 90);
      final output = VideoFacts(
        videoMimeType: "video/hevc",
        width: 1080,
        height: 1920,
        durationMs: portrait.durationMs,
      );
      expect(compareVideoFacts(source: portrait, output: output), isNull);
    });

    test("rejects a different codec, size, duration, audio or frame count", () {
      expect(
        compareVideoFacts(source: source, output: source),
        contains("not HEVC"),
      );
      expect(
        compareVideoFacts(
          source: source,
          output: VideoFacts(
            videoMimeType: "video/hevc",
            width: 1280,
            height: 720,
            durationMs: source.durationMs,
          ),
        ),
        contains("dimensions"),
      );
      expect(
        compareVideoFacts(
          source: source,
          output: _hevcOf(source, durationMs: 4000),
        ),
        contains("duration"),
      );
      expect(
        compareVideoFacts(
          source: source,
          output: VideoFacts(
            videoMimeType: "video/hevc",
            width: 1920,
            height: 1080,
            durationMs: source.durationMs,
            audioTrackCount: 0,
          ),
        ),
        contains("audio"),
      );
      expect(
        compareVideoFacts(
          source: source,
          output: _hevcOf(source),
          outputFrameCount: 100,
        ),
        contains("frame count"),
      );
    });
  });

  group("names", () {
    test("adds the suffix and the mp4 extension", () {
      expect(
        compressedNameFor("20240309_180542.mp4"),
        "20240309_180542_hevc.mp4",
      );
      expect(compressedNameFor("IMG_0001.MOV"), "IMG_0001_hevc.mp4");
      expect(compressedNameFor("clip.mp4", 2), "clip_hevc (2).mp4");
    });

    test("picks a free name", () async {
      final taken = {"clip_hevc.mp4", "clip_hevc (1).mp4"};
      expect(
        await pickCompressedName("clip.mp4", (n) async => taken.contains(n)),
        "clip_hevc (2).mp4",
      );
    });
  });

  group("VideoCompressor", () {
    const preset = VideoCompressPreset.balanced;

    test("compresses, verifies, then deletes the original", () async {
      final io = _FakeIo();
      final summary = await VideoCompressor(
        io,
      ).run([_candidate()], preset: preset);

      final result = summary.results.single;
      expect(result.status, VideoCompressStatus.compressed);
      expect(result.saved!.name, "clip_hevc.mp4");
      expect(summary.savedBytes, 3 * _mb);
      expect(io.deleteRequests, [
        ["1"],
      ]);
      expect(io.discardedEncoded, ["/cache/encode_1.mp4"]);
      expect(io.discardedSaved, isEmpty);
      expect(io.bitrates.single, _candidate().plan(preset).targetVideoBitrate);
    });

    test("keeps the original when the saving is too small", () async {
      final io = _FakeIo()..outputFraction = 0.9;
      final summary = await VideoCompressor(
        io,
      ).run([_candidate()], preset: preset);

      expect(
        summary.results.single.status,
        VideoCompressStatus.skippedNoSaving,
      );
      expect(io.saved, isEmpty);
      expect(io.deleteRequests, isEmpty);
      expect(io.discardedEncoded, hasLength(1));
    });

    test("fails when the encoder only copied the video", () async {
      final io = _FakeIo()..reEncodes = false;
      final summary = await VideoCompressor(
        io,
      ).run([_candidate()], preset: preset);

      expect(summary.results.single.status, VideoCompressStatus.failed);
      expect(io.saved, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test("fails when the output differs from the source", () async {
      final io = _FakeIo()
        ..outputFacts = (source) => _hevcOf(source, durationMs: 1000);
      final summary = await VideoCompressor(
        io,
      ).run([_candidate()], preset: preset);

      final result = summary.results.single;
      expect(result.status, VideoCompressStatus.failed);
      expect(result.message, contains("duration"));
      expect(io.saved, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test("removes a saved copy that fails the check", () async {
      for (final io in [
        _FakeIo()..savedSizeOverride = 10,
        _FakeIo()..savedFolderOverride = "/storage/emulated/0/Movies",
      ]) {
        final summary = await VideoCompressor(
          io,
        ).run([_candidate()], preset: preset);

        expect(summary.results.single.status, VideoCompressStatus.failed);
        expect(io.discardedSaved, hasLength(1));
        expect(io.deleteRequests, isEmpty);
      }
    });

    test("an encoder error fails one file and the run goes on", () async {
      final io = _FakeIo()..encodeError = StateError("no encoder");
      final summary = await VideoCompressor(
        io,
      ).run([_candidate(id: "1"), _candidate(id: "2")], preset: preset);

      expect(summary.count(VideoCompressStatus.failed), 2);
      expect(summary.notProcessed, 0);
      expect(io.deleteRequests, isEmpty);
    });

    test("does not encode a video that is not eligible", () async {
      final io = _FakeIo();
      final summary = await VideoCompressor(
        io,
      ).run([_candidate(facts: _facts(isHdr: true))], preset: preset);

      expect(
        summary.results.single.status,
        VideoCompressStatus.skippedNotEligible,
      );
      expect(io.bitrates, isEmpty);
    });

    test(
      "a cancel before a file stops the run and deletes what is done",
      () async {
        final io = _FakeIo();
        var calls = 0;
        final summary = await VideoCompressor(io).run(
          [_candidate(id: "1"), _candidate(id: "2"), _candidate(id: "3")],
          preset: preset,
          isCancelled: () => calls++ >= 1,
        );

        expect(summary.results, hasLength(1));
        expect(summary.notProcessed, 2);
        expect(summary.results.single.status, VideoCompressStatus.compressed);
        expect(io.deleteRequests, [
          ["1"],
        ]);
      },
    );

    test("a cancelled encode keeps its original", () async {
      final io = _FakeIo()..cancelEncode = true;
      final summary = await VideoCompressor(
        io,
      ).run([_candidate(id: "1"), _candidate(id: "2")], preset: preset);

      expect(summary.results, isEmpty);
      expect(summary.notProcessed, 2);
      expect(io.saved, isEmpty);
      expect(io.deleteRequests, isEmpty);
    });

    test(
      "a refused delete keeps both files, then retry or roll back",
      () async {
        final io = _FakeIo()..refuseDelete = true;
        final compressor = VideoCompressor(io);
        final summary = await compressor.run([_candidate()], preset: preset);

        expect(summary.results.single.status, VideoCompressStatus.originalKept);
        expect(summary.savedBytes, 0);
        expect(io.discardedSaved, isEmpty);

        final rolledBack = await compressor.rollBack(summary);
        expect(
          rolledBack.results.single.status,
          VideoCompressStatus.rolledBack,
        );
        expect(io.discardedSaved, hasLength(1));

        io.refuseDelete = false;
        final retried = await compressor.retryDelete(summary);
        expect(retried.results.single.status, VideoCompressStatus.compressed);
        expect(retried.savedBytes, 3 * _mb);
      },
    );

    test("uses the next free name in the folder", () async {
      final io = _FakeIo()..existingNames.add("clip_hevc.mp4");
      final summary = await VideoCompressor(
        io,
      ).run([_candidate()], preset: preset);

      expect(summary.results.single.saved!.name, "clip_hevc (1).mp4");
    });

    test("reports the progress of the current file", () async {
      final io = _FakeIo();
      final events = <String>[];
      await VideoCompressor(io).run(
        [_candidate()],
        preset: preset,
        onProgress: (done, total, current, fraction) =>
            events.add("$done/$total ${current?.id} $fraction"),
      );

      expect(events, ["0/1 1 0.0", "0/1 1 0.5", "1/1 null 0.0"]);
    });
  });
}

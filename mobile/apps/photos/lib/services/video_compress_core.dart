// Offline fork: pure logic for the "Compress videos" tool.
//
// This file must stay free of Flutter, plugin and app imports so that the unit
// tests can run it in isolation. All device work (probe, encode, MediaStore
// save, delete) goes through [VideoCompressIo], which the app implements in
// video_compress_service.dart and the tests replace with fakes.
//
// The tool re-encodes a video to HEVC with the hardware encoder. The pixel
// dimensions, the frame rate and the audio stay as they are; only the video
// bitrate goes down. The bitrate rule below is conservative: a video is
// re-encoded only when its bitrate is clearly above what HEVC needs for the
// same picture, and the result is kept only when it is clearly smaller.

import "dart:math" as math;

import "package:path/path.dart" as p;

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

/// HEVC video bitrate (bits per second) for 1920x1080 at 30 frames per second
/// that the tool treats as visually equal to a camera original.
const int kVideoCompressReferenceBitrate = 5000000;
const int _referencePixels = 1920 * 1080;
const double _referenceFrameRate = 30;

/// The bitrate grows slower than the pixel count and the frame rate.
const double _pixelExponent = 0.75;
const double _frameRateExponent = 0.5;

/// The hardware HEVC encoder needs about this fraction of the bitrate of an
/// older codec (H.264, MPEG-4) for the same picture. The target is never
/// above this fraction of such a source: more bits cannot add detail.
const double kVideoCompressOldCodecRatio = 0.65;

/// A source that already uses a modern codec (HEVC, VP9, AV1) is re-encoded
/// only when its bitrate is at least this many times the target.
const double kVideoCompressModernCodecMinRatio = 1.75;

/// A video is offered only when the expected saving is at least this fraction
/// of the file.
const double kVideoCompressMinExpectedSaving = 0.25;

/// A result is kept only if it is at least this much smaller than the source.
const double kVideoCompressMinSavingFraction = 0.20;

/// Seconds between key frames in the output.
const double kVideoCompressKeyFrameIntervalSeconds = 2;

/// Assumed audio bitrate when the container does not state one.
const int kVideoCompressAssumedAudioBitrate = 192000;

/// Frame rates above this are slow-motion or special recordings. Skipped.
const double kVideoCompressMaxFrameRate = 65;

const int kVideoCompressMinDurationMs = 1000;

const String kVideoCompressOutputMimeType = "video/hevc";

/// Android lets an app create a video only below these top-level folders.
const Set<String> kVideoCompressWritableRoots = {"dcim", "movies", "pictures"};

const Set<String> _videoExtensions = {".mp4", ".mov", ".m4v", ".3gp"};
const Set<String> _oldCodecs = {"video/avc", "video/mp4v-es", "video/3gpp"};
const Set<String> _modernCodecs = {
  "video/hevc",
  "video/x-vnd.on2.vp9",
  "video/av01",
};

enum VideoCompressPreset {
  /// The default: the reference bitrate.
  balanced(1.0, "Balanced"),

  /// 40% more bitrate, for less saving.
  higherQuality(1.4, "Higher quality");

  final double bitrateFactor;
  final String label;

  const VideoCompressPreset(this.bitrateFactor, this.label);
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// What the container says about a video file.
class VideoFacts {
  final String? videoMimeType;

  /// Encoded pixels, before the rotation is applied.
  final int width;
  final int height;
  final int rotationDegrees;
  final int durationMs;
  final double? frameRate;
  final int? frameCount;
  final int? videoBitrate;
  final int? audioBitrate;
  final int videoTrackCount;
  final int audioTrackCount;

  /// Tracks that are neither video nor audio. A re-encode drops them.
  final int otherTrackCount;
  final bool isHdr;

  const VideoFacts({
    required this.videoMimeType,
    required this.width,
    required this.height,
    this.rotationDegrees = 0,
    required this.durationMs,
    this.frameRate,
    this.frameCount,
    this.videoBitrate,
    this.audioBitrate,
    this.videoTrackCount = 1,
    this.audioTrackCount = 1,
    this.otherTrackCount = 0,
    this.isHdr = false,
  });

  bool get _isQuarterTurned => rotationDegrees == 90 || rotationDegrees == 270;

  int get displayWidth => _isQuarterTurned ? height : width;

  int get displayHeight => _isQuarterTurned ? width : height;
}

enum VideoSkipReason {
  unsupportedContainer("File type is not supported"),
  unsupportedCodec("Video codec is not supported"),
  hdr("HDR video"),
  extraTracks("Has extra tracks"),
  highFrameRate("Slow-motion or high frame rate"),
  tooShort("Shorter than 1 second"),
  folderNotWritable("Folder does not accept new videos"),
  alreadyCompact("Already compact");

  final String label;

  const VideoSkipReason(this.label);
}

/// The decision for one video.
class VideoCompressPlan {
  /// Null when the video is worth a re-encode.
  final VideoSkipReason? skipReason;

  /// Bits per second for the encoder. Zero when skipped.
  final int targetVideoBitrate;
  final int estimatedOutputBytes;
  final int estimatedSavingBytes;

  const VideoCompressPlan.skip(VideoSkipReason reason)
    : skipReason = reason,
      targetVideoBitrate = 0,
      estimatedOutputBytes = 0,
      estimatedSavingBytes = 0;

  const VideoCompressPlan.encode({
    required this.targetVideoBitrate,
    required this.estimatedOutputBytes,
    required this.estimatedSavingBytes,
  }) : skipReason = null;

  bool get isEligible => skipReason == null;
}

// ---------------------------------------------------------------------------
// Bitrate rule
// ---------------------------------------------------------------------------

bool hasVideoExtension(String? title) {
  if (title == null) return false;
  return _videoExtensions.contains(p.extension(title).toLowerCase());
}

/// True when MediaStore lets the app create a video in [relativePath]
/// (for example "DCIM/Camera/").
bool isVideoFolderWritable(String? relativePath) {
  if (relativePath == null) return false;
  final parts = relativePath.split("/").where((part) => part.isNotEmpty);
  if (parts.isEmpty) return false;
  return kVideoCompressWritableRoots.contains(parts.first.toLowerCase());
}

/// The HEVC video bitrate that keeps the picture of a camera original at the
/// given size and frame rate.
int referenceHevcBitrate({
  required int width,
  required int height,
  double? frameRate,
  VideoCompressPreset preset = VideoCompressPreset.balanced,
}) {
  final pixels = math.max(1, width * height);
  final fps = (frameRate == null || frameRate <= 0 ? 30.0 : frameRate).clamp(
    15.0,
    60.0,
  );
  final bitrate =
      kVideoCompressReferenceBitrate *
      math.pow(pixels / _referencePixels, _pixelExponent) *
      math.pow(fps / _referenceFrameRate, _frameRateExponent) *
      preset.bitrateFactor;
  return bitrate.round();
}

/// Bits per second that all audio of the file uses.
int audioBitrateOf(VideoFacts facts) {
  if (facts.audioTrackCount <= 0) return 0;
  return facts.audioBitrate ?? kVideoCompressAssumedAudioBitrate;
}

/// Video bits per second, from the file size. The value that the container
/// states is only a fallback, because it is often a nominal value.
int sourceVideoBitrate({required int sizeBytes, required VideoFacts facts}) {
  if (facts.durationMs <= 0 || sizeBytes <= 0) return facts.videoBitrate ?? 0;
  final total = sizeBytes * 8 * 1000 / facts.durationMs;
  final video = total - audioBitrateOf(facts);
  if (video <= 0) return facts.videoBitrate ?? total.round();
  return video.round();
}

VideoCompressPlan planVideoCompression({
  required String? title,
  required String? relativePath,
  required int sizeBytes,
  required VideoFacts facts,
  VideoCompressPreset preset = VideoCompressPreset.balanced,
}) {
  if (!hasVideoExtension(title)) {
    return const VideoCompressPlan.skip(VideoSkipReason.unsupportedContainer);
  }
  final mimeType = facts.videoMimeType?.toLowerCase();
  final isOldCodec = _oldCodecs.contains(mimeType);
  if (facts.isHdr) {
    return const VideoCompressPlan.skip(VideoSkipReason.hdr);
  }
  if (!isOldCodec && !_modernCodecs.contains(mimeType)) {
    return const VideoCompressPlan.skip(VideoSkipReason.unsupportedCodec);
  }
  if (facts.videoTrackCount != 1 ||
      facts.audioTrackCount > 1 ||
      facts.otherTrackCount > 0) {
    return const VideoCompressPlan.skip(VideoSkipReason.extraTracks);
  }
  if ((facts.frameRate ?? 0) > kVideoCompressMaxFrameRate) {
    return const VideoCompressPlan.skip(VideoSkipReason.highFrameRate);
  }
  if (facts.durationMs < kVideoCompressMinDurationMs) {
    return const VideoCompressPlan.skip(VideoSkipReason.tooShort);
  }
  if (!isVideoFolderWritable(relativePath)) {
    return const VideoCompressPlan.skip(VideoSkipReason.folderNotWritable);
  }

  final source = sourceVideoBitrate(sizeBytes: sizeBytes, facts: facts);
  final reference = referenceHevcBitrate(
    width: facts.width,
    height: facts.height,
    frameRate: facts.frameRate,
    preset: preset,
  );
  const compact = VideoCompressPlan.skip(VideoSkipReason.alreadyCompact);
  final int target;
  if (isOldCodec) {
    // A source below the reference is already lean. A second lossy encode
    // of it would cost visible detail.
    if (source < reference) return compact;
    target = math.min(
      reference,
      (source * kVideoCompressOldCodecRatio).round(),
    );
  } else {
    if (source < reference * kVideoCompressModernCodecMinRatio) return compact;
    target = reference;
  }
  final outputBytes =
      ((target + audioBitrateOf(facts)) * facts.durationMs / 8000).round();
  final saving = sizeBytes - outputBytes;
  if (target <= 0 || saving < sizeBytes * kVideoCompressMinExpectedSaving) {
    return compact;
  }
  return VideoCompressPlan.encode(
    targetVideoBitrate: target,
    estimatedOutputBytes: outputBytes,
    estimatedSavingBytes: saving,
  );
}

/// The "keep only if smaller" rule.
bool isCompressedVideoWorthKeeping({
  required int sourceBytes,
  required int outputBytes,
  double minSavingFraction = kVideoCompressMinSavingFraction,
}) {
  if (sourceBytes <= 0 || outputBytes <= 0) return false;
  return outputBytes <= sourceBytes * (1 - minSavingFraction);
}

/// Returns null when [output] is a faithful re-encode of [source], else the
/// reason. Checks the codec, the displayed size, the duration, the audio
/// track and (when both are known) the frame count.
String? compareVideoFacts({
  required VideoFacts source,
  required VideoFacts output,
  int? outputFrameCount,
}) {
  if (output.videoMimeType?.toLowerCase() != kVideoCompressOutputMimeType) {
    return "The output is not HEVC (${output.videoMimeType ?? "unknown"})";
  }
  if (output.displayWidth != source.displayWidth ||
      output.displayHeight != source.displayHeight) {
    return "The output has different dimensions "
        "(${output.displayWidth}x${output.displayHeight}, source "
        "${source.displayWidth}x${source.displayHeight})";
  }
  final durationTolerance = math.max(500, source.durationMs ~/ 100);
  if ((output.durationMs - source.durationMs).abs() > durationTolerance) {
    return "The output has a different duration "
        "(${output.durationMs} ms, source ${source.durationMs} ms)";
  }
  if (output.videoTrackCount != 1) {
    return "The output has no single video track";
  }
  if (output.audioTrackCount != source.audioTrackCount) {
    return "The output has a different number of audio tracks";
  }
  final sourceFrames = source.frameCount;
  final outputFrames = outputFrameCount ?? output.frameCount;
  if (sourceFrames != null && outputFrames != null && outputFrames > 0) {
    final frameTolerance = math.max(2, sourceFrames ~/ 100);
    if ((outputFrames - sourceFrames).abs() > frameTolerance) {
      return "The output has a different frame count "
          "($outputFrames, source $sourceFrames)";
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Output naming
// ---------------------------------------------------------------------------

/// "20240309_180542.mp4" -> "20240309_180542_hevc.mp4". The original still
/// exists when the new file is saved, so the name must differ.
String compressedNameFor(String title, [int attempt = 0]) {
  final base = hasVideoExtension(title)
      ? p.basenameWithoutExtension(title)
      : title;
  final suffix = attempt == 0 ? "" : " ($attempt)";
  return "${base.isEmpty ? "video" : base}_hevc$suffix.mp4";
}

Future<String> pickCompressedName(
  String title,
  Future<bool> Function(String name) isTaken,
) async {
  for (var i = 0; i < 1000; i++) {
    final name = compressedNameFor(title, i);
    if (!await isTaken(name)) return name;
  }
  throw StateError("No free file name for $title");
}

// ---------------------------------------------------------------------------
// Conversion state machine
// ---------------------------------------------------------------------------

/// One video on the device that is worth a re-encode.
class VideoCandidate {
  /// Media library id (`EnteFile.localID`).
  final String id;
  final String title;
  final String path;
  final int sizeBytes;
  final DateTime captureTime;

  /// MediaStore RELATIVE_PATH of the folder, for example "DCIM/Camera/".
  final String? relativePath;
  final VideoFacts facts;

  const VideoCandidate({
    required this.id,
    required this.title,
    required this.path,
    required this.sizeBytes,
    required this.captureTime,
    required this.relativePath,
    required this.facts,
  });

  VideoCompressPlan plan(VideoCompressPreset preset) => planVideoCompression(
    title: title,
    relativePath: relativePath,
    sizeBytes: sizeBytes,
    facts: facts,
    preset: preset,
  );
}

/// The encoder output, in private app storage.
class EncodedVideo {
  final String path;
  final int sizeBytes;
  final bool isVideoReEncoded;
  final int? frameCount;

  const EncodedVideo({
    required this.path,
    required this.sizeBytes,
    required this.isVideoReEncoded,
    this.frameCount,
  });
}

/// A video that the tool wrote to the media library.
class SavedVideo {
  final String id;
  final String path;
  final String name;

  const SavedVideo({required this.id, required this.path, required this.name});
}

/// Thrown by [VideoCompressIo.encode] when the user stopped the encode.
class VideoEncodeCancelled implements Exception {
  const VideoEncodeCancelled();
}

enum VideoCompressStatus {
  /// New file saved and verified, original removed.
  compressed,

  /// New file saved and verified, but the device did not remove the original
  /// (for example the user denied the system prompt). Both files exist.
  originalKept,

  /// The new file of an [originalKept] video was removed again.
  rolledBack,
  skippedNotEligible,
  skippedNoSaving,
  failed,
}

class VideoCompressResult {
  final VideoCandidate candidate;
  final VideoCompressStatus status;
  final int outputBytes;
  final SavedVideo? saved;
  final String? message;

  const VideoCompressResult({
    required this.candidate,
    required this.status,
    this.outputBytes = 0,
    this.saved,
    this.message,
  });

  VideoCompressResult withStatus(VideoCompressStatus status) {
    return VideoCompressResult(
      candidate: candidate,
      status: status,
      outputBytes: outputBytes,
      saved: saved,
      message: message,
    );
  }

  int get savedBytes => status == VideoCompressStatus.compressed
      ? candidate.sizeBytes - outputBytes
      : 0;
}

class VideoCompressSummary {
  final List<VideoCompressResult> results;

  /// Selected files that were not finished because the user cancelled.
  final int notProcessed;

  const VideoCompressSummary({
    required this.results,
    required this.notProcessed,
  });

  int count(VideoCompressStatus status) =>
      results.where((r) => r.status == status).length;

  int get savedBytes => results.fold(0, (sum, r) => sum + r.savedBytes);

  List<VideoCompressResult> get originalsKept => results
      .where((r) => r.status == VideoCompressStatus.originalKept)
      .toList();
}

/// Device operations. Every method may throw; the compressor turns a throw
/// into a failed file and keeps the original.
abstract class VideoCompressIo {
  /// Re-encodes the video to HEVC at [videoBitrate] into private storage.
  /// Throws [VideoEncodeCancelled] when the user stopped it.
  Future<EncodedVideo> encode(
    VideoCandidate candidate, {
    required int videoBitrate,
    void Function(double fraction)? onProgress,
  });

  Future<VideoFacts> probe(String path);

  Future<bool> fileExists(String path);

  /// Copies [encoded] into the media library next to [source].
  Future<SavedVideo> saveVideo(
    EncodedVideo encoded, {
    required String name,
    required VideoCandidate source,
  });

  /// The size of the saved file as the device now has it. Zero or a throw
  /// means the file is not there.
  Future<int> savedSize(SavedVideo saved);

  /// Removes the encoder output from private storage.
  Future<void> discardEncoded(String path);

  /// Removes a video that this tool wrote to the media library.
  Future<void> discardSaved(SavedVideo saved);

  /// Removes the given originals in one batch (one system prompt). Returns
  /// the ids that are gone.
  Future<Set<String>> deleteOriginals(List<VideoCandidate> originals);
}

/// [fileFraction] is the progress of [current], from 0 to 1.
typedef VideoProgressCallback =
    void Function(
      int done,
      int total,
      VideoCandidate? current,
      double fileFraction,
    );

class VideoCompressor {
  final VideoCompressIo io;

  VideoCompressor(this.io);

  /// Re-encodes [candidates] one at a time, then removes the originals of all
  /// verified results in one batch.
  ///
  /// [isCancelled] is checked before each file. A cancelled encode leaves its
  /// original untouched; the originals of the files that are already done
  /// are still removed.
  Future<VideoCompressSummary> run(
    List<VideoCandidate> candidates, {
    required VideoCompressPreset preset,
    VideoProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final results = <VideoCompressResult>[];
    final pendingDelete = <int>[];
    var notProcessed = 0;

    for (var i = 0; i < candidates.length; i++) {
      if (isCancelled?.call() ?? false) {
        notProcessed = candidates.length - i;
        break;
      }
      final candidate = candidates[i];
      onProgress?.call(i, candidates.length, candidate, 0);
      final result = await compressOne(
        candidate,
        preset: preset,
        onProgress: (fraction) =>
            onProgress?.call(i, candidates.length, candidate, fraction),
      );
      if (result == null) {
        notProcessed = candidates.length - i;
        break;
      }
      if (result.status == VideoCompressStatus.originalKept) {
        pendingDelete.add(results.length);
      }
      results.add(result);
    }
    onProgress?.call(
      candidates.length - notProcessed,
      candidates.length,
      null,
      0,
    );

    await _deleteVerified(results, pendingDelete);
    return VideoCompressSummary(results: results, notProcessed: notProcessed);
  }

  /// Asks again to remove the originals that are still on the device.
  Future<VideoCompressSummary> retryDelete(VideoCompressSummary summary) async {
    final results = List<VideoCompressResult>.of(summary.results);
    final pending = <int>[
      for (var i = 0; i < results.length; i++)
        if (results[i].status == VideoCompressStatus.originalKept) i,
    ];
    await _deleteVerified(results, pending);
    return VideoCompressSummary(
      results: results,
      notProcessed: summary.notProcessed,
    );
  }

  /// Removes the new files whose original is still on the device, so that no
  /// duplicate stays behind.
  Future<VideoCompressSummary> rollBack(VideoCompressSummary summary) async {
    final results = List<VideoCompressResult>.of(summary.results);
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      if (result.status != VideoCompressStatus.originalKept) continue;
      try {
        await io.discardSaved(result.saved!);
        results[i] = result.withStatus(VideoCompressStatus.rolledBack);
      } catch (_) {
        // Both files stay. The status stays originalKept.
      }
    }
    return VideoCompressSummary(
      results: results,
      notProcessed: summary.notProcessed,
    );
  }

  Future<void> _deleteVerified(
    List<VideoCompressResult> results,
    List<int> pending,
  ) async {
    if (pending.isEmpty) return;
    // Only files with a saved and verified copy reach this point.
    final originals = [
      for (final index in pending)
        if (results[index].status == VideoCompressStatus.originalKept &&
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
        results[index] = result.withStatus(VideoCompressStatus.compressed);
      }
    }
  }

  /// encode -> check -> save -> verify. Returns
  /// [VideoCompressStatus.originalKept] when the new file is saved and
  /// verified; the original is never removed here. Returns null when the
  /// user cancelled the encode.
  Future<VideoCompressResult?> compressOne(
    VideoCandidate candidate, {
    required VideoCompressPreset preset,
    void Function(double fraction)? onProgress,
  }) async {
    VideoCompressResult done(
      VideoCompressStatus status, {
      String? message,
      int outputBytes = 0,
    }) {
      return VideoCompressResult(
        candidate: candidate,
        status: status,
        message: message,
        outputBytes: outputBytes,
      );
    }

    final plan = candidate.plan(preset);
    if (!plan.isEligible) {
      return done(
        VideoCompressStatus.skippedNotEligible,
        message: plan.skipReason!.label,
      );
    }

    String? encodedPath;
    SavedVideo? saved;
    try {
      final EncodedVideo encoded;
      try {
        encoded = await io.encode(
          candidate,
          videoBitrate: plan.targetVideoBitrate,
          onProgress: onProgress,
        );
      } on VideoEncodeCancelled {
        return null;
      }
      encodedPath = encoded.path;

      if (!encoded.isVideoReEncoded) {
        return done(
          VideoCompressStatus.failed,
          message: "The encoder copied the video and did not re-encode it",
        );
      }
      final outputFacts = await io.probe(encoded.path);
      final difference = compareVideoFacts(
        source: candidate.facts,
        output: outputFacts,
        outputFrameCount: encoded.frameCount,
      );
      if (difference != null) {
        return done(VideoCompressStatus.failed, message: difference);
      }
      if (!isCompressedVideoWorthKeeping(
        sourceBytes: candidate.sizeBytes,
        outputBytes: encoded.sizeBytes,
      )) {
        return done(
          VideoCompressStatus.skippedNoSaving,
          outputBytes: encoded.sizeBytes,
        );
      }

      final folder = p.dirname(candidate.path);
      final name = await pickCompressedName(
        candidate.title,
        (name) => io.fileExists(p.join(folder, name)),
      );
      saved = await io.saveVideo(encoded, name: name, source: candidate);

      final problem = await _verifySaved(saved, encoded, candidate, folder);
      if (problem != null) {
        await _discardSavedQuietly(saved);
        return done(VideoCompressStatus.failed, message: problem);
      }

      return VideoCompressResult(
        candidate: candidate,
        status: VideoCompressStatus.originalKept,
        outputBytes: encoded.sizeBytes,
        saved: saved,
      );
    } catch (e) {
      if (saved != null) {
        await _discardSavedQuietly(saved);
      }
      return done(VideoCompressStatus.failed, message: e.toString());
    } finally {
      if (encodedPath != null) {
        try {
          await io.discardEncoded(encodedPath);
        } catch (_) {
          // A leftover in the cache folder is removed with the next run.
        }
      }
    }
  }

  /// Returns null if the saved video is good, else the reason.
  Future<String?> _verifySaved(
    SavedVideo saved,
    EncodedVideo encoded,
    VideoCandidate candidate,
    String expectedFolder,
  ) async {
    if (saved.id.isEmpty) return "The device did not register the new video";
    if (p.dirname(saved.path) != expectedFolder) {
      return "The new video was saved in a different folder";
    }
    final size = await io.savedSize(saved);
    if (size <= 0) return "The saved video is empty";
    if (size != encoded.sizeBytes) return "The saved video has the wrong size";
    return compareVideoFacts(
      source: candidate.facts,
      output: await io.probe(saved.path),
    );
  }

  Future<void> _discardSavedQuietly(SavedVideo saved) async {
    try {
      await io.discardSaved(saved);
    } catch (_) {
      // Nothing more can be done; the original is untouched in every case.
    }
  }
}

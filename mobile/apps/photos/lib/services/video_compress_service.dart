// Offline fork: device side of the "Compress videos" tool.
//
// The rules (which video is worth a re-encode, the target bitrate, the
// encode -> check -> save -> verify -> delete order) live in
// video_compress_core.dart. This file only connects them to photo_manager,
// the native video plugin and the local database.

import "dart:io";
import "dart:math" show min;

import "package:logging/logging.dart";
import "package:native_video_editor/native_video_editor.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/constants.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/local_photos_updated_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/services/search_service.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:photos/services/video_compress_core.dart";

/// A video found on the device, with the gallery file that shows its
/// thumbnail.
class VideoScanItem {
  final VideoCandidate candidate;
  final EnteFile file;

  const VideoScanItem({required this.candidate, required this.file});
}

class VideoScanResult {
  /// Every readable video, largest first. The page filters by plan.
  final List<VideoScanItem> items;

  /// Videos that could not be read at all.
  final int unreadable;

  const VideoScanResult({required this.items, required this.unreadable});
}

/// Removes the given gallery files from the device in one request. Returns
/// the files that are gone.
typedef VideoOriginalsDeleter =
    Future<List<EnteFile>> Function(List<EnteFile> files);

class VideoCompressService {
  VideoCompressService._();

  static final VideoCompressService instance = VideoCompressService._();

  static const _scanConcurrency = 4;

  /// The system delete request takes a limited number of items.
  static const _deleteChunkSize = 1500;

  final _logger = Logger("VideoCompressService");

  /// Reads the container facts of every video on the device.
  Future<VideoScanResult> scan({
    void Function(int done, int total)? onProgress,
  }) async {
    await _clearWorkFolder();
    final allFiles = await SearchService.instance.getAllFilesForSearch();
    // The same asset is listed once for each device folder.
    final byLocalID = <String, EnteFile>{};
    for (final file in allFiles) {
      final localID = file.localID;
      if (localID == null ||
          localID.startsWith(sharedMediaIdentifier) ||
          file.fileType != FileType.video) {
        continue;
      }
      byLocalID.putIfAbsent(localID, () => file);
    }

    final files = byLocalID.values.toList();
    final items = <VideoScanItem>[];
    var unreadable = 0;
    for (var i = 0; i < files.length; i += _scanConcurrency) {
      final end = min(i + _scanConcurrency, files.length);
      final batch = await Future.wait(files.sublist(i, end).map(_inspect));
      for (final item in batch) {
        if (item == null) {
          unreadable++;
        } else {
          items.add(item);
        }
      }
      onProgress?.call(end, files.length);
    }
    items.sort(
      (a, b) => b.candidate.sizeBytes.compareTo(a.candidate.sizeBytes),
    );
    _logger.info("Read ${items.length} videos, $unreadable unreadable");
    return VideoScanResult(items: items, unreadable: unreadable);
  }

  Future<VideoScanItem?> _inspect(EnteFile file) async {
    try {
      final asset = await AssetEntity.fromId(file.localID!);
      if (asset == null || asset.type != AssetType.video) return null;
      final source = await asset.originFile;
      if (source == null) return null;
      final sizeBytes = await source.length();
      if (sizeBytes <= 0) return null;
      final facts = await _probe(source.path);

      final creationTime = file.creationTime ?? 0;
      return VideoScanItem(
        file: file,
        candidate: VideoCandidate(
          id: asset.id,
          title: asset.title ?? file.title ?? p.basename(source.path),
          path: source.path,
          sizeBytes: sizeBytes,
          // The gallery time is what places the file in the timeline.
          captureTime: creationTime > 0
              ? DateTime.fromMicrosecondsSinceEpoch(creationTime)
              : asset.createDateTime,
          relativePath: asset.relativePath,
          facts: facts,
        ),
      );
    } catch (e, s) {
      _logger.warning("Could not inspect a video", e, s);
      return null;
    }
  }

  /// A compressor whose delete step uses [deleteOriginals] (the page supplies
  /// it, because the delete helpers need a BuildContext).
  VideoCompressor compressor({
    required List<VideoScanItem> items,
    required VideoOriginalsDeleter deleteOriginals,
  }) {
    return VideoCompressor(
      _DeviceIo(
        filesByID: {for (final item in items) item.candidate.id: item.file},
        deleteOriginalFiles: deleteOriginals,
        chunkSize: _deleteChunkSize,
      ),
    );
  }

  /// Stops the encode that is in progress, if there is one.
  Future<void> cancelEncode() async {
    try {
      await NativeVideoEditor.cancelProcessing();
    } catch (e) {
      _logger.warning("Could not cancel the encode", e);
    }
  }

  /// Makes the gallery pick up the new videos. The delete helpers already
  /// report the removed originals.
  Future<void> refreshGallery() async {
    try {
      await LocalSyncService.instance.checkAndSync();
    } catch (e, s) {
      _logger.warning("Local sync after video compression failed", e, s);
    }
  }
}

Future<Directory> _workFolder() async {
  final cache = await getTemporaryDirectory();
  return Directory(p.join(cache.path, "video_compress"));
}

/// Removes encoder output that an earlier run left behind (for example after
/// the app was closed during an encode).
Future<void> _clearWorkFolder() async {
  try {
    final folder = await _workFolder();
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }
  } catch (_) {
    // The folder is in the app cache; Android can clear it too.
  }
}

Future<VideoFacts> _probe(String path) async {
  final probe = await NativeVideoEditor.probeVideo(path);
  return VideoFacts(
    videoMimeType: probe.videoMimeType,
    width: probe.width,
    height: probe.height,
    rotationDegrees: probe.rotationDegrees,
    durationMs: probe.duration.inMilliseconds,
    frameRate: probe.frameRate,
    frameCount: probe.frameCount,
    videoBitrate: probe.videoBitrate,
    audioBitrate: probe.audioBitrate,
    videoTrackCount: probe.videoTrackCount,
    audioTrackCount: probe.audioTrackCount,
    otherTrackCount: probe.otherTrackCount,
    isHdr: probe.isHdr,
  );
}

class _DeviceIo implements VideoCompressIo {
  final Map<String, EnteFile> filesByID;
  final VideoOriginalsDeleter deleteOriginalFiles;
  final int chunkSize;
  final _logger = Logger("VideoCompressDeviceIo");
  var _counter = 0;

  _DeviceIo({
    required this.filesByID,
    required this.deleteOriginalFiles,
    required this.chunkSize,
  });

  @override
  Future<EncodedVideo> encode(
    VideoCandidate candidate, {
    required int videoBitrate,
    void Function(double fraction)? onProgress,
  }) async {
    final folder = await _workFolder();
    await folder.create(recursive: true);
    final outputPath = p.join(folder.path, "encode_${_counter++}.mp4");
    final watch = Stopwatch()..start();
    try {
      final result = await NativeVideoEditor.compressVideo(
        inputPath: candidate.path,
        outputPath: outputPath,
        videoBitrate: videoBitrate,
        iFrameIntervalSeconds: kVideoCompressKeyFrameIntervalSeconds,
        creationTime: candidate.captureTime,
        onProgress: onProgress,
      );
      watch.stop();
      final seconds = watch.elapsedMilliseconds / 1000;
      final speed = seconds <= 0
          ? 0
          : candidate.facts.durationMs / 1000 / seconds;
      // One line per file: this is the performance record of the tool.
      _logger.info(
        "Encoded ${candidate.facts.width}x${candidate.facts.height} "
        "${candidate.facts.frameRate?.toStringAsFixed(1) ?? "?"} fps "
        "${candidate.facts.videoMimeType} "
        "${(candidate.facts.durationMs / 1000).toStringAsFixed(1)} s: "
        "${candidate.sizeBytes} -> ${result.fileSizeBytes} bytes in "
        "${seconds.toStringAsFixed(1)} s (${speed.toStringAsFixed(2)}x "
        "real time), target $videoBitrate bit/s, actual "
        "${result.averageVideoBitrate} bit/s, ${result.videoEncoderName}",
      );
      return EncodedVideo(
        path: result.outputPath,
        sizeBytes: result.fileSizeBytes,
        isVideoReEncoded: result.isVideoReEncoded,
        frameCount: result.videoFrameCount > 0 ? result.videoFrameCount : null,
      );
    } on NativeVideoEditorException catch (e) {
      if (e.code == "PROCESS_CANCELLED") {
        throw const VideoEncodeCancelled();
      }
      rethrow;
    }
  }

  @override
  Future<VideoFacts> probe(String path) => _probe(path);

  @override
  Future<bool> fileExists(String path) => File(path).exists();

  @override
  Future<SavedVideo> saveVideo(
    EncodedVideo encoded, {
    required String name,
    required VideoCandidate source,
  }) async {
    final relativePath = source.relativePath;
    if (relativePath == null || relativePath.trim().isEmpty) {
      throw StateError("The folder of the video is not known");
    }
    final asset = await PhotoManager.editor.saveVideo(
      File(encoded.path),
      title: name,
      relativePath: relativePath,
      creationDate: source.captureTime,
    );
    final file = await asset.originFile;
    return SavedVideo(
      id: asset.id,
      path: file?.path ?? "",
      name: asset.title ?? name,
    );
  }

  @override
  Future<int> savedSize(SavedVideo saved) async {
    final asset = await AssetEntity.fromId(saved.id);
    if (asset == null || !await asset.exists) {
      throw StateError("The new video is not in the media library");
    }
    return File(saved.path).length();
  }

  @override
  Future<void> discardEncoded(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> discardSaved(SavedVideo saved) async {
    // The app owns this file, so a direct delete needs no system prompt.
    if (saved.path.isNotEmpty) {
      final file = File(saved.path);
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        _logger.warning("Direct delete of a new video failed", e);
      }
    }
    final asset = saved.id.isEmpty ? null : await AssetEntity.fromId(saved.id);
    if (asset != null && await asset.exists) {
      final removed = await PhotoManager.editor.deleteWithIds([saved.id]);
      if (!removed.contains(saved.id)) {
        throw StateError("Could not remove the new video");
      }
    }
    if (saved.id.isEmpty) return;
    // Local sync may have listed the new video already.
    final rows = await FilesDB.instance.getLocalFiles([saved.id]);
    if (rows.isEmpty) return;
    await FilesDB.instance.deleteLocalFile(rows.first);
    Bus.instance.fire(
      LocalPhotosUpdatedEvent(
        rows,
        type: EventType.deletedFromDevice,
        source: "videoCompressRollBack",
      ),
    );
  }

  @override
  Future<Set<String>> deleteOriginals(List<VideoCandidate> originals) async {
    final removed = <String>{};
    for (var i = 0; i < originals.length; i += chunkSize) {
      final end = min(i + chunkSize, originals.length);
      final ids = <String>[];
      final files = <EnteFile>[];
      for (final original in originals.sublist(i, end)) {
        final file = filesByID[original.id];
        if (file == null) continue;
        ids.add(original.id);
        files.add(file);
      }
      if (files.isEmpty) continue;
      final deleted = await deleteOriginalFiles(files);
      var removedInChunk = 0;
      for (var j = 0; j < files.length; j++) {
        if (deleted.any((file) => identical(file, files[j]))) {
          removed.add(ids[j]);
          removedInChunk++;
        }
      }
      // A refused request must not lead to another prompt.
      if (removedInChunk == 0) break;
    }
    return removed;
  }
}

import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:logging/logging.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/db/exact_duplicates_db.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/exact_duplicates/exact_duplicate_finder.dart";
import "package:photos/services/exact_duplicates/file_hash_pool.dart";
import "package:photos/services/search_service.dart";

export "package:photos/services/exact_duplicates/exact_duplicate_finder.dart"
    show
        DuplicateCopy,
        ExactDuplicateGroup,
        ExactDuplicateProgress,
        ExactDuplicateScanPhase,
        ExactDuplicateScanResult;

/// Offline fork: finds device files with byte-identical content.
///
/// This is not the upstream "deduplicate" tool (server side hashes) and not
/// the "similar images" tool (CLIP embeddings). It compares file bytes only:
///
/// 1. Group all device files by exact byte size. The size comes from one
///    MediaStore `SIZE` column query for each file, no file is opened.
/// 2. For the files that share a size with another file, compute a streaming
///    SHA-256 of the origin file in a dedicated isolate, and group by hash.
///
/// Hashes persist in [ExactDuplicatesDB], keyed by local ID and validated
/// against the size and modified time of the file on disk.
///
/// Live and motion photos: on Android a motion photo is one file (a JPEG with
/// the video inside). That one file is the primary file and it is hashed as
/// a whole, so two motion photos match only when the image and the video
/// bytes are identical.
class ExactDuplicatesService {
  ExactDuplicatesService._privateConstructor();

  static final ExactDuplicatesService instance =
      ExactDuplicatesService._privateConstructor();

  static final Logger _logger = Logger("ExactDuplicatesService");

  static const int _hashWorkerCount = 3;

  /// Progress of the scan in flight. `done` and `total` count files in the
  /// current phase. In the hashing phase they are "files hashed" and "total
  /// candidates".
  final ValueNotifier<ExactDuplicateProgress> progress = ValueNotifier(
    const ExactDuplicateProgress(ExactDuplicateScanPhase.idle),
  );

  Future<ExactDuplicateScanResult<EnteFile>?>? _scanInFlight;
  ExactDuplicateCancelToken? _cancelToken;
  FileHashPool? _pool;

  bool get isScanning => _scanInFlight != null;

  /// Scans the device library. Returns null when the scan is cancelled.
  ///
  /// A second call while a scan is in flight returns the same scan.
  Future<ExactDuplicateScanResult<EnteFile>?> scan() {
    return _scanInFlight ??= _scan().whenComplete(() {
      _scanInFlight = null;
    });
  }

  /// Stops the scan in flight. Hashes that are complete stay in the cache.
  void cancel() {
    _cancelToken?.cancel();
    // Kill the hash isolates, so a hash of a large video stops at once.
    _pool?.close();
  }

  Future<ExactDuplicateScanResult<EnteFile>?> _scan() async {
    final stopwatch = Stopwatch()..start();
    final cancelToken = _cancelToken = ExactDuplicateCancelToken();
    final pool = _pool = FileHashPool(workerCount: _hashWorkerCount);
    progress.value = const ExactDuplicateProgress(
      ExactDuplicateScanPhase.listing,
    );
    try {
      final files = await _deviceFiles();
      final finder = ExactDuplicateFinder<EnteFile>(
        idOf: (file) => file.localID,
        sizeOf: _sizeOf,
        stampOf: _stampOf,
        hashOf: (stamp) => pool.hash(
          stamp.path,
          expectedSize: stamp.size,
          expectedModifiedMs: stamp.modifiedMs,
        ),
        creationTimeOf: (file) => file.creationTime,
        cache: ExactDuplicatesDB.instance,
        hashConcurrency: _hashWorkerCount,
      );
      final result = await finder.find(
        files,
        cancelToken: cancelToken,
        onProgress: (value) => progress.value = value,
      );
      _logger.info(
        "Scan took ${stopwatch.elapsedMilliseconds}ms: "
        "${result.fileCount} files, ${result.candidateCount} candidates, "
        "${result.hashedCount} hashed, ${result.cachedCount} from cache, "
        "${result.skippedCount} skipped, ${result.groups.length} groups",
      );
      return result;
    } on ExactDuplicateScanCancelled {
      _logger.info("Scan cancelled after ${stopwatch.elapsedMilliseconds}ms");
      return null;
    } on FileHashPoolClosed {
      if (cancelToken.isCancelled) {
        _logger.info("Scan cancelled after ${stopwatch.elapsedMilliseconds}ms");
        return null;
      }
      rethrow;
    } finally {
      pool.close();
      _pool = null;
      _cancelToken = null;
      progress.value = const ExactDuplicateProgress(
        ExactDuplicateScanPhase.idle,
      );
    }
  }

  /// Returns the IDs of the [copies] whose origin file is missing, or has a
  /// different size or modified time than it had when it was hashed.
  ///
  /// Call this immediately before a deletion. A scan result can be old: a
  /// file that was edited or removed after the scan is not a proven duplicate
  /// any more.
  Future<Set<String>> findChangedCopies(
    int expectedSize,
    Iterable<DuplicateCopy<EnteFile>> copies,
  ) async {
    final changed = <String>{};
    for (final copy in copies) {
      try {
        final stat = await File(copy.path).stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size != expectedSize ||
            stat.modified.millisecondsSinceEpoch != copy.modifiedMs) {
          changed.add(copy.id);
        }
      } catch (_) {
        changed.add(copy.id);
      }
    }
    return changed;
  }

  /// All files that are on the device and managed by MediaStore.
  ///
  /// The list can hold one entry for each device folder of the same asset.
  /// [ExactDuplicateFinder] collapses entries with the same local ID.
  Future<List<EnteFile>> _deviceFiles() async {
    final all = await SearchService.instance.getAllFilesForSearch();
    return [
      for (final file in all)
        if ((file.localID ?? "").isNotEmpty &&
            (file.uploadedFileID == null || file.uploadedFileID == -1) &&
            // Files shared into the app sandbox are not MediaStore assets.
            !file.isSharedMediaToAppSandbox)
          file,
    ];
  }

  /// An entity that carries only the ID. The plugin calls used here
  /// (`getFileSize`, `getFullFile`) read nothing else from the entity, so
  /// this avoids one `AssetEntity.fromId` MediaStore query for each file.
  AssetEntity _assetOf(EnteFile file) =>
      AssetEntity(id: file.localID!, typeInt: 0, width: 0, height: 0);

  Future<int?> _sizeOf(EnteFile file) async {
    final size = await _assetOf(file).fileSize;
    return size > 0 ? size : null;
  }

  Future<FileStamp?> _stampOf(EnteFile file) async {
    // `originFile`, not `file`: the hash must cover the original bytes. On
    // Android 11 and later both return the MediaStore path and nothing is
    // copied. On Android 10 with scoped storage the plugin copies the asset
    // into its cache, and `file` could return a copy without location EXIF.
    final File? origin = await _assetOf(file).originFile;
    if (origin == null) return null;
    final stat = await origin.stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return FileStamp(
      path: origin.path,
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }
}

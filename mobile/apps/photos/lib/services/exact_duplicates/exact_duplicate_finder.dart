// Offline fork: exact (byte-identical) duplicate detection for device files.
//
// This file holds the pure matching logic. It must not import Flutter,
// photo_manager or any app service, so that it can be unit tested with
// injected providers. See `ExactDuplicatesService` for the device wiring.

import "dart:async";

/// What the file system says about a file at the moment it is examined.
///
/// The cache is keyed on [size] and [modifiedMs] as read from the real file,
/// not on gallery metadata, so an edited file never reuses an old hash.
class FileStamp {
  const FileStamp({
    required this.path,
    required this.size,
    required this.modifiedMs,
  });

  final String path;
  final int size;
  final int modifiedMs;
}

class CachedFileHash {
  const CachedFileHash({
    required this.size,
    required this.modifiedMs,
    required this.hash,
  });

  final int size;
  final int modifiedMs;
  final String hash;

  bool matches(FileStamp stamp) =>
      size == stamp.size && modifiedMs == stamp.modifiedMs;
}

/// Persistent store of content hashes, keyed by file ID.
abstract class FileHashCache {
  Future<Map<String, CachedFileHash>> loadAll();

  Future<void> saveAll(Map<String, CachedFileHash> entries);

  Future<void> removeAll(Iterable<String> ids);
}

class ExactDuplicateScanCancelled implements Exception {
  const ExactDuplicateScanCancelled();

  @override
  String toString() => "ExactDuplicateScanCancelled";
}

class ExactDuplicateCancelToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;

  void throwIfCancelled() {
    if (_isCancelled) throw const ExactDuplicateScanCancelled();
  }
}

enum ExactDuplicateScanPhase { idle, listing, sizing, hashing, done }

class ExactDuplicateProgress {
  const ExactDuplicateProgress(this.phase, {this.done = 0, this.total = 0});

  final ExactDuplicateScanPhase phase;

  /// Files processed in the current [phase].
  final int done;

  /// Files to process in the current [phase]. For
  /// [ExactDuplicateScanPhase.hashing] this is the number of candidates, which
  /// are the files that share their byte size with at least one other file.
  final int total;

  @override
  String toString() => "ExactDuplicateProgress($phase, $done/$total)";
}

/// One copy of a duplicated file.
class DuplicateCopy<T> {
  const DuplicateCopy({
    required this.item,
    required this.id,
    required this.path,
    required this.modifiedMs,
    required this.creationTime,
  });

  final T item;
  final String id;

  /// Absolute path of the origin file.
  final String path;

  /// Modified time of the origin file when it was hashed.
  final int modifiedMs;
  final int? creationTime;
}

/// Two or more files with identical bytes.
class ExactDuplicateGroup<T> {
  ExactDuplicateGroup({
    required this.size,
    required this.hash,
    required List<DuplicateCopy<T>> copies,
  }) : assert(copies.length >= 2),
       copies = List.unmodifiable(
         List<DuplicateCopy<T>>.of(copies)..sort(compareCopiesForKeeping),
       );

  /// Byte size of each copy.
  final int size;

  /// Lowercase hex SHA-256 of the file content.
  final String hash;

  /// All copies, best keeper first. See [compareCopiesForKeeping].
  final List<DuplicateCopy<T>> copies;

  /// The copy that is kept by default.
  DuplicateCopy<T> get keeper => copies.first;

  /// Bytes that are freed when all copies except one are deleted.
  int get reclaimableBytes => size * (copies.length - 1);
}

class ExactDuplicateScanResult<T> {
  const ExactDuplicateScanResult({
    required this.groups,
    required this.fileCount,
    required this.candidateCount,
    required this.hashedCount,
    required this.cachedCount,
    required this.skippedCount,
  });

  /// Groups ordered by reclaimable bytes, largest first.
  final List<ExactDuplicateGroup<T>> groups;

  /// Unique files examined.
  final int fileCount;

  /// Files that shared their size with at least one other file.
  final int candidateCount;

  /// Candidates hashed in this scan.
  final int hashedCount;

  /// Candidates whose hash came from the cache.
  final int cachedCount;

  /// Files that could not be sized, located or hashed.
  final int skippedCount;

  int get reclaimableBytes =>
      groups.fold(0, (sum, group) => sum + group.reclaimableBytes);

  int get duplicateCount =>
      groups.fold(0, (sum, group) => sum + group.copies.length - 1);
}

/// Rank of the folder a copy is in. Lower is better.
///
/// 0: the camera folder (`DCIM/Camera`), 1: any other folder below `DCIM`,
/// 2: everything else (downloads, messenger folders, screenshots...).
int keeperFolderRank(String path) {
  final lower = path.toLowerCase();
  if (lower.contains("/dcim/camera/")) return 0;
  if (lower.contains("/dcim/")) return 1;
  return 2;
}

/// Orders copies so that the best one to keep comes first.
///
/// 1. A copy in the camera folder, then one elsewhere below `DCIM`.
/// 2. The oldest creation time (a missing time sorts last).
/// 3. The shortest path, then the path in alphabetical order.
/// 4. The ID, so that the order is total and deterministic.
int compareCopiesForKeeping<T>(DuplicateCopy<T> a, DuplicateCopy<T> b) {
  final rank = keeperFolderRank(a.path).compareTo(keeperFolderRank(b.path));
  if (rank != 0) return rank;
  final aTime = a.creationTime;
  final bTime = b.creationTime;
  if (aTime != bTime) {
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return aTime.compareTo(bTime);
  }
  final length = a.path.length.compareTo(b.path.length);
  if (length != 0) return length;
  final path = a.path.compareTo(b.path);
  if (path != 0) return path;
  return a.id.compareTo(b.id);
}

/// Finds byte-identical files among [T] items.
///
/// Stage 1 groups the items by byte size. Stage 2 hashes only the items that
/// share a size with another item, and groups them by size and hash.
class ExactDuplicateFinder<T> {
  ExactDuplicateFinder({
    required this.idOf,
    required this.sizeOf,
    required this.stampOf,
    required this.hashOf,
    this.creationTimeOf,
    this.cache,
    this.sizeConcurrency = 16,
    this.hashConcurrency = 3,
    this.cacheFlushInterval = 200,
  }) : assert(sizeConcurrency > 0),
       assert(hashConcurrency > 0);

  /// Stable identity of the file. Items with the same ID are one file. An
  /// item with a null or empty ID is ignored.
  final String? Function(T item) idOf;

  /// Cheap byte size. Null or a value below 1 means unknown.
  final Future<int?> Function(T item) sizeOf;

  /// Locates the origin file and reads its size and modified time. Called
  /// only for candidates.
  final Future<FileStamp?> Function(T item) stampOf;

  /// Content hash of the file at [FileStamp.path]. Must return null when the
  /// file cannot be read or does not match the stamp any more.
  final Future<String?> Function(FileStamp stamp) hashOf;

  final int? Function(T item)? creationTimeOf;
  final FileHashCache? cache;
  final int sizeConcurrency;
  final int hashConcurrency;
  final int cacheFlushInterval;

  /// Throws [ExactDuplicateScanCancelled] when [cancelToken] is cancelled.
  Future<ExactDuplicateScanResult<T>> find(
    Iterable<T> items, {
    void Function(ExactDuplicateProgress progress)? onProgress,
    ExactDuplicateCancelToken? cancelToken,
  }) async {
    // The same file can be listed once for each folder or album it is in.
    // That is one file, not a duplicate.
    final unique = <String, T>{};
    for (final item in items) {
      final id = idOf(item);
      if (id == null || id.isEmpty) continue;
      unique.putIfAbsent(id, () => item);
    }
    final ids = unique.keys.toList(growable: false);
    var skipped = 0;

    // Stage 1: group by byte size.
    onProgress?.call(
      ExactDuplicateProgress(ExactDuplicateScanPhase.sizing, total: ids.length),
    );
    final bySize = <int, List<String>>{};
    var sized = 0;
    await _forEachConcurrent<String>(ids, sizeConcurrency, cancelToken, (
      id,
    ) async {
      int? size;
      try {
        size = await sizeOf(unique[id] as T);
      } catch (_) {
        size = null;
      }
      if (size == null || size < 1) {
        skipped++;
      } else {
        (bySize[size] ??= <String>[]).add(id);
      }
      sized++;
      if (sized % 64 == 0 || sized == ids.length) {
        onProgress?.call(
          ExactDuplicateProgress(
            ExactDuplicateScanPhase.sizing,
            done: sized,
            total: ids.length,
          ),
        );
      }
    });

    final candidates = <String>[
      for (final group in bySize.values)
        if (group.length >= 2) ...group,
    ];

    // Stage 2: hash the candidates.
    onProgress?.call(
      ExactDuplicateProgress(
        ExactDuplicateScanPhase.hashing,
        total: candidates.length,
      ),
    );
    final cached = candidates.isEmpty || cache == null
        ? const <String, CachedFileHash>{}
        : await cache!.loadAll();
    final pendingCacheWrites = <String, CachedFileHash>{};
    final byContent = <String, List<DuplicateCopy<T>>>{};
    final contentSize = <String, int>{};
    final contentHash = <String, String>{};
    var processed = 0;
    var hashedNow = 0;
    var fromCache = 0;

    Future<void> flushCache() async {
      if (cache == null || pendingCacheWrites.isEmpty) return;
      final batch = Map<String, CachedFileHash>.of(pendingCacheWrites);
      pendingCacheWrites.clear();
      await cache!.saveAll(batch);
    }

    try {
      await _forEachConcurrent<String>(
        candidates,
        hashConcurrency,
        cancelToken,
        (id) async {
          final item = unique[id] as T;
          String? hash;
          FileStamp? stamp;
          try {
            stamp = await stampOf(item);
            if (stamp != null && stamp.size > 0) {
              final hit = cached[id];
              if (hit != null && hit.matches(stamp)) {
                hash = hit.hash;
                fromCache++;
              } else {
                cancelToken?.throwIfCancelled();
                hash = await hashOf(stamp);
                if (hash != null) {
                  hashedNow++;
                  pendingCacheWrites[id] = CachedFileHash(
                    size: stamp.size,
                    modifiedMs: stamp.modifiedMs,
                    hash: hash,
                  );
                }
              }
            }
          } on ExactDuplicateScanCancelled {
            rethrow;
          } catch (_) {
            hash = null;
          }
          cancelToken?.throwIfCancelled();
          if (hash == null || stamp == null) {
            skipped++;
          } else {
            // The size from the file system is authoritative. It is part of
            // the key, so a stale stage 1 size can never join two files.
            final key = "${stamp.size}:$hash";
            contentSize[key] = stamp.size;
            contentHash[key] = hash;
            (byContent[key] ??= <DuplicateCopy<T>>[]).add(
              DuplicateCopy<T>(
                item: item,
                id: id,
                path: stamp.path,
                modifiedMs: stamp.modifiedMs,
                creationTime: creationTimeOf?.call(item),
              ),
            );
          }
          processed++;
          onProgress?.call(
            ExactDuplicateProgress(
              ExactDuplicateScanPhase.hashing,
              done: processed,
              total: candidates.length,
            ),
          );
          if (pendingCacheWrites.length >= cacheFlushInterval) {
            await flushCache();
          }
        },
      );
    } finally {
      // Keep the work that is done, also when the scan is cancelled.
      await flushCache();
    }

    final groups = <ExactDuplicateGroup<T>>[];
    for (final entry in byContent.entries) {
      // Two IDs that resolve to one path are one file on disk. Deletion of
      // one of them would delete the "kept" copy too.
      final byPath = <String, DuplicateCopy<T>>{};
      for (final copy in entry.value) {
        final existing = byPath[copy.path];
        if (existing == null || copy.id.compareTo(existing.id) < 0) {
          byPath[copy.path] = copy;
        }
      }
      if (byPath.length < 2) continue;
      groups.add(
        ExactDuplicateGroup<T>(
          size: contentSize[entry.key]!,
          hash: contentHash[entry.key]!,
          copies: byPath.values.toList(),
        ),
      );
    }
    groups.sort((a, b) {
      final bytes = b.reclaimableBytes.compareTo(a.reclaimableBytes);
      if (bytes != 0) return bytes;
      return a.keeper.id.compareTo(b.keeper.id);
    });

    if (cache != null && cached.isNotEmpty) {
      final stale = cached.keys.where((id) => !unique.containsKey(id)).toList();
      if (stale.isNotEmpty) await cache!.removeAll(stale);
    }

    onProgress?.call(
      ExactDuplicateProgress(
        ExactDuplicateScanPhase.done,
        done: processed,
        total: candidates.length,
      ),
    );
    return ExactDuplicateScanResult<T>(
      groups: groups,
      fileCount: ids.length,
      candidateCount: candidates.length,
      hashedCount: hashedNow,
      cachedCount: fromCache,
      skippedCount: skipped,
    );
  }
}

/// Runs [action] for each item with at most [concurrency] actions in flight.
/// Stops at the first error, after the actions in flight complete.
Future<void> _forEachConcurrent<E>(
  List<E> items,
  int concurrency,
  ExactDuplicateCancelToken? cancelToken,
  Future<void> Function(E item) action,
) async {
  var next = 0;
  Object? firstError;
  StackTrace? firstStack;

  Future<void> worker() async {
    while (firstError == null) {
      if (cancelToken?.isCancelled ?? false) {
        firstError = const ExactDuplicateScanCancelled();
        firstStack = StackTrace.current;
        return;
      }
      if (next >= items.length) return;
      final item = items[next++];
      try {
        await action(item);
      } catch (e, s) {
        firstError ??= e;
        firstStack ??= s;
        return;
      }
    }
  }

  cancelToken?.throwIfCancelled();
  final workerCount = concurrency < items.length ? concurrency : items.length;
  await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
  cancelToken?.throwIfCancelled();
  final error = firstError;
  if (error != null) {
    Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
  }
}

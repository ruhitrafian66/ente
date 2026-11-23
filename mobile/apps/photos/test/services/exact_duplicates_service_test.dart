import "dart:io";
import "dart:typed_data";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/services/exact_duplicates/exact_duplicate_finder.dart";
import "package:photos/services/exact_duplicates/file_hash_pool.dart";

/// A device file as the gallery lists it. The same [id] can be listed in
/// more than one [folder].
class _Entry {
  _Entry(this.id, this.folder, {this.creationTime});

  final String id;
  final String folder;
  final int? creationTime;
}

/// The bytes and the modified time of a file on the fake disk.
class _Disk {
  _Disk(this.path, this.bytes, {this.modifiedMs = 1000});

  final String path;
  List<int> bytes;
  int modifiedMs;
}

class _MemoryCache implements FileHashCache {
  final Map<String, CachedFileHash> rows = {};
  int saveCalls = 0;

  @override
  Future<Map<String, CachedFileHash>> loadAll() async => Map.of(rows);

  @override
  Future<void> saveAll(Map<String, CachedFileHash> entries) async {
    saveCalls++;
    rows.addAll(entries);
  }

  @override
  Future<void> removeAll(Iterable<String> ids) async {
    ids.forEach(rows.remove);
  }
}

class _Harness {
  _Harness(this.disk, {this.cache});

  /// File ID to file content.
  final Map<String, _Disk> disk;
  final FileHashCache? cache;

  final List<String> sizedIds = [];
  final List<String> stampedIds = [];
  final List<String> hashedPaths = [];

  /// Stage 1 sizes that differ from the real size, to simulate stale
  /// MediaStore data.
  final Map<String, int> reportedSizeOverride = {};

  late final finder = ExactDuplicateFinder<_Entry>(
    idOf: (entry) => entry.id,
    sizeOf: (entry) async {
      sizedIds.add(entry.id);
      return reportedSizeOverride[entry.id] ?? disk[entry.id]?.bytes.length;
    },
    stampOf: (entry) async {
      stampedIds.add(entry.id);
      final file = disk[entry.id];
      if (file == null) return null;
      return FileStamp(
        path: file.path,
        size: file.bytes.length,
        modifiedMs: file.modifiedMs,
      );
    },
    hashOf: (stamp) async {
      hashedPaths.add(stamp.path);
      final file = disk.values.firstWhere((f) => f.path == stamp.path);
      return sha256.convert(file.bytes).toString();
    },
    creationTimeOf: (entry) => entry.creationTime,
    cache: cache,
  );
}

DuplicateCopy<String> _copy(String id, String path, {int? creationTime}) {
  return DuplicateCopy<String>(
    item: id,
    id: id,
    path: path,
    modifiedMs: 0,
    creationTime: creationTime,
  );
}

void main() {
  group("ExactDuplicateFinder", () {
    test("groups files with the same size and the same bytes", () async {
      final harness = _Harness({
        "1": _Disk("/storage/emulated/0/DCIM/Camera/a.jpg", [1, 2, 3, 4]),
        "2": _Disk("/storage/emulated/0/Download/a.jpg", [1, 2, 3, 4]),
        "3": _Disk("/storage/emulated/0/Pictures/a (1).jpg", [1, 2, 3, 4]),
      });

      final result = await harness.finder.find([
        _Entry("1", "Camera"),
        _Entry("2", "Download"),
        _Entry("3", "Pictures"),
      ]);

      expect(result.groups, hasLength(1));
      final group = result.groups.single;
      expect(group.copies.map((c) => c.id).toSet(), {"1", "2", "3"});
      expect(group.size, 4);
      expect(group.hash, sha256.convert([1, 2, 3, 4]).toString());
      expect(group.reclaimableBytes, 8);
      expect(result.reclaimableBytes, 8);
      expect(result.duplicateCount, 2);
      expect(result.candidateCount, 3);
      expect(result.hashedCount, 3);
    });

    test("does not group files with the same size and other bytes", () async {
      final harness = _Harness({
        "1": _Disk("/a/1.jpg", [1, 2, 3, 4]),
        "2": _Disk("/a/2.jpg", [1, 2, 3, 5]),
      });

      final result = await harness.finder.find([
        _Entry("1", "a"),
        _Entry("2", "a"),
      ]);

      expect(result.groups, isEmpty);
      // Both were candidates, so both were hashed.
      expect(harness.hashedPaths.toSet(), {"/a/1.jpg", "/a/2.jpg"});
    });

    test("never hashes a file with a size that no other file has", () async {
      final harness = _Harness({
        "1": _Disk("/a/1.jpg", [1, 2, 3, 4]),
        "2": _Disk("/a/2.jpg", [1, 2, 3, 4]),
        "3": _Disk("/a/3.jpg", [1, 2, 3]),
        "4": _Disk("/a/4.jpg", [1, 2, 3, 4, 5]),
      });

      final result = await harness.finder.find([
        _Entry("1", "a"),
        _Entry("2", "a"),
        _Entry("3", "a"),
        _Entry("4", "a"),
      ]);

      expect(harness.sizedIds.toSet(), {"1", "2", "3", "4"});
      expect(harness.stampedIds.toSet(), {"1", "2"});
      expect(harness.hashedPaths.toSet(), {"/a/1.jpg", "/a/2.jpg"});
      expect(result.candidateCount, 2);
      expect(result.groups.single.copies.map((c) => c.id).toSet(), {"1", "2"});
    });

    test("the same local ID in two folders is one file", () async {
      final harness = _Harness({
        "1": _Disk("/storage/emulated/0/DCIM/Camera/a.jpg", [9, 9, 9]),
      });

      final result = await harness.finder.find([
        _Entry("1", "Camera"),
        _Entry("1", "Recents"),
      ]);

      expect(result.fileCount, 1);
      expect(result.groups, isEmpty);
      expect(harness.sizedIds, ["1"]);
      expect(harness.hashedPaths, isEmpty);
    });

    test("a repeated local ID does not add a copy to a real group", () async {
      final harness = _Harness({
        "1": _Disk("/storage/emulated/0/DCIM/Camera/a.jpg", [9, 9, 9]),
        "2": _Disk("/storage/emulated/0/Download/a.jpg", [9, 9, 9]),
      });

      final result = await harness.finder.find([
        _Entry("1", "Camera"),
        _Entry("1", "Recents"),
        _Entry("2", "Download"),
      ]);

      expect(result.groups.single.copies, hasLength(2));
      expect(result.groups.single.reclaimableBytes, 3);
    });

    test("two IDs that point at one path are one file", () async {
      final harness = _Harness({
        "1": _Disk("/a/same.jpg", [7, 7]),
        "2": _Disk("/a/same.jpg", [7, 7]),
      });

      final result = await harness.finder.find([
        _Entry("1", "a"),
        _Entry("2", "a"),
      ]);

      expect(result.groups, isEmpty);
    });

    test("ignores items without an ID and files without a size", () async {
      final harness = _Harness({
        "1": _Disk("/a/1.jpg", [1]),
        "2": _Disk("/a/2.jpg", []),
        "3": _Disk("/a/3.jpg", []),
      });

      final result = await harness.finder.find([
        _Entry("", "a"),
        _Entry("1", "a"),
        _Entry("2", "a"),
        _Entry("3", "a"),
        _Entry("missing", "a"),
      ]);

      expect(result.groups, isEmpty);
      expect(result.fileCount, 4);
      expect(result.skippedCount, 3);
      expect(harness.hashedPaths, isEmpty);
    });

    test("a stale stage 1 size cannot join files of other sizes", () async {
      final harness = _Harness({
        "1": _Disk("/a/1.jpg", [1, 2, 3, 4]),
        "2": _Disk("/a/2.jpg", [1, 2, 3, 4, 5]),
      });
      // MediaStore still reports the old size of file 2.
      harness.reportedSizeOverride["2"] = 4;

      final result = await harness.finder.find([
        _Entry("1", "a"),
        _Entry("2", "a"),
      ]);

      expect(result.candidateCount, 2);
      expect(result.groups, isEmpty);
    });

    test("orders groups by reclaimable bytes", () async {
      final harness = _Harness({
        "1": _Disk("/a/1.jpg", [1, 1]),
        "2": _Disk("/a/2.jpg", [1, 1]),
        "3": _Disk("/a/3.mp4", List.filled(100, 3)),
        "4": _Disk("/a/4.mp4", List.filled(100, 3)),
        "5": _Disk("/a/5.jpg", [5, 5, 5]),
        "6": _Disk("/a/6.jpg", [5, 5, 5]),
        "7": _Disk("/a/7.jpg", [5, 5, 5]),
      });

      final result = await harness.finder.find([
        for (final id in ["1", "2", "3", "4", "5", "6", "7"]) _Entry(id, "a"),
      ]);

      expect(result.groups.map((g) => g.reclaimableBytes), [100, 6, 2]);
    });

    test("reports hashing progress up to the candidate count", () async {
      final harness = _Harness({
        "1": _Disk("/a/1.jpg", [1, 1]),
        "2": _Disk("/a/2.jpg", [1, 1]),
        "3": _Disk("/a/3.jpg", [1]),
      });
      final events = <ExactDuplicateProgress>[];

      await harness.finder.find([
        _Entry("1", "a"),
        _Entry("2", "a"),
        _Entry("3", "a"),
      ], onProgress: events.add);

      final hashing = events
          .where((e) => e.phase == ExactDuplicateScanPhase.hashing)
          .toList();
      expect(hashing.first.done, 0);
      expect(hashing.every((e) => e.total == 2), isTrue);
      expect(hashing.last.done, 2);
      expect(events.last.phase, ExactDuplicateScanPhase.done);
    });

    test("stops when the token is cancelled", () async {
      final token = ExactDuplicateCancelToken();
      final disk = {
        for (var i = 0; i < 20; i++) "$i": _Disk("/a/$i.jpg", [1, 2, 3]),
      };
      final harness = _Harness(disk, cache: _MemoryCache());

      final future = harness.finder.find(
        [for (final id in disk.keys) _Entry(id, "a")],
        cancelToken: token,
        onProgress: (progress) {
          if (progress.phase == ExactDuplicateScanPhase.hashing &&
              progress.done == 4) {
            token.cancel();
          }
        },
      );

      await expectLater(future, throwsA(isA<ExactDuplicateScanCancelled>()));
      expect(harness.hashedPaths.length, lessThan(20));
      // The hashes that were complete are kept for the next scan.
      expect(
        (harness.cache! as _MemoryCache).rows.length,
        greaterThanOrEqualTo(4),
      );
    });
  });

  group("hash cache", () {
    Map<String, _Disk> disk() => {
      "1": _Disk("/a/1.jpg", [1, 2, 3, 4], modifiedMs: 10),
      "2": _Disk("/a/2.jpg", [1, 2, 3, 4], modifiedMs: 20),
    };
    final entries = [_Entry("1", "a"), _Entry("2", "a")];

    test("a second scan reuses the stored hashes", () async {
      final cache = _MemoryCache();
      final first = _Harness(disk(), cache: cache);
      await first.finder.find(entries);
      expect(first.hashedPaths, hasLength(2));
      expect(cache.rows.keys.toSet(), {"1", "2"});

      final second = _Harness(disk(), cache: cache);
      final result = await second.finder.find(entries);

      expect(second.hashedPaths, isEmpty);
      expect(result.cachedCount, 2);
      expect(result.hashedCount, 0);
      expect(result.groups.single.copies, hasLength(2));
    });

    test("a changed modified time invalidates the stored hash", () async {
      final cache = _MemoryCache();
      await _Harness(disk(), cache: cache).finder.find(entries);

      final changed = disk();
      changed["2"]!
        ..bytes = [4, 3, 2, 1]
        ..modifiedMs = 21;
      final second = _Harness(changed, cache: cache);
      final result = await second.finder.find(entries);

      expect(second.hashedPaths, ["/a/2.jpg"]);
      expect(result.groups, isEmpty);
      expect(cache.rows["2"]!.modifiedMs, 21);
    });

    test("a changed size invalidates the stored hash", () async {
      final cache = _MemoryCache();
      await _Harness(disk(), cache: cache).finder.find(entries);

      final changed = disk();
      changed["2"]!.bytes = [1, 2, 3, 4, 5];
      final second = _Harness(changed, cache: cache);
      // The gallery still reports the old size, so file 2 is a candidate.
      second.reportedSizeOverride["2"] = 4;
      final result = await second.finder.find(entries);

      expect(second.hashedPaths, ["/a/2.jpg"]);
      expect(result.groups, isEmpty);
      expect(cache.rows["2"]!.size, 5);
    });

    test("drops rows of files that are not in the library", () async {
      final cache = _MemoryCache();
      cache.rows["gone"] = const CachedFileHash(
        size: 1,
        modifiedMs: 1,
        hash: "x",
      );

      await _Harness(disk(), cache: cache).finder.find(entries);

      expect(cache.rows.containsKey("gone"), isFalse);
    });
  });

  group("keeper selection", () {
    test("prefers the camera folder", () {
      final group = ExactDuplicateGroup<String>(
        size: 10,
        hash: "h",
        copies: [
          _copy("1", "/storage/emulated/0/Download/a.jpg", creationTime: 1),
          _copy(
            "2",
            "/storage/emulated/0/DCIM/Screenshots/a.jpg",
            creationTime: 2,
          ),
          _copy("3", "/storage/emulated/0/DCIM/Camera/a.jpg", creationTime: 3),
        ],
      );

      expect(group.keeper.id, "3");
      expect(group.copies.map((c) => c.id), ["3", "2", "1"]);
    });

    test("then prefers the oldest creation time", () {
      final group = ExactDuplicateGroup<String>(
        size: 10,
        hash: "h",
        copies: [
          _copy("1", "/storage/emulated/0/Download/a.jpg", creationTime: 30),
          _copy("2", "/storage/emulated/0/WhatsApp/a.jpg", creationTime: 20),
          _copy("3", "/storage/emulated/0/Pictures/a.jpg"),
        ],
      );

      expect(group.keeper.id, "2");
      // A copy without a creation time sorts last.
      expect(group.copies.last.id, "3");
    });

    test("then prefers the shortest path", () {
      final group = ExactDuplicateGroup<String>(
        size: 10,
        hash: "h",
        copies: [
          _copy("1", "/storage/emulated/0/DCIM/Camera/a (1).jpg"),
          _copy("2", "/storage/emulated/0/DCIM/Camera/a.jpg"),
        ],
      );

      expect(group.keeper.id, "2");
    });

    test("is deterministic for equal copies in any input order", () {
      final copies = [
        _copy("b", "/storage/emulated/0/Download/x.jpg", creationTime: 5),
        _copy("a", "/storage/emulated/0/Download/y.jpg", creationTime: 5),
        _copy("c", "/storage/emulated/0/Download/x.jpg", creationTime: 5),
      ];
      final forward = ExactDuplicateGroup<String>(
        size: 1,
        hash: "h",
        copies: copies,
      );
      final backward = ExactDuplicateGroup<String>(
        size: 1,
        hash: "h",
        copies: copies.reversed.toList(),
      );

      expect(forward.copies.map((c) => c.id), ["b", "c", "a"]);
      expect(backward.copies.map((c) => c.id), ["b", "c", "a"]);
    });

    test("the finder returns each group with the keeper first", () async {
      final harness = _Harness({
        "1": _Disk("/storage/emulated/0/Download/a.jpg", [1, 2]),
        "2": _Disk("/storage/emulated/0/DCIM/Camera/a.jpg", [1, 2]),
      });

      final result = await harness.finder.find([
        _Entry("1", "Download", creationTime: 1),
        _Entry("2", "Camera", creationTime: 2),
      ]);

      expect(result.groups.single.keeper.id, "2");
    });
  });

  group("file hashing", () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync("exact_duplicates_test");
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    File write(String name, List<int> bytes) {
      return File("${dir.path}/$name")..writeAsBytesSync(bytes, flush: true);
    }

    test("streams a file that is larger than one chunk", () {
      final bytes = Uint8List.fromList(
        List.generate(100000, (i) => (i * 31) % 251),
      );
      final file = write("big.bin", bytes);

      final hash = sha256OfFileSync(file.path, chunkSize: 4096);

      expect(hash, sha256.convert(bytes).toString());
    });

    test("rejects a file that does not match the expected stamp", () {
      final file = write("a.bin", [1, 2, 3]);
      final modifiedMs = file.statSync().modified.millisecondsSinceEpoch;

      expect(sha256OfFileSync(file.path, expectedSize: 4), isNull);
      expect(
        sha256OfFileSync(file.path, expectedModifiedMs: modifiedMs + 1000),
        isNull,
      );
      expect(
        sha256OfFileSync(
          file.path,
          expectedSize: 3,
          expectedModifiedMs: modifiedMs,
        ),
        sha256.convert([1, 2, 3]).toString(),
      );
      expect(sha256OfFileSync("${dir.path}/missing.bin"), isNull);
    });

    test("the pool hashes files in worker isolates", () async {
      final same1 = write("same1.bin", List.filled(5000, 7));
      final same2 = write("same2.bin", List.filled(5000, 7));
      final other = write("other.bin", List.filled(5000, 8));
      final pool = FileHashPool(workerCount: 2);
      addTearDown(pool.close);

      final hashes = await Future.wait([
        pool.hash(same1.path, expectedSize: 5000),
        pool.hash(same2.path),
        pool.hash(other.path),
        pool.hash("${dir.path}/missing.bin"),
      ]);

      expect(hashes[0], sha256.convert(List.filled(5000, 7)).toString());
      expect(hashes[1], hashes[0]);
      expect(hashes[2], isNot(hashes[0]));
      expect(hashes[3], isNull);
    });

    test("a closed pool fails the hashes that are not done", () async {
      final file = write("a.bin", [1, 2, 3]);
      final pool = FileHashPool(workerCount: 1);

      final pending = pool.hash(file.path);
      pool.close();

      await expectLater(pending, throwsA(isA<FileHashPoolClosed>()));
      await expectLater(
        pool.hash(file.path),
        throwsA(isA<FileHashPoolClosed>()),
      );
    });
  });
}

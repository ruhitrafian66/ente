// Offline fork: SHA-256 of whole files, computed off the UI isolate.
//
// Dart only (dart:io, dart:isolate, package:crypto), so that it can be unit
// tested without the app.

import "dart:async";
import "dart:io";
import "dart:isolate";
import "dart:typed_data";

import "package:crypto/crypto.dart";

/// Bytes read from disk for each step. This bounds the memory of one worker,
/// whatever the size of the file is.
const int kFileHashChunkSize = 1024 * 1024;

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Streams the file at [path] through SHA-256 and returns the lowercase hex
/// digest.
///
/// Returns null when the file cannot be read, or when its size or modified
/// time is not equal to the expected values before or after the read. Such a
/// file changed while it was examined, so its hash is not safe to use.
String? sha256OfFileSync(
  String path, {
  int? expectedSize,
  int? expectedModifiedMs,
  int chunkSize = kFileHashChunkSize,
}) {
  RandomAccessFile? raf;
  try {
    final file = File(path);
    final before = file.statSync();
    if (before.type != FileSystemEntityType.file) return null;
    if (expectedSize != null && before.size != expectedSize) return null;
    if (expectedModifiedMs != null &&
        before.modified.millisecondsSinceEpoch != expectedModifiedMs) {
      return null;
    }

    final digestSink = _DigestSink();
    final input = sha256.startChunkedConversion(digestSink);
    final buffer = Uint8List(chunkSize);
    raf = file.openSync();
    var total = 0;
    while (true) {
      final read = raf.readIntoSync(buffer);
      if (read <= 0) break;
      // The hash sink copies the bytes it buffers, so the buffer is reused.
      input.add(Uint8List.sublistView(buffer, 0, read));
      total += read;
    }
    input.close();
    raf.closeSync();
    raf = null;

    final after = file.statSync();
    if (total != before.size ||
        after.size != before.size ||
        after.modified != before.modified) {
      return null;
    }
    return digestSink.value?.toString();
  } catch (_) {
    return null;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

class FileHashPoolClosed implements Exception {
  const FileHashPoolClosed();

  @override
  String toString() => "FileHashPoolClosed";
}

class _Job {
  _Job(this.path, this.expectedSize, this.expectedModifiedMs) {
    // A job can fail before `FileHashPool.hash` listens to it (the pool is
    // closed while it starts). That is not an unhandled error.
    completer.future.ignore();
  }

  final String path;
  final int? expectedSize;
  final int? expectedModifiedMs;
  final Completer<String?> completer = Completer<String?>();
}

class _Worker {
  _Worker(this.isolate, this.sendPort);

  final Isolate isolate;
  final SendPort sendPort;
  _Job? job;
}

/// A small set of dedicated isolates that hash files.
///
/// The isolates are dedicated (not `Computer.shared()`) for two reasons: a
/// long hash of a large video does not occupy the shared workers of the app,
/// and [close] can stop a hash that is in progress at once.
class FileHashPool {
  FileHashPool({this.workerCount = 3}) : assert(workerCount > 0);

  final int workerCount;
  final List<_Worker> _workers = [];
  final List<_Job> _queue = [];
  final ReceivePort _results = ReceivePort();
  Future<void>? _startFuture;
  bool _isClosed = false;

  Future<void> _start() async {
    _results.listen(_onMessage);
    for (var i = 0; i < workerCount; i++) {
      final handshake = ReceivePort();
      try {
        final isolate = await Isolate.spawn(_workerMain, [
          handshake.sendPort,
          _results.sendPort,
          i,
        ], debugName: "exact-duplicates-hash-$i");
        final sendPort = await handshake.first as SendPort;
        if (_isClosed) {
          isolate.kill(priority: Isolate.immediate);
          return;
        }
        _workers.add(_Worker(isolate, sendPort));
      } finally {
        handshake.close();
      }
    }
  }

  /// Hashes the file at [path]. See [sha256OfFileSync] for the result.
  ///
  /// Completes with a [FileHashPoolClosed] error when the pool is closed
  /// before the hash is done.
  Future<String?> hash(
    String path, {
    int? expectedSize,
    int? expectedModifiedMs,
  }) async {
    if (_isClosed) throw const FileHashPoolClosed();
    final job = _Job(path, expectedSize, expectedModifiedMs);
    _queue.add(job);
    _startFuture ??= _start();
    try {
      await _startFuture;
    } catch (e) {
      _queue.remove(job);
      rethrow;
    }
    if (_isClosed) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(const FileHashPoolClosed());
      }
    } else {
      _dispatch();
    }
    return job.completer.future;
  }

  void _dispatch() {
    for (final worker in _workers) {
      if (_queue.isEmpty) return;
      if (worker.job != null) continue;
      final job = _queue.removeAt(0);
      worker.job = job;
      worker.sendPort.send([
        job.path,
        job.expectedSize,
        job.expectedModifiedMs,
      ]);
    }
  }

  void _onMessage(dynamic message) {
    final reply = message as List<dynamic>;
    final worker = _workers[reply[0] as int];
    final job = worker.job;
    worker.job = null;
    if (job != null && !job.completer.isCompleted) {
      job.completer.complete(reply[1] as String?);
    }
    if (!_isClosed) _dispatch();
  }

  /// Stops all workers at once. Hashes that are not done fail with
  /// [FileHashPoolClosed].
  void close() {
    if (_isClosed) return;
    _isClosed = true;
    _results.close();
    for (final worker in _workers) {
      worker.isolate.kill(priority: Isolate.immediate);
      final job = worker.job;
      worker.job = null;
      if (job != null && !job.completer.isCompleted) {
        job.completer.completeError(const FileHashPoolClosed());
      }
    }
    for (final job in _queue) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(const FileHashPoolClosed());
      }
    }
    _queue.clear();
  }
}

void _workerMain(List<dynamic> args) {
  final handshake = args[0] as SendPort;
  final results = args[1] as SendPort;
  final index = args[2] as int;
  final jobs = ReceivePort();
  handshake.send(jobs.sendPort);
  jobs.listen((dynamic message) {
    final job = message as List<dynamic>;
    final hash = sha256OfFileSync(
      job[0] as String,
      expectedSize: job[1] as int?,
      expectedModifiedMs: job[2] as int?,
    );
    results.send([index, hash]);
  });
}

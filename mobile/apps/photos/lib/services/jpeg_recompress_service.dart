// Offline fork: device side of the "Recompress large JPGs" tool.
//
// The rules (which JPEG is large for its pixels, the picture check, the
// encode -> compare -> save -> verify -> delete order) live in
// jpeg_recompress_core.dart. This file only connects them to photo_manager,
// the Rust image bridge and the local database.

import "dart:io";
import "dart:math" show min;
import "dart:typed_data";

import "package:logging/logging.dart";
import "package:path/path.dart" as p;
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/constants.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/local_photos_updated_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/services/jpeg_recompress_core.dart";
import "package:photos/services/jpeg_recompress_decode.dart";
import "package:photos/services/png_to_jpg_core.dart" show SavedJpeg;
import "package:photos/services/search_service.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:photos/src/rust/api/image_processing_api.dart" as rust_image;
import "package:photos/ui/settings/file_access_section.dart"
    show hasAllFilesAccess;

/// A large JPEG found on the device, with the gallery file that shows its
/// thumbnail.
class JpegScanItem {
  final JpegCandidate candidate;
  final EnteFile file;

  /// When the file was last changed on the device (MediaStore
  /// DATE_MODIFIED). The page sorts by it.
  final DateTime modified;

  const JpegScanItem({
    required this.candidate,
    required this.file,
    required this.modified,
  });
}

/// What the scan did with the JPEG files of one device folder.
class JpegFolderReport {
  /// MediaStore RELATIVE_PATH, for example "Pictures/People/Ann/".
  final String folder;

  /// Outcome (one of the `JpegRecompressService.outcome...` texts) to the
  /// number of files.
  final Map<String, int> counts;

  const JpegFolderReport({required this.folder, required this.counts});

  int get total => counts.values.fold(0, (a, b) => a + b);

  int get listed => counts[JpegRecompressService.outcomeListed] ?? 0;
}

class JpegScanResult {
  /// Every JPEG that is large for its pixel count, last modified first. The
  /// page separates the ones with a skip reason.
  final List<JpegScanItem> items;

  /// How many JPEG files the scan looked at.
  final int checked;

  /// One entry for each folder that has a file with a JPEG name, by name.
  final List<JpegFolderReport> folders;

  /// Image files that the scan did not look at, because their name is not a
  /// JPEG name: file extension (for example ".png") to the number of files.
  final Map<String, int> otherImageTypes;

  const JpegScanResult({
    required this.items,
    required this.checked,
    this.folders = const [],
    this.otherImageTypes = const {},
  });
}

/// Removes the given gallery files from the device in one request. Returns
/// the files that are gone.
typedef JpegOriginalsDeleter =
    Future<List<EnteFile>> Function(List<EnteFile> files);

class JpegRecompressService {
  JpegRecompressService._();

  static final JpegRecompressService instance = JpegRecompressService._();

  static const _scanConcurrency = 12;

  /// The system delete request takes a limited number of items.
  static const _deleteChunkSize = 1500;

  final _logger = Logger("JpegRecompressService");

  static const outcomeListed = "Large for its pixels";
  static const outcomeNormal = "Normal size for its pixels";
  static const outcomeNotReadable = "The app cannot read the file";
  static const outcomeOtherFormat = "Android reports another format";
  static const outcomeNotJpeg = "Not readable as JPG";

  /// The file has a JPG name, but its data is another format.
  static String outcomeMisnamed(String format) => format == "PNG"
      ? "Is a PNG with a JPG name (see the PNG tool)"
      : "Is a $format file with a JPG name";

  /// Folder to outcome to count, for the scan that is in progress.
  final Map<String, Map<String, int>> _outcomes = {};

  void _note(String? folder, String outcome) {
    final counts = _outcomes.putIfAbsent(
      folder == null || folder.isEmpty ? "(unknown folder)" : folder,
      () => {},
    );
    counts[outcome] = (counts[outcome] ?? 0) + 1;
  }

  /// Finds the JPEG images that are large for their pixel count.
  Future<JpegScanResult> scan({
    void Function(int done, int total)? onProgress,
  }) async {
    _outcomes.clear();
    final allFiles = await SearchService.instance.getAllFilesForSearch();
    // The same asset is listed once for each device folder.
    final byLocalID = <String, EnteFile>{};
    final otherTypes = <String, int>{};
    final seenOther = <String>{};
    for (final file in allFiles) {
      final localID = file.localID;
      if (localID == null ||
          localID.startsWith(sharedMediaIdentifier) ||
          file.fileType != FileType.image) {
        continue;
      }
      if (!hasJpegExtension(file.title)) {
        if (seenOther.add(localID)) {
          final extension = p.extension(file.title ?? "").toLowerCase();
          final key = extension.isEmpty ? "(no extension)" : extension;
          otherTypes[key] = (otherTypes[key] ?? 0) + 1;
        }
        continue;
      }
      byLocalID.putIfAbsent(localID, () => file);
    }

    final files = byLocalID.values.toList();
    final items = <JpegScanItem>[];
    for (var i = 0; i < files.length; i += _scanConcurrency) {
      final end = min(i + _scanConcurrency, files.length);
      final batch = await Future.wait(
        files.sublist(i, end).map((file) => _inspect(file, report: true)),
      );
      items.addAll(batch.whereType<JpegScanItem>());
      onProgress?.call(end, files.length);
    }
    // Newest change first.
    items.sort((a, b) => b.modified.compareTo(a.modified));
    final folders = [
      for (final entry in _outcomes.entries)
        JpegFolderReport(
          folder: entry.key,
          counts: Map.unmodifiable(entry.value),
        ),
    ]..sort((a, b) => a.folder.toLowerCase().compareTo(b.folder.toLowerCase()));
    _logger.info(
      "Checked ${files.length} JPEG files in ${folders.length} folders, "
      "${items.length} are large for their pixel count; other image types: "
      "$otherTypes",
    );
    for (final folder in folders) {
      _logger.info("JPEG scan, ${folder.folder}: ${folder.counts}");
    }
    return JpegScanResult(
      items: items,
      checked: files.length,
      folders: folders,
      otherImageTypes: Map.unmodifiable(otherTypes),
    );
  }

  /// Reads one JPEG that the user chose in the viewer. Unlike the scan, it
  /// does not require the file to be large for its pixel count. Returns null
  /// when the file is not a readable JPEG on the device.
  Future<JpegScanItem?> inspectSingle(EnteFile file) {
    if (file.localID == null) return Future.value(null);
    return _inspect(file, onlyLarge: false);
  }

  /// [report] counts the outcome for the folder report of a scan.
  Future<JpegScanItem?> _inspect(
    EnteFile file, {
    bool onlyLarge = true,
    bool report = false,
  }) async {
    String? folder = file.deviceFolder;
    Null out(String outcome) {
      if (report) _note(folder, outcome);
      return null;
    }

    try {
      final asset = await AssetEntity.fromId(file.localID!);
      if (asset == null) return out(outcomeNotReadable);
      folder = asset.relativePath ?? folder;
      if (asset.type != AssetType.image) return out(outcomeOtherFormat);
      final title = asset.title ?? file.title;
      if (!looksLikeJpeg(title: title, mimeType: asset.mimeType)) {
        return out(outcomeOtherFormat);
      }
      final source = await asset.originFile;
      if (source == null) return out(outcomeNotReadable);
      final sizeBytes = await source.length();
      // The media library dimensions are enough for the first filter, so
      // most files are not opened at all.
      if (onlyLarge &&
          asset.width > 0 &&
          asset.height > 0 &&
          !isLargeForItsPixels(
            sizeBytes: sizeBytes,
            width: asset.width,
            height: asset.height,
          )) {
        return out(outcomeNormal);
      }
      if (onlyLarge && sizeBytes < kJpegRecompressMinBytes) {
        return out(outcomeNormal);
      }

      // A large file: read it once to find the real image size, the quality
      // and the bytes after the end of the image.
      final bytes = await source.readAsBytes();
      final header = parseJpegHeader(bytes);
      if (header == null) {
        final format = sniffImageFormat(bytes);
        if (format != null && format != "JPG") {
          return out(outcomeMisnamed(format));
        }
        final start = bytes
            .take(16)
            .map((b) => b.toRadixString(16).padLeft(2, "0"))
            .join(" ");
        _logger.warning(
          "JPEG header not readable: ${bytes.length} bytes, starts with "
          "$start",
        );
        return out(outcomeNotJpeg);
      }
      final primaryEnd = findJpegPrimaryEnd(bytes) ?? bytes.length;
      if (onlyLarge &&
          !isLargeForItsPixels(
            sizeBytes: sizeBytes,
            width: header.width,
            height: header.height,
          )) {
        return out(outcomeNormal);
      }
      if (report) _note(folder, outcomeListed);

      final creationTime = file.creationTime ?? 0;
      return JpegScanItem(
        file: file,
        modified: asset.modifiedDateTime,
        candidate: JpegCandidate(
          id: asset.id,
          title: title ?? p.basename(source.path),
          path: source.path,
          sizeBytes: sizeBytes,
          width: header.width,
          height: header.height,
          components: header.components,
          estimatedQuality: header.estimatedQuality,
          trailerBytes: bytes.length - primaryEnd,
          // The gallery time is what places the file in the timeline.
          captureTime: creationTime > 0
              ? DateTime.fromMicrosecondsSinceEpoch(creationTime)
              : asset.createDateTime,
          relativePath: asset.relativePath,
          canWriteAnyFolder: await hasAllFilesAccess(),
        ),
      );
    } catch (e, s) {
      _logger.warning("Could not inspect a JPEG candidate", e, s);
      return out(outcomeNotReadable);
    }
  }

  /// A recompressor whose delete step uses [deleteOriginals] (the page
  /// supplies it, because the delete helpers need a BuildContext).
  JpegRecompressor recompressor({
    required List<JpegScanItem> items,
    required JpegOriginalsDeleter deleteOriginals,
  }) {
    return JpegRecompressor(
      _DeviceIo(
        filesByID: {for (final item in items) item.candidate.id: item.file},
        deleteOriginalFiles: deleteOriginals,
        chunkSize: _deleteChunkSize,
      ),
    );
  }

  /// One log line for each result: the record of what the tool did.
  void logResult(JpegRecompressResult result) {
    final candidate = result.candidate;
    _logger.info(
      "${result.status.name}: ${candidate.width}x${candidate.height} "
      "${candidate.bitsPerPixel.toStringAsFixed(1)} bpp, source quality "
      "${candidate.estimatedQuality ?? "?"}, ${candidate.sizeBytes} -> "
      "${result.outputBytes} bytes, quality ${result.quality ?? "-"}, PSNR "
      "${result.psnr?.toStringAsFixed(1) ?? "-"} dB"
      "${result.message == null ? "" : ", ${result.message}"}",
    );
  }

  /// Makes the gallery pick up the new files. The delete helpers already
  /// report the removed originals.
  Future<void> refreshGallery() async {
    try {
      await LocalSyncService.instance.checkAndSync();
    } catch (e, s) {
      _logger.warning("Local sync after JPEG recompression failed", e, s);
    }
  }
}

class _DeviceIo implements JpegRecompressIo {
  final Map<String, EnteFile> filesByID;
  final JpegOriginalsDeleter deleteOriginalFiles;
  final int chunkSize;
  final _logger = Logger("JpegRecompressDeviceIo");

  _DeviceIo({
    required this.filesByID,
    required this.deleteOriginalFiles,
    required this.chunkSize,
  });

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) async {
    final file = await File(path).open();
    try {
      return await file.read(maxBytes);
    } finally {
      await file.close();
    }
  }

  @override
  Future<DecodedRgba?> decodeFile(String path) {
    return decodeUprightRgbaFromPath(path, maxPixels: kJpegRecompressMaxPixels);
  }

  @override
  Future<DecodedRgba?> decodeBytes(Uint8List bytes) {
    return decodeUprightRgbaFromBytes(
      bytes,
      maxPixels: kJpegRecompressMaxPixels,
    );
  }

  // Native decode + encode on the Rust worker pool: full resolution, the
  // EXIF orientation applied, an embedded ICC profile converted to sRGB.
  @override
  Future<Uint8List> encodeJpeg(String path, int quality) {
    return rust_image.decodeFullToJpeg(imagePath: path, quality: quality);
  }

  @override
  Future<bool> fileExists(String path) => File(path).exists();

  @override
  Future<SavedJpeg> saveJpeg(
    Uint8List bytes, {
    required String name,
    required JpegCandidate source,
  }) async {
    final relativePath = source.relativePath;
    if (relativePath == null || relativePath.trim().isEmpty) {
      throw StateError("The folder of the image is not known");
    }
    final asset = await PhotoManager.editor.saveImage(
      bytes,
      filename: name,
      title: name,
      relativePath: relativePath,
      creationDate: source.captureTime,
    );
    final file = await asset.originFile;
    return SavedJpeg(
      id: asset.id,
      path: file?.path ?? "",
      name: asset.title ?? name,
    );
  }

  @override
  Future<Uint8List> readSaved(SavedJpeg saved) async {
    final asset = await AssetEntity.fromId(saved.id);
    if (asset == null || !await asset.exists) {
      throw StateError("The new JPG is not in the media library");
    }
    return File(saved.path).readAsBytes();
  }

  @override
  Future<void> discardJpeg(SavedJpeg saved) async {
    // The app owns this file, so a direct delete needs no system prompt.
    if (saved.path.isNotEmpty) {
      final file = File(saved.path);
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        _logger.warning("Direct delete of a new JPG failed", e);
      }
    }
    final asset = saved.id.isEmpty ? null : await AssetEntity.fromId(saved.id);
    if (asset != null && await asset.exists) {
      final removed = await PhotoManager.editor.deleteWithIds([saved.id]);
      if (!removed.contains(saved.id)) {
        throw StateError("Could not remove the new JPG");
      }
    }
    if (saved.id.isEmpty) return;
    // Local sync may have listed the new file already.
    final rows = await FilesDB.instance.getLocalFiles([saved.id]);
    if (rows.isEmpty) return;
    await FilesDB.instance.deleteLocalFile(rows.first);
    Bus.instance.fire(
      LocalPhotosUpdatedEvent(
        rows,
        type: EventType.deletedFromDevice,
        source: "jpegRecompressRollBack",
      ),
    );
  }

  @override
  Future<Set<String>> deleteOriginals(List<JpegCandidate> originals) async {
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

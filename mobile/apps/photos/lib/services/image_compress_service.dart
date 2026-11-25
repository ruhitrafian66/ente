// Offline fork: device side of the "Compress images" tool.
//
// The rules (which image is large for its pixels, the picture check, the
// encode -> compare -> save -> verify -> delete order) live in
// image_compress_core.dart. This file only connects them to photo_manager,
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
import "package:photos/services/image_compress_core.dart";
import "package:photos/services/image_compress_decode.dart";
import "package:photos/services/png_to_jpg_core.dart"
    show SavedJpeg, parsePngHeader;
import "package:photos/services/search_service.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:photos/src/rust/api/image_processing_api.dart" as rust_image;
import "package:photos/ui/settings/file_access_section.dart"
    show hasAllFilesAccess;

/// A large image found on the device, with the gallery file that shows its
/// thumbnail.
class ImageScanItem {
  final ImageCandidate candidate;
  final EnteFile file;

  /// When the file was last changed on the device (MediaStore
  /// DATE_MODIFIED). The page sorts by it.
  final DateTime modified;

  const ImageScanItem({
    required this.candidate,
    required this.file,
    required this.modified,
  });
}

/// What the scan did with the images of one device folder.
class ImageFolderReport {
  /// MediaStore RELATIVE_PATH, for example "Pictures/People/Ann/".
  final String folder;

  /// Outcome (one of the `ImageCompressService.outcome...` texts) to the
  /// number of files.
  final Map<String, int> counts;

  const ImageFolderReport({required this.folder, required this.counts});

  int get total => counts.values.fold(0, (a, b) => a + b);

  int get listed => counts[ImageCompressService.outcomeListed] ?? 0;
}

class ImageScanResult {
  /// Every image that is large for its pixel count, last modified first. The
  /// page separates the ones with a skip reason.
  final List<ImageScanItem> items;

  /// How many images the scan looked at.
  final int checked;

  /// One entry for each folder that has an image, by name.
  final List<ImageFolderReport> folders;

  const ImageScanResult({
    required this.items,
    required this.checked,
    this.folders = const [],
  });
}

/// Removes the given gallery files from the device in one request. Returns
/// the files that are gone.
typedef ImageOriginalsDeleter =
    Future<List<EnteFile>> Function(List<EnteFile> files);

class ImageCompressService {
  ImageCompressService._();

  static final ImageCompressService instance = ImageCompressService._();

  static const _scanConcurrency = 12;

  /// The system delete request takes a limited number of items.
  static const _deleteChunkSize = 1500;

  final _logger = Logger("ImageCompressService");

  static const outcomeListed = "Large for its pixels";
  static const outcomeNormal = "Normal size for its pixels";
  static const outcomeNotReadable = "The app cannot read the file";

  /// Folder to outcome to count, for the scan that is in progress.
  final Map<String, Map<String, int>> _outcomes = {};

  void _note(String? folder, String outcome) {
    final counts = _outcomes.putIfAbsent(
      folder == null || folder.isEmpty ? "(unknown folder)" : folder,
      () => {},
    );
    counts[outcome] = (counts[outcome] ?? 0) + 1;
  }

  /// Finds the images that are large for their pixel count, whatever
  /// their format or their name.
  Future<ImageScanResult> scan({
    void Function(int done, int total)? onProgress,
  }) async {
    _outcomes.clear();
    final allFiles = await SearchService.instance.getAllFilesForSearch();
    // The same asset is listed once for each device folder.
    final byLocalID = <String, EnteFile>{};
    for (final file in allFiles) {
      final localID = file.localID;
      if (localID == null ||
          localID.startsWith(sharedMediaIdentifier) ||
          file.fileType != FileType.image) {
        continue;
      }
      byLocalID.putIfAbsent(localID, () => file);
    }

    final files = byLocalID.values.toList();
    final items = <ImageScanItem>[];
    for (var i = 0; i < files.length; i += _scanConcurrency) {
      final end = min(i + _scanConcurrency, files.length);
      final batch = await Future.wait(
        files.sublist(i, end).map((file) => _inspect(file, report: true)),
      );
      items.addAll(batch.whereType<ImageScanItem>());
      onProgress?.call(end, files.length);
    }
    // Newest change first.
    items.sort((a, b) => b.modified.compareTo(a.modified));
    final folders = [
      for (final entry in _outcomes.entries)
        ImageFolderReport(
          folder: entry.key,
          counts: Map.unmodifiable(entry.value),
        ),
    ]..sort((a, b) => a.folder.toLowerCase().compareTo(b.folder.toLowerCase()));
    _logger.info(
      "Checked ${files.length} images in ${folders.length} folders, "
      "${items.length} are large for their pixel count",
    );
    for (final folder in folders) {
      _logger.info("Image scan, ${folder.folder}: ${folder.counts}");
    }
    return ImageScanResult(
      items: items,
      checked: files.length,
      folders: folders,
    );
  }

  /// Reads one image that the user chose in the viewer. Unlike the scan, it
  /// does not require the file to be large for its pixel count. Returns null
  /// when the app cannot read the file on the device.
  Future<ImageScanItem?> inspectSingle(EnteFile file) {
    if (file.localID == null) return Future.value(null);
    return _inspect(file, onlyLarge: false);
  }

  /// [report] counts the outcome for the folder report of a scan.
  Future<ImageScanItem?> _inspect(
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
      if (asset.type != AssetType.image) return out(outcomeNotReadable);
      final source = await asset.originFile;
      if (source == null) return out(outcomeNotReadable);
      final sizeBytes = await source.length();
      if (sizeBytes <= 0) return out(outcomeNotReadable);
      if (onlyLarge && sizeBytes < kImageCompressMinBytes) {
        return out(outcomeNormal);
      }
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

      // A large file. Its format comes from its data: the name and the
      // Android media type can both be wrong.
      final prefix = await _readPrefix(source.path, kJpegHeaderPrefixBytes);
      final format = sniffImageFormat(prefix) ?? "unknown";
      var width = asset.width;
      var height = asset.height;
      var components = 3;
      int? quality;
      var trailerBytes = 0;
      var isAnimated = false;
      if (format == "JPG") {
        // The whole file is necessary to find the end of the image.
        final bytes = await source.readAsBytes();
        final header = parseJpegHeader(bytes);
        if (header == null) {
          final start = bytes
              .take(16)
              .map((b) => b.toRadixString(16).padLeft(2, "0"))
              .join(" ");
          _logger.warning(
            "JPEG header not readable: ${bytes.length} bytes, starts with "
            "$start",
          );
          return out(outcomeNotReadable);
        }
        width = header.width;
        height = header.height;
        components = header.components;
        quality = header.estimatedQuality;
        trailerBytes =
            bytes.length - (findJpegPrimaryEnd(bytes) ?? bytes.length);
      } else if (format == "PNG") {
        final header = parsePngHeader(prefix);
        if (header != null) {
          width = header.width;
          height = header.height;
          isAnimated = header.isAnimated;
        }
      } else if (format == "WebP") {
        isAnimated = isAnimatedWebp(prefix);
      }
      if (width <= 0 || height <= 0) return out(outcomeNotReadable);
      if (onlyLarge &&
          !isLargeForItsPixels(
            sizeBytes: sizeBytes,
            width: width,
            height: height,
          )) {
        return out(outcomeNormal);
      }
      if (report) _note(folder, outcomeListed);

      final creationTime = file.creationTime ?? 0;
      return ImageScanItem(
        file: file,
        modified: asset.modifiedDateTime,
        candidate: ImageCandidate(
          id: asset.id,
          title: asset.title ?? file.title ?? p.basename(source.path),
          path: source.path,
          sizeBytes: sizeBytes,
          format: format,
          isAnimated: isAnimated,
          width: width,
          height: height,
          components: components,
          estimatedQuality: quality,
          trailerBytes: trailerBytes,
          // The gallery time is what places the file in the timeline.
          captureTime: creationTime > 0
              ? DateTime.fromMicrosecondsSinceEpoch(creationTime)
              : asset.createDateTime,
          relativePath: asset.relativePath,
          canWriteAnyFolder: await hasAllFilesAccess(),
        ),
      );
    } catch (e, s) {
      _logger.warning("Could not inspect an image", e, s);
      return out(outcomeNotReadable);
    }
  }

  /// A compressor whose delete step uses [deleteOriginals] (the page
  /// supplies it, because the delete helpers need a BuildContext).
  ImageCompressor compressor({
    required List<ImageScanItem> items,
    required ImageOriginalsDeleter deleteOriginals,
  }) {
    return ImageCompressor(
      _DeviceIo(
        filesByID: {for (final item in items) item.candidate.id: item.file},
        deleteOriginalFiles: deleteOriginals,
        chunkSize: _deleteChunkSize,
      ),
    );
  }

  /// One log line for each result: the record of what the tool did.
  void logResult(ImageCompressResult result) {
    final candidate = result.candidate;
    _logger.info(
      "${result.status.name}: ${candidate.format} "
      "${candidate.width}x${candidate.height} "
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
      _logger.warning("Local sync after image compression failed", e, s);
    }
  }
}

Future<Uint8List> _readPrefix(String path, int maxBytes) async {
  final file = await File(path).open();
  try {
    return await file.read(maxBytes);
  } finally {
    await file.close();
  }
}

class _DeviceIo implements ImageCompressIo {
  final Map<String, EnteFile> filesByID;
  final ImageOriginalsDeleter deleteOriginalFiles;
  final int chunkSize;
  final _logger = Logger("ImageCompressDeviceIo");

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
    return decodeUprightRgbaFromPath(path, maxPixels: kImageCompressMaxPixels);
  }

  @override
  Future<DecodedRgba?> decodeBytes(Uint8List bytes) {
    return decodeUprightRgbaFromBytes(
      bytes,
      maxPixels: kImageCompressMaxPixels,
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
    required ImageCandidate source,
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
  Future<Set<String>> deleteOriginals(List<ImageCandidate> originals) async {
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

// Offline fork: device side of the "Convert PNG to JPG" tool.
//
// The rules (what is a PNG, what has transparency, when a JPEG is kept, the
// encode -> write -> verify -> delete order) live in png_to_jpg_core.dart.
// This file only connects them to photo_manager, the Rust image bridge and
// the local database.

import "dart:io";
import "dart:math" show min;
import "dart:typed_data";
import "dart:ui" as ui;

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
import "package:photos/services/png_to_jpg_core.dart";
import "package:photos/services/search_service.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:photos/src/rust/api/image_processing_api.dart" as rust_image;

/// A PNG found on the device, with the gallery file that shows its thumbnail.
class PngScanItem {
  final PngCandidate candidate;
  final EnteFile file;

  const PngScanItem({required this.candidate, required this.file});
}

/// Removes the given gallery files from the device in one request. Returns
/// the files that are gone.
typedef PngOriginalsDeleter =
    Future<List<EnteFile>> Function(List<EnteFile> files);

class PngToJpgService {
  PngToJpgService._();

  static final PngToJpgService instance = PngToJpgService._();

  static const _scanConcurrency = 12;

  /// Images above this pixel count are not decoded for the transparency scan
  /// (the RGBA buffer would need more than 256 MB). They are reported as
  /// failed and stay as PNG.
  static const _maxPixelsForAlphaScan = 64 * 1000 * 1000;

  /// The system delete request takes a limited number of items.
  static const _deleteChunkSize = 1500;

  final _logger = Logger("PngToJpgService");

  /// Finds the PNG images on the device, largest first.
  Future<List<PngScanItem>> scan({
    void Function(int done, int total)? onProgress,
  }) async {
    final allFiles = await SearchService.instance.getAllFilesForSearch();
    // The same asset is listed once for each device folder.
    final byLocalID = <String, EnteFile>{};
    for (final file in allFiles) {
      final localID = file.localID;
      if (localID == null ||
          localID.startsWith(sharedMediaIdentifier) ||
          file.fileType != FileType.image ||
          !hasPngExtension(file.title)) {
        continue;
      }
      byLocalID.putIfAbsent(localID, () => file);
    }

    final files = byLocalID.values.toList();
    final items = <PngScanItem>[];
    for (var i = 0; i < files.length; i += _scanConcurrency) {
      final end = min(i + _scanConcurrency, files.length);
      final batch = await Future.wait(files.sublist(i, end).map(_inspect));
      items.addAll(batch.whereType<PngScanItem>());
      onProgress?.call(end, files.length);
    }
    items.sort(
      (a, b) => b.candidate.sizeBytes.compareTo(a.candidate.sizeBytes),
    );
    _logger.info("Found ${items.length} PNG files");
    return items;
  }

  Future<PngScanItem?> _inspect(EnteFile file) async {
    try {
      final asset = await AssetEntity.fromId(file.localID!);
      if (asset == null || asset.type != AssetType.image) return null;
      final title = asset.title ?? file.title;
      if (!looksLikePng(title: title, mimeType: asset.mimeType)) return null;
      final source = await asset.originFile;
      if (source == null) return null;
      final sizeBytes = await source.length();
      if (sizeBytes <= 0) return null;
      // The extension and the mime type can be wrong. The signature is not.
      final header = parsePngHeader(await _readPrefix(source.path, 64));
      if (header == null) return null;

      final creationTime = file.creationTime ?? 0;
      return PngScanItem(
        file: file,
        candidate: PngCandidate(
          id: asset.id,
          title: title ?? p.basename(source.path),
          path: source.path,
          sizeBytes: sizeBytes,
          width: header.width,
          height: header.height,
          // The gallery time is what places the file in the timeline.
          captureTime: creationTime > 0
              ? DateTime.fromMicrosecondsSinceEpoch(creationTime)
              : asset.createDateTime,
          relativePath: asset.relativePath,
        ),
      );
    } catch (e, s) {
      _logger.warning("Could not inspect a PNG candidate", e, s);
      return null;
    }
  }

  /// A converter whose delete step uses [deleteOriginals] (the page supplies
  /// it, because the delete helpers need a BuildContext).
  PngToJpgConverter converter({
    required List<PngScanItem> items,
    required PngOriginalsDeleter deleteOriginals,
  }) {
    return PngToJpgConverter(
      _DeviceIo(
        filesByID: {for (final item in items) item.candidate.id: item.file},
        deleteOriginals: deleteOriginals,
        chunkSize: _deleteChunkSize,
        maxPixelsForAlphaScan: _maxPixelsForAlphaScan,
      ),
    );
  }

  /// Makes the gallery pick up the new JPEGs. The delete helpers already
  /// report the removed PNGs.
  Future<void> refreshGallery() async {
    try {
      await LocalSyncService.instance.checkAndSync();
    } catch (e, s) {
      _logger.warning("Local sync after PNG conversion failed", e, s);
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

class _DeviceIo implements PngToJpgIo {
  final Map<String, EnteFile> filesByID;
  final PngOriginalsDeleter deleteOriginalFiles;
  final int chunkSize;
  final int maxPixelsForAlphaScan;
  final _logger = Logger("PngToJpgDeviceIo");

  _DeviceIo({
    required this.filesByID,
    required PngOriginalsDeleter deleteOriginals,
    required this.chunkSize,
    required this.maxPixelsForAlphaScan,
  }) : deleteOriginalFiles = deleteOriginals;

  @override
  Future<Uint8List> readPrefix(String path, int maxBytes) {
    return _readPrefix(path, maxBytes);
  }

  // The engine decodes on its own worker threads, so the UI isolate only
  // waits here.
  @override
  Future<Uint8List?> decodeRgba(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > maxPixelsForAlphaScan) {
        return null;
      }
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  // Native decode + encode on the Rust worker pool: full resolution, 16-bit
  // reduced to 8-bit, an embedded ICC profile converted to sRGB.
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
    required PngCandidate source,
  }) async {
    final relativePath = source.relativePath;
    if (relativePath == null || relativePath.trim().isEmpty) {
      throw StateError("The folder of the PNG is not known");
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
      throw StateError("The JPEG is not in the media library");
    }
    return File(saved.path).readAsBytes();
  }

  @override
  Future<ImageDimensions?> decodeDimensions(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (width: descriptor.width, height: descriptor.height);
      // A reduced target size still makes the codec read the whole file.
      codec = await descriptor.instantiateCodec(
        targetWidth: size.width > 256 ? 256 : size.width,
      );
      image = (await codec.getNextFrame()).image;
      return size;
    } catch (e) {
      _logger.warning("Saved JPEG does not decode", e);
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
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
        _logger.warning("Direct delete of a new JPEG failed", e);
      }
    }
    final asset = saved.id.isEmpty ? null : await AssetEntity.fromId(saved.id);
    if (asset != null && await asset.exists) {
      final removed = await PhotoManager.editor.deleteWithIds([saved.id]);
      if (!removed.contains(saved.id)) {
        throw StateError("Could not remove the new JPEG");
      }
    }
    if (saved.id.isEmpty) return;
    // Local sync may have listed the JPEG already.
    final rows = await FilesDB.instance.getLocalFiles([saved.id]);
    if (rows.isEmpty) return;
    await FilesDB.instance.deleteLocalFile(rows.first);
    Bus.instance.fire(
      LocalPhotosUpdatedEvent(
        rows,
        type: EventType.deletedFromDevice,
        source: "pngToJpgRollBack",
      ),
    );
  }

  @override
  Future<Set<String>> deleteOriginals(List<PngCandidate> originals) async {
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

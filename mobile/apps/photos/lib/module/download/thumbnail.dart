import 'dart:io';
import "dart:typed_data";

import 'package:ente_pure_utils/ente_pure_utils.dart'
    show deleteFileSystemEntityIfPresent, isFileSystemPathMissing;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:logging/logging.dart';
import 'package:native_video_editor/native_video_editor.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:photos/core/cache/thumbnail_in_memory_cache.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import "package:photos/models/file/extensions/file_props.dart";
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/module/download/file.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger("ThumbnailUtil");
const int _maximumThumbnailCompressionAttempts = 2;

Future<Uint8List> compressThumbnail(Uint8List thumbnail) {
  return FlutterImageCompress.compressWithList(
    thumbnail,
    minHeight: compressedThumbnailResolution,
    minWidth: compressedThumbnailResolution,
    quality: 25,
  );
}

Future<Uint8List> compressThumbnailToSizeLimit(
  Uint8List thumbnail, {
  int maxAttempts = _maximumThumbnailCompressionAttempts,
}) async {
  var result = thumbnail;
  for (
    var attempt = 0;
    result.length > thumbnailDataLimit && attempt < maxAttempts;
    attempt++
  ) {
    _logger.info("Thumbnail size ${result.length}");
    result = await compressThumbnail(result);
    _logger.info("Compressed thumbnail size ${result.length}");
  }
  return result;
}

Future<Uint8List?> getThumbnail(EnteFile file) async {
  if (file.isRemoteOnlyFile) {
    // Offline fork: there is no server. A file without a device copy only has
    // a thumbnail when one is already in the disk cache.
    return _readCachedThumbnailIfPresent(cachedThumbnailPath(file), file);
  } else {
    return getThumbnailFromLocal(file, size: thumbnailLargeSize);
  }
}

void preloadThumbnail(EnteFile file) {
  if (file.isRemoteOnlyFile) {
    return;
  }
  getThumbnailFromLocal(file).ignore();
}

// cachedThumbnailPath requires an uploaded file ID.
Future<File?> getThumbnailForUploadedFile(EnteFile file) async {
  final cachedThumbnail = cachedThumbnailPath(file);
  if (await cachedThumbnail.exists()) {
    _logger.info("Thumbnail already exists for ${file.uploadedFileID}");
    return cachedThumbnail;
  }
  final thumbnail = await getThumbnail(file);
  if (thumbnail != null) {
    // getThumbnail may have already written this path.
    if (!await cachedThumbnail.exists()) {
      final didWrite = await _writeCachedThumbnail(
        cachedThumbnail,
        thumbnail,
        flush: true,
      );
      if (!didWrite) {
        _logger.info(
          "Thumbnail obtained but not persisted for ${file.uploadedFileID}",
        );
        return null;
      }
    }
    _logger.info("Thumbnail obtained for ${file.uploadedFileID}");
    return cachedThumbnail;
  }
  _logger.severe("Failed to get thumbnail for ${file.uploadedFileID}");
  return null;
}

Future<Uint8List?> getThumbnailFromLocal(
  EnteFile file, {
  int size = thumbnailSmallSize,
  int quality = thumbnailQuality,
}) async {
  final lruCachedThumbnail = ThumbnailInMemoryLruCache.get(file, size);
  if (lruCachedThumbnail != null) {
    return lruCachedThumbnail;
  }
  if (file.isUploaded) {
    final cachedThumbnail = cachedThumbnailPath(file);
    final data = await _readCachedThumbnailIfPresent(
      cachedThumbnail,
      file,
      size: size,
    );
    if (data != null) {
      return data;
    }
  }
  if (file.isSharedMediaToAppSandbox) {
    //todo:neeraj support specifying size/quality
    return getThumbnailFromInAppCacheFile(file).then((data) {
      if (data != null) {
        ThumbnailInMemoryLruCache.put(file, data, size);
      }
      return data;
    });
  } else {
    return file.getAsset.then((asset) async {
      // asset.exists may return false for files in the android device trash
      if (asset == null || !(await asset.exists || file.isDeviceTrash)) {
        return null;
      }
      return asset
          .thumbnailDataWithSize(ThumbnailSize(size, size), quality: quality)
          .then((data) {
            ThumbnailInMemoryLruCache.put(file, data, size);
            return data;
          });
    });
  }
}

Future<Uint8List?> getThumbnailFromInAppCacheFile(EnteFile file) async {
  final localFile = File(getSharedMediaFilePath(file));
  if (!localFile.existsSync()) {
    return null;
  }
  if (file.fileType == FileType.video) {
    try {
      final result = await getVideoThumbnailFromInAppCacheFile(file);
      return result?.data;
    } catch (e) {
      _logger.warning('Failed to generate video thumbnail', e);
      return null;
    }
  }
  return compressThumbnailToSizeLimit(await localFile.readAsBytes());
}

Future<({Uint8List data, NativeVideoInfo info})?>
getVideoThumbnailFromInAppCacheFile(EnteFile file) async {
  final localFile = File(getSharedMediaFilePath(file));
  if (!localFile.existsSync() || file.fileType != FileType.video) {
    return null;
  }
  final thumbnailFile = File(
    p.join(
      Configuration.instance.getTempDirectory(),
      'video-thumbnail-${const Uuid().v4()}.jpg',
    ),
  );
  try {
    final extraction = await NativeVideoEditor.extractFrame(
      VideoFrameRequest(
        inputPath: localFile.path,
        outputPath: thumbnailFile.path,
        position: Duration.zero,
        maxWidth: thumbnailLargeSize,
        maxHeight: thumbnailLargeSize,
        quality: 80,
      ),
    );
    return (
      data: await compressThumbnailToSizeLimit(
        await thumbnailFile.readAsBytes(),
      ),
      info: extraction.videoInfo,
    );
  } finally {
    try {
      await deleteFileSystemEntityIfPresent(thumbnailFile);
    } catch (e, s) {
      _logger.warning('Failed to delete temporary video thumbnail', e, s);
    }
  }
}

Future<Uint8List?> _readCachedThumbnailIfPresent(
  File cachedThumbnail,
  EnteFile file, {
  int? size,
}) async {
  if (!await cachedThumbnail.exists()) {
    return null;
  }
  try {
    final data = await cachedThumbnail.readAsBytes();
    ThumbnailInMemoryLruCache.put(file, data, size);
    return data;
  } on FileSystemException catch (e) {
    if (isFileSystemPathMissing(e)) {
      _logger.info(
        "Thumbnail cache file missing during read; treating as cache miss: "
        "${cachedThumbnail.path}",
      );
      return null;
    }
    rethrow;
  }
}

Future<bool> _writeCachedThumbnail(
  File cachedThumbnail,
  Uint8List data, {
  bool flush = false,
}) async {
  try {
    await cachedThumbnail.writeAsBytes(data, flush: flush);
    return true;
  } on FileSystemException catch (e) {
    if (!isFileSystemPathMissing(e)) {
      rethrow;
    }
    _logger.info(
      "Thumbnail cache directory missing during write; recreating: "
      "${cachedThumbnail.parent.path}",
    );
    await cachedThumbnail.parent.create(recursive: true);
    try {
      await cachedThumbnail.writeAsBytes(data, flush: flush);
      return true;
    } on FileSystemException catch (retryError) {
      if (isFileSystemPathMissing(retryError)) {
        _logger.info(
          "Thumbnail cache path still missing after recreate; skipping write: "
          "${cachedThumbnail.path}",
        );
        return false;
      }
      rethrow;
    }
  }
}

File cachedThumbnailPath(EnteFile file) {
  final thumbnailCacheDirectory = Configuration.instance
      .getThumbnailCacheDirectory();
  final uploadedFileID = file.uploadedFileID;
  if (uploadedFileID != null && uploadedFileID != -1) {
    return File("$thumbnailCacheDirectory/$uploadedFileID");
  }

  final localID = file.localID;
  if (localID != null && localID.isNotEmpty) {
    return File(
      "$thumbnailCacheDirectory/local-${Uri.encodeComponent(localID)}",
    );
  }

  return File(
    "$thumbnailCacheDirectory/generated-${file.generatedID ?? "unknown"}",
  );
}

File cachedFaceCropPath(String faceID, bool useTempCache) {
  late final String thumbnailCacheDirectory;
  if (useTempCache) {
    thumbnailCacheDirectory = Configuration.instance
        .getThumbnailCacheDirectory();
  } else {
    thumbnailCacheDirectory = Configuration.instance
        .getPersonFaceThumbnailCacheDirectory();
  }
  return File(thumbnailCacheDirectory + "/" + faceID);
}

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:motionphoto/motionphoto.dart';
import 'package:path/path.dart';
import 'package:photos/core/cache/image_cache.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import "package:photos/models/file/extensions/file_props.dart";
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';

final _logger = Logger("FileUtil");

void preloadFile(EnteFile file) {
  if (file.fileType == FileType.video) {
    return;
  }
  getFile(file);
}

// IMPORTANT: Delete the returned file if `isOrigin` is set to true
// https://github.com/CaiJingLong/flutter_photo_manager#cache-problem-of-ios
Future<File?> getFile(
  EnteFile file, {
  bool liveVideo = false,
  bool isOrigin = false,
}) async {
  try {
    if (file.isRemoteOnlyFile) {
      // Offline fork: there is no server. A file without a device copy has no
      // bytes to return.
      return null;
    } else {
      final String key = file.tag + liveVideo.toString() + isOrigin.toString();
      final cachedFile = FileLruCache.get(key);
      if (cachedFile == null) {
        final diskFile = await _getLocalDiskFile(
          file,
          liveVideo: liveVideo,
          isOrigin: isOrigin,
        );
        // do not cache origin file for IOS as they are immediately deleted
        // after usage
        if (!(isOrigin && Platform.isIOS) && diskFile != null) {
          FileLruCache.put(key, diskFile);
        }
        return diskFile;
      }
      return cachedFile;
    }
  } catch (e, s) {
    _logger.warning("Failed to get file", e, s);
    return null;
  }
}

Future<bool> doesLocalFileExist(EnteFile file) async {
  return await _getLocalDiskFile(file) != null;
}

Future<File?> getFileForEditing(EnteFile file) async {
  final localFile = await getFile(file);
  if (localFile != null && await localFile.exists()) {
    return localFile;
  }
  return null;
}

Future<File?> _getLocalDiskFile(
  EnteFile file, {
  bool liveVideo = false,
  bool isOrigin = false,
}) async {
  // Return null because reading a device trash file by its file system path
  // fails with a permission-denied error.
  if (file.isDeviceTrash) {
    return null;
  }

  if (file.isSharedMediaToAppSandbox) {
    final localFile = File(getSharedMediaPathFromLocalID(file.localID!));
    return await localFile.exists() ? localFile : null;
  }

  if (file.fileType == FileType.livePhoto && liveVideo) {
    return await Motionphoto.getLivePhotoFile(file.localID!);
  }

  final asset = await file.getAsset;
  if (asset == null || !(await asset.exists)) {
    return null;
  }
  return isOrigin ? await asset.originFile : await asset.file;
}

String getSharedMediaFilePath(EnteFile file) {
  return getSharedMediaPathFromLocalID(file.localID!);
}

String getSharedMediaPathFromLocalID(String localID) {
  return Configuration.instance.getSharedMediaDirectory() +
      "/" +
      localID.replaceAll(sharedMediaIdentifier, '');
}

String getExtension(String nameOrPath) {
  var fileExtension = "unknown";
  try {
    fileExtension = extension(nameOrPath).substring(1).toLowerCase();
  } catch (e) {
    _logger.severe("Could not capture file extension");
  }
  return fileExtension;
}

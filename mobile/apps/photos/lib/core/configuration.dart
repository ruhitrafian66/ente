import "dart:async";
import "dart:io";

import 'package:backup_exclusion/backup_exclusion.dart';
import 'package:ente_lock_screen/lock_screen_host.dart';
import "package:flutter/services.dart";
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photos/core/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Offline fork: there is no account. This class only owns the app
// directories. It also is the host of the lock screen, which asks for the
// login state.
class Configuration implements LockScreenHost {
  Configuration._privateConstructor();

  static final Configuration instance = Configuration._privateConstructor();

  static const lastTempFolderClearTimeKey = "last_temp_folder_clear_time";
  static final _logger = Logger("Configuration");

  late String _documentsDirectory;
  late SharedPreferences _preferences;
  late String _tempDocumentsDirPath;
  late String _thumbnailCacheDirectory;
  late String _personFaceThumbnailCacheDirectory;

  late String _sharedDocumentsMediaDirectory;

  Future<void> init(SharedPreferences preferences) async {
    try {
      _preferences = preferences;
      _documentsDirectory = (await getApplicationDocumentsDirectory()).path;
      final appSupportDirectory = await getApplicationSupportDirectory();
      // Exclude Documents (SQLite, thumbnails) and Application Support (ML
      // models) from backups.
      await excludeFromBackup(_documentsDirectory);
      await excludeFromBackup(appSupportDirectory.path);
      _tempDocumentsDirPath = _documentsDirectory + "/temp/";
      final tempDocumentsDir = Directory(_tempDocumentsDirPath);
      await _cleanUpStaleFiles(tempDocumentsDir);
      tempDocumentsDir.createSync(recursive: true);
      final tempDirectoryPath = (await getTemporaryDirectory()).path;
      _thumbnailCacheDirectory = tempDirectoryPath + "/thumbnail-cache";
      Directory(_thumbnailCacheDirectory).createSync(recursive: true);
      _personFaceThumbnailCacheDirectory =
          _documentsDirectory + "/person-face-thumbnail-cache";
      Directory(_personFaceThumbnailCacheDirectory).createSync(recursive: true);
      _sharedDocumentsMediaDirectory =
          _documentsDirectory + "/ente-shared-media";
      Directory(_sharedDocumentsMediaDirectory).createSync(recursive: true);
      // Offline fork: upstream reads the token and the keys from the secure
      // storage here and wipes that storage when there is no token. The app
      // lock PIN lives in the secure storage, so this class does not touch it.
    } catch (e, s) {
      _logger.severe("Configuration init failed", e, s);
      // As before: a platform error is logged, all other errors stop the init.
      if (e is! PlatformException) {
        rethrow;
      }
    }
  }

  // Offline fork: the uploader is gone. This is the former
  // `isUploadTempArtifactPath` predicate, kept so that the temp clean-up
  // skips the same files as before.
  static bool _isUploadTempArtifactPath(String path) {
    final fileName = path.split(Platform.pathSeparator).last;
    return fileName.startsWith(uploadTempFilePrefix) &&
        fileName.endsWith('.encrypted');
  }

  Future<void> _cleanUpStaleFiles(Directory tempDocumentsDir) async {
    try {
      final currentTime = DateTime.now().microsecondsSinceEpoch;
      if (tempDocumentsDir.existsSync() &&
          (_preferences.getInt(lastTempFolderClearTimeKey) ?? 0) <
              (currentTime - tempDirCleanUpInterval)) {
        int skippedTempUploadFiles = 0;
        final files = tempDocumentsDir.listSync();
        for (final file in files) {
          if (file is File) {
            if (_isUploadTempArtifactPath(file.path)) {
              skippedTempUploadFiles++;
              continue;
            }
            _logger.info("Deleting file: ${file.path}");
            await file.delete();
          } else if (file is Directory) {
            await file.delete(recursive: true);
          }
        }
        await _preferences.setInt(lastTempFolderClearTimeKey, currentTime);
        _logger.info(
          "Cleared temp folder except $skippedTempUploadFiles upload files",
        );
      } else {
        _logger.info("Skipping temp folder clear");
      }
    } catch (e) {
      _logger.warning(e);
    }
  }

  // Offline fork: there is no account. The lock screen shows its logout
  // button only when logged in, so `logout` is never called.
  @override
  bool isLoggedIn() => false;

  @override
  Future<void> logout() async {}

  // Caution: This directory is cleared on app start
  String getTempDirectory() {
    return _tempDocumentsDirPath;
  }

  String getThumbnailCacheDirectory() {
    return _thumbnailCacheDirectory;
  }

  String getPersonFaceThumbnailCacheDirectory() {
    return _personFaceThumbnailCacheDirectory;
  }

  String getSharedMediaDirectory() {
    return _sharedDocumentsMediaDirectory;
  }
}

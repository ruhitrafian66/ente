import "package:photos/core/configuration.dart";
import "package:photos/db/offline_files_db.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/models/file/trash_file.dart";
import "package:photos/service_locator.dart" show isLocalGalleryMode;

extension FilePropsExtn on EnteFile {
  /// The file ID used as the key in the ML database (face IDs, clusters,
  /// manual person assignments).
  ///
  /// Account mode keys ML data by `uploadedFileID`. Local gallery mode (the
  /// only mode of the offline fork) keys it by the int ID that
  /// `OfflineFilesDB` assigns to the device `localID`. Use this getter instead
  /// of `uploadedFileID` in all people / face code.
  int? get mlFileID => isLocalGalleryMode
      ? OfflineFilesDB.instance.cachedLocalIntId(localID)
      : uploadedFileID;

  bool get isLivePhoto => fileType == FileType.livePhoto;

  bool get isMotionPhoto => (pubMagicMetadata?.mvi ?? 0) > 0;

  bool get isLiveOrMotionPhoto => isLivePhoto || isMotionPhoto;

  bool get isOwner =>
      (ownerID == null) || (ownerID == Configuration.instance.getUserID());

  bool get isVideo => fileType == FileType.video;

  bool get hasDims => height > 0 && width > 0;

  bool? isPanorama() {
    if (fileType != FileType.image) {
      return false;
    }
    if (pubMagicMetadata?.mediaType != null) {
      return (pubMagicMetadata!.mediaType! & 1) == 1;
    }
    return null;
  }

  bool canBePanorama() {
    if (hasDims) {
      if (height < 8000 && width < 8000) return false;
      if (height > width) {
        return height / width >= 2.0;
      }
      return width / height >= 2.0;
    }
    return false;
  }

  bool get canEditMetaInfo => isUploaded && isOwner;

  bool get isTrash => this is TrashFile;
  bool get isDeviceTrash => this is DeviceTrashFile;
  TrashFile? get asTrashFile => (this is TrashFile) ? this as TrashFile : null;
  DeviceTrashFile? get asDeviceTrashFile =>
      (this is DeviceTrashFile) ? this as DeviceTrashFile : null;

  bool get isCollect => uploaderName != null;

  String? get uploaderName => pubMagicMetadata?.uploaderName;

  String? get cameraMake => pubMagicMetadata?.cameraMake;

  String? get cameraModel => pubMagicMetadata?.cameraModel;

  String? get cameraLabel {
    final make = cameraMake?.trim();
    final model = cameraModel?.trim();
    if ((make == null || make.isEmpty) && (model == null || model.isEmpty)) {
      return null;
    }
    if (make != null && make.isNotEmpty && model != null && model.isNotEmpty) {
      return '$make $model';
    }
    return model ?? make;
  }

  bool get skipIndex => !isUploaded || fileType == FileType.other;
}

Set<int> filesToUploadedFileIDs(Iterable<EnteFile> files) => files
    .where((file) => file.isUploaded)
    .map((file) => file.uploadedFileID!)
    .toSet();

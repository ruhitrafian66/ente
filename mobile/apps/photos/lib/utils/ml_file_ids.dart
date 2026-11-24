import "package:photos/db/offline_files_db.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/services/search_service.dart";

/// Creation time for every file, keyed by the ML file ID (`EnteFile.mlFileID`).
///
/// Face clustering uses this to order faces. It is built from the device
/// files and their local int IDs.
Future<Map<int, int>> getMlFileIdToCreationTime() async {
  await OfflineFilesDB.instance.refreshIntIdCache();
  final files = await SearchService.instance.getAllFilesForSearch();
  final result = <int, int>{};
  for (final file in files) {
    final id = file.mlFileID;
    final creationTime = file.creationTime;
    if (id != null && creationTime != null) {
      result[id] = creationTime;
    }
  }
  return result;
}

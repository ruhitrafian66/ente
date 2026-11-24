import "package:photos/db/memories_db.dart";
import "package:photos/db/offline_files_db.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/metadata/common_keys.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/search_service.dart";

MemoriesDB get memoriesDB =>
    isLocalGalleryMode ? MemoriesDB.localGalleryInstance : MemoriesDB.instance;

Future<Map<int, EnteFile>> getFilesAndMapForMemories({
  bool useGeneratedIds = false,
  bool requireLocalId = false,
  bool useLocalIntIds = false,
}) async {
  final allFilesFromSearchService = await SearchService.instance
      .getAllFilesForSearch();
  final candidateFiles = <EnteFile>[];
  for (final file in allFilesFromSearchService) {
    final localId = file.localID;
    final hasLocalId = localId != null && localId.isNotEmpty;
    if (requireLocalId && !hasLocalId) {
      continue;
    }
    final hasId = useLocalIntIds
        ? hasLocalId
        : useGeneratedIds
        ? file.generatedID != null &&
              (file.uploadedFileID != null || hasLocalId)
        : file.uploadedFileID != null;
    if (hasId && file.creationTime != null) {
      if (file.magicMetadata.visibility == archiveVisibility ||
          file.magicMetadata.visibility == hiddenVisibility) {
        continue;
      }
      candidateFiles.add(file);
    }
  }
  final Map<String, int> localIdToIntId = useLocalIntIds
      ? await OfflineFilesDB.instance.ensureLocalIntIds(
          candidateFiles
              .map((file) => file.localID)
              .whereType<String>()
              .where((id) => id.isNotEmpty),
        )
      : <String, int>{};
  final allFileIdsToFile = <int, EnteFile>{};
  for (final file in candidateFiles) {
    final localIntId = useLocalIntIds ? localIdToIntId[file.localID] : null;
    final mappedFile = localIntId != null
        ? file.copyWith(generatedID: localIntId)
        : file;
    final key = useLocalIntIds
        ? localIntId
        : useGeneratedIds
        ? mappedFile.generatedID
        : mappedFile.uploadedFileID;
    if (key != null) {
      allFileIdsToFile[key] = mappedFile;
    }
  }
  return allFileIdsToFile;
}

/// Offline fork: server albums do not exist, so there is nothing to exclude.
Future<Set<int>> getCollectionIDsToExclude() async {
  return <int>{};
}

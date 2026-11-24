import "package:photos/core/configuration.dart";
import "package:photos/db/files_db.dart";
import "package:photos/gateways/collections/models/create_request.dart";
import "package:photos/models/collection/action.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_items.dart";
import "package:photos/models/file/file.dart";
import "package:photos/settings/local_settings.dart";
import "package:shared_preferences/shared_preferences.dart";

/// Offline fork: temporary STUB of the account-era collections service
/// (removal plan, stage 3, step 3a).
///
/// Ente collections (server albums) cannot exist in the fork: there is no
/// account, no network and no collections database. Each member below returns
/// what the old service returned with an empty collections database and no
/// user: empty lists, sets and maps, `null` for lookups, `false` for
/// predicates and `0` for counts. Each member that needs the server throws
/// [UnsupportedError].
///
/// Device folders are NOT collections. They live in `FilesDB`
/// (`device_files`, `device_collections`) and do not use this class.
///
/// Step 3b removes the call sites file by file and then deletes this file.
/// Do not add members here.
class CollectionsService {
  CollectionsService._privateConstructor();

  static final CollectionsService instance =
      CollectionsService._privateConstructor();

  static Never _unsupported() => throw UnsupportedError(
    "Collections are not available in the offline fork",
  );

  /// Read and written by the `HiddenService` extension. It is always null.
  Collection? cachedDefaultHiddenCollection;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// No-op. The old `init` loaded the (always empty) collections database and
  /// registered a listener that only cleared caches inside the old service.
  Future<void> init(SharedPreferences preferences) async {}

  /// No-op: there is no remote to sync with.
  Future<void> sync() async {}

  void clearCache() {
    cachedDefaultHiddenCollection = null;
  }

  // ---------------------------------------------------------------------
  // Accessors that the `HiddenService` extension reads
  // ---------------------------------------------------------------------

  Configuration get config => Configuration.instance;

  FilesDB get filesDB => FilesDB.instance;

  Map<int, Collection> get collectionIDToCollections =>
      const <int, Collection>{};

  // ---------------------------------------------------------------------
  // Lookups: nothing exists
  // ---------------------------------------------------------------------

  Collection? getCollectionByID(int collectionID) => null;

  List<Collection> getActiveCollections() => <Collection>[];

  List<Collection> getCollectionsForUI({
    bool includedShared = false,
    bool includeCollab = false,
    bool includeUncategorized = false,
  }) => <Collection>[];

  List<Collection> getRecentlyUsedCollections() => <Collection>[];

  void recordCollectionUsage(int collectionID) {}

  Future<List<Collection>> getArchivedCollection() async => <Collection>[];

  Future<List<Collection>> getCollectionForOnEnteSection() async =>
      <Collection>[];

  Future<List<Collection>> getCollectionForWidgetSelection() async =>
      <Collection>[];

  Future<SharedCollections> getSharedCollections() async =>
      SharedCollections.empty();

  Future<Map<int, int>> getCollectionIDToNewestFileTime() async => <int, int>{};

  // ---------------------------------------------------------------------
  // Hidden and archive. The callers pass these sets to the FilesDB filters
  // as the collection IDs to ignore. Each call returns a new mutable set
  // because one caller adds to it.
  // ---------------------------------------------------------------------

  List<Collection> getHiddenCollections({bool includeDefaultHidden = true}) =>
      <Collection>[];

  Set<int> getHiddenCollectionIds() => <int>{};

  Set<int> archivedOrHiddenCollectionIds() => <int>{};

  // ---------------------------------------------------------------------
  // Sort helpers: there is nothing to sort
  // ---------------------------------------------------------------------

  Future<void> sortCollectionsByAlbumPreferences(
    List<Collection> collections, {
    AlbumSortKey? sortKey,
    AlbumSortDirection? sortDirection,
  }) async {}

  Future<List<Collection>> orderCollectionsForAlbums(
    Iterable<Collection> collections,
  ) async => collections.toList();

  // ---------------------------------------------------------------------
  // Queries about one collection or one file
  // ---------------------------------------------------------------------

  Future<EnteFile?> getCover(Collection c) async => null;

  EnteFile? getCoverCache(Collection c) => null;

  Future<int> getFileCount(Collection c, {bool useCache = true}) async => 0;

  int? getCachedFileCount(Collection c) => null;

  bool canRemoveFilesFromAllParticipants(Collection collection) => false;

  Future<bool> isFileInSharedCollection(int uploadedFileID) async => false;

  String getSharedPublicAlbumKey(int collectionID) => "";

  String? getSharedPublicAlbumToken(int collectionID) => null;

  // ---------------------------------------------------------------------
  // Server reads. The old service failed with a network error here.
  // ---------------------------------------------------------------------

  Future<Collection> fetchCollectionByID(int collectionID) async =>
      _unsupported();

  Future<List<CollectionAction>> fetchPendingRemovalActions() async =>
      _unsupported();

  Future<List<int>> fetchDeleteSuggestionFileIDs() async => _unsupported();

  // ---------------------------------------------------------------------
  // Mutators. All of them need the server.
  // ---------------------------------------------------------------------

  /// The old service created the collection on the server when it was absent.
  Future<Collection> getUncategorizedCollection() async => _unsupported();

  Future<Collection> createAlbum(String albumName) async => _unsupported();

  Future<Collection> createAndCacheCollection(
    CreateRequest createRequest,
  ) async => _unsupported();

  Future<void> rename(Collection collection, String newName) async =>
      _unsupported();

  Future<void> leaveAlbum(Collection collection) async => _unsupported();

  Future<void> trashNonEmptyCollection(Collection collection) async =>
      _unsupported();

  Future<void> trashEmptyCollection(
    Collection collection, {
    bool isBulkDelete = false,
  }) async => _unsupported();

  Future<void> updateMagicMetadata(
    Collection collection,
    Map<String, dynamic> newMetadataUpdate,
  ) async => _unsupported();

  Future<void> updatePublicMagicMetadata(
    Collection collection,
    Map<String, dynamic> newMetadataUpdate,
  ) async => _unsupported();

  Future<void> updateShareeMagicMetadata(
    Collection collection,
    Map<String, dynamic> newMetadataUpdate,
  ) async => _unsupported();

  Future<void> disableShareUrl(Collection collection) async => _unsupported();

  Future<void> addOrCopyToCollection(
    int dstCollectionID,
    List<EnteFile> files, {
    bool toCopy = true,
  }) async => _unsupported();

  /// Same as the old service: an empty list is not an error.
  Future<void> addSilentlyToCollection(
    int collectionID,
    List<EnteFile> files,
  ) async {
    if (files.isEmpty) {
      return;
    }
    _unsupported();
  }

  Future<void> restore(int toCollectionID, List<EnteFile> files) async =>
      _unsupported();

  Future<void> move(
    List<EnteFile> files, {
    required int toCollectionID,
    required int fromCollectionID,
  }) async => _unsupported();

  Future<void> removeFromCollection(
    int collectionID,
    List<EnteFile> files,
  ) async => _unsupported();

  Future<void> suggestDeleteFromCollection(
    int collectionID,
    List<EnteFile> files,
  ) async => _unsupported();

  /// Same as the old service: an empty list is not an error.
  Future<void> rejectDeleteSuggestions(List<int> fileIDs) async {
    if (fileIDs.isEmpty) {
      return;
    }
    _unsupported();
  }
}

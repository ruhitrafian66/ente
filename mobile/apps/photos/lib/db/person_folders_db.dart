import "package:logging/logging.dart";
import "package:photos/db/common/base.dart";
import "package:photos/services/person_folders/person_folder_planner.dart";
import "package:sqlite_async/sqlite_async.dart";

// Offline fork: state of the "Sort photos into person folders" tool. This is
// a separate database file, so no upstream schema changes.
//
// * `person_folder_moves`: one row for each file that the tool moved and that
//   is still in a person folder. `original_folder` is where "Restore all"
//   puts the file back. `previous_folder` is set only while a move is in
//   flight, see `PersonFolderExecutor`.
// * `person_folder_names`: the folder name of each named person, so that two
//   persons with the same name keep their folders from run to run.
class PersonFoldersDB with SqlDbBase implements PersonFolderStore {
  static final Logger _logger = Logger("PersonFoldersDB");

  static const _databaseName = "ente.offline_person_folders.db";

  static const _movesTable = "person_folder_moves";
  static const _localIdColumn = "local_id";
  static const _originalFolderColumn = "original_folder";
  static const _originalNameColumn = "original_name";
  static const _personFolderColumn = "person_folder";
  static const _previousFolderColumn = "previous_folder";
  static const _personIdColumn = "person_id";
  static const _movedAtColumn = "moved_at";

  static const _namesTable = "person_folder_names";
  static const _baseNameColumn = "base_name";
  static const _folderNameColumn = "folder_name";

  static const _moveColumns =
      "$_localIdColumn, $_originalFolderColumn, $_originalNameColumn, "
      "$_personFolderColumn, $_previousFolderColumn, $_personIdColumn, "
      "$_movedAtColumn";

  static const List<String> _migrationScripts = [
    '''
CREATE TABLE IF NOT EXISTS $_movesTable (
  $_localIdColumn TEXT NOT NULL PRIMARY KEY,
  $_originalFolderColumn TEXT NOT NULL,
  $_originalNameColumn TEXT NOT NULL,
  $_personFolderColumn TEXT NOT NULL,
  $_previousFolderColumn TEXT,
  $_personIdColumn TEXT NOT NULL,
  $_movedAtColumn INTEGER NOT NULL
)
''',
    '''
CREATE TABLE IF NOT EXISTS $_namesTable (
  $_personIdColumn TEXT NOT NULL PRIMARY KEY,
  $_baseNameColumn TEXT NOT NULL,
  $_folderNameColumn TEXT NOT NULL
)
''',
  ];

  PersonFoldersDB._privateConstructor();

  static final PersonFoldersDB instance = PersonFoldersDB._privateConstructor();

  Future<SqliteDatabase> get _db => getOrOpenDatabase(
    () => openMigratedDatabase(
      _databaseName,
      _migrationScripts,
      logPath: (path) => _logger.info("Opening person folders DB at $path"),
    ),
  );

  Future<List<PersonFolderRecord>> getRecords() async {
    final db = await _db;
    final rows = await db.getAll("SELECT $_moveColumns FROM $_movesTable");
    return [
      for (final row in rows)
        PersonFolderRecord(
          localId: row[_localIdColumn] as String,
          originalFolder: row[_originalFolderColumn] as String,
          originalName: row[_originalNameColumn] as String,
          personFolder: row[_personFolderColumn] as String,
          previousFolder: row[_previousFolderColumn] as String?,
          personId: row[_personIdColumn] as String,
          movedAtMs: row[_movedAtColumn] as int,
        ),
    ];
  }

  Future<int> getRecordCount() async {
    final db = await _db;
    final row = await db.get("SELECT COUNT(*) AS count FROM $_movesTable");
    return row["count"] as int;
  }

  @override
  Future<void> applyRecordChanges({
    Iterable<PersonFolderRecord> upserts = const [],
    Iterable<String> deletes = const [],
  }) async {
    final upsertSets = [
      for (final record in upserts)
        [
          record.localId,
          record.originalFolder,
          record.originalName,
          record.personFolder,
          record.previousFolder,
          record.personId,
          record.movedAtMs,
        ],
    ];
    final deleteSets = [
      for (final id in deletes) [id],
    ];
    if (upsertSets.isEmpty && deleteSets.isEmpty) return;
    final db = await _db;
    await db.writeTransaction((tx) async {
      if (upsertSets.isNotEmpty) {
        await tx.executeBatch(
          "INSERT OR REPLACE INTO $_movesTable ($_moveColumns) "
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
          upsertSets,
        );
      }
      if (deleteSets.isNotEmpty) {
        await tx.executeBatch(
          "DELETE FROM $_movesTable WHERE $_localIdColumn = ?",
          deleteSets,
        );
      }
    });
  }

  Future<List<PersonFolderName>> getFolderNames() async {
    final db = await _db;
    final rows = await db.getAll(
      "SELECT $_personIdColumn, $_baseNameColumn, $_folderNameColumn "
      "FROM $_namesTable",
    );
    return [
      for (final row in rows)
        PersonFolderName(
          personId: row[_personIdColumn] as String,
          baseName: row[_baseNameColumn] as String,
          folderName: row[_folderNameColumn] as String,
        ),
    ];
  }

  @override
  Future<void> saveFolderNames(List<PersonFolderName> names) async {
    final db = await _db;
    await db.writeTransaction((tx) async {
      await tx.execute("DELETE FROM $_namesTable");
      if (names.isEmpty) return;
      await tx.executeBatch(
        "INSERT OR REPLACE INTO $_namesTable "
        "($_personIdColumn, $_baseNameColumn, $_folderNameColumn) "
        "VALUES (?, ?, ?)",
        [
          for (final name in names)
            [name.personId, name.baseName, name.folderName],
        ],
      );
    });
  }
}

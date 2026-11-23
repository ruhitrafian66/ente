import "package:logging/logging.dart";
import "package:photos/db/common/base.dart";
import "package:photos/services/exact_duplicates/exact_duplicate_finder.dart";
import "package:sqlite_async/sqlite_async.dart";

// Offline fork: content hashes of device files for the "Exact duplicates"
// tool. This is a separate database file, so no upstream schema changes.
//
// A row is valid only while the size and modified time of the file on disk
// are equal to the stored values. The reader does that comparison, see
// `CachedFileHash.matches`.
class ExactDuplicatesDB with SqlDbBase implements FileHashCache {
  static final Logger _logger = Logger("ExactDuplicatesDB");

  static const _databaseName = "ente.offline_exact_duplicates.db";
  static const _table = "file_content_hash";
  static const _localIdColumn = "local_id";
  static const _sizeColumn = "size";
  static const _modifiedMsColumn = "modified_ms";
  static const _sha256Column = "sha256";

  static const List<String> _migrationScripts = [
    '''
CREATE TABLE IF NOT EXISTS $_table (
  $_localIdColumn TEXT NOT NULL PRIMARY KEY,
  $_sizeColumn INTEGER NOT NULL,
  $_modifiedMsColumn INTEGER NOT NULL,
  $_sha256Column TEXT NOT NULL
)
''',
  ];

  ExactDuplicatesDB._privateConstructor();

  static final ExactDuplicatesDB instance =
      ExactDuplicatesDB._privateConstructor();

  Future<SqliteDatabase> get _db => getOrOpenDatabase(
    () => openMigratedDatabase(
      _databaseName,
      _migrationScripts,
      logPath: (path) => _logger.info("Opening exact duplicates DB at $path"),
    ),
  );

  @override
  Future<Map<String, CachedFileHash>> loadAll() async {
    final db = await _db;
    final rows = await db.getAll(
      'SELECT $_localIdColumn, $_sizeColumn, $_modifiedMsColumn, $_sha256Column FROM $_table',
    );
    return {
      for (final row in rows)
        row[_localIdColumn] as String: CachedFileHash(
          size: row[_sizeColumn] as int,
          modifiedMs: row[_modifiedMsColumn] as int,
          hash: row[_sha256Column] as String,
        ),
    };
  }

  @override
  Future<void> saveAll(Map<String, CachedFileHash> entries) async {
    if (entries.isEmpty) return;
    final db = await _db;
    await db.executeBatch(
      'INSERT OR REPLACE INTO $_table ($_localIdColumn, $_sizeColumn, $_modifiedMsColumn, $_sha256Column) VALUES (?, ?, ?, ?)',
      [
        for (final entry in entries.entries)
          [
            entry.key,
            entry.value.size,
            entry.value.modifiedMs,
            entry.value.hash,
          ],
      ],
    );
  }

  @override
  Future<void> removeAll(Iterable<String> ids) async {
    final parameterSets = [
      for (final id in ids) [id],
    ];
    if (parameterSets.isEmpty) return;
    final db = await _db;
    await db.executeBatch(
      'DELETE FROM $_table WHERE $_localIdColumn = ?',
      parameterSets,
    );
  }
}

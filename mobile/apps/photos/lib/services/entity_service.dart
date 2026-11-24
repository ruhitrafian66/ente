import 'dart:convert';

import "package:crypto/crypto.dart";
import "package:nanoid/nanoid.dart";
import "package:photos/db/entities_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/models/entity_type.dart";
import "package:photos/models/local_entity_data.dart";
import 'package:shared_preferences/shared_preferences.dart';

// Offline fork: entities (persons, location tags) live only in the local
// `entities` table of FilesDB. No entity key, no encryption, no server.
class EntityService {
  final SharedPreferences _prefs;
  late final FilesDB _db = FilesDB.instance;

  EntityService(this._prefs);

  String _getEntityLastSyncTimePrefix(EntityType type) {
    return "entity_last_sync_time_" + type.name;
  }

  Future<List<LocalEntityData>> getCertainEntities(
    EntityType type,
    List<String> ids,
  ) async {
    return await _db.getCertainEntities(type, ids);
  }

  Future<List<LocalEntityData>> getEntities(EntityType type) async {
    return await _db.getEntities(type);
  }

  Future<LocalEntityData?> getEntity(EntityType type, String id) async {
    return await _db.getEntity(type, id);
  }

  Future<LocalEntityData> addOrUpdate(
    EntityType type,
    Map<String, dynamic> jsonMap, {
    String? id,
  }) async {
    final String plainText = jsonEncode(jsonMap);
    final localData = LocalEntityData(
      id: id ?? "local_${nanoid()}",
      type: type,
      data: plainText,
      ownerID: 0,
      updatedAt: DateTime.now().microsecondsSinceEpoch,
    );
    await _db.upsertEntities([localData]);
    return localData;
  }

  Future<void> deleteEntry(String id) async {
    await _db.deleteEntities([id]);
  }

  // Offline fork: nothing writes this value, so it stays 0. PersonService
  // uses it as a cache stamp.
  int lastSyncTime(EntityType type) {
    return _prefs.getInt(_getEntityLastSyncTimePrefix(type)) ?? 0;
  }

  Future<String?> getPreHashForEntities(
    EntityType type,
    List<String> ids,
  ) async {
    return await _db.getPreHashForEntities(type, ids);
  }

  Future<String> getHashForIds(List<String> personIds) async {
    final preHash = await getPreHashForEntities(EntityType.cgroup, personIds);

    if (preHash == null) {
      return "";
    }

    final hash = md5.convert(utf8.encode(preHash)).toString().substring(0, 10);
    return hash;
  }

  Future<Map<String, int>> getUpdatedAts(
    EntityType type,
    List<String> personIds,
  ) async {
    return await _db.getUpdatedAts(type, personIds);
  }
}

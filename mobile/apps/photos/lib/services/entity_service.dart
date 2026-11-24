import 'dart:async';
import 'dart:convert';

import "package:crypto/crypto.dart";
import "package:ente_crypto/ente_crypto.dart";
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import "package:nanoid/nanoid.dart";
import "package:photos/core/configuration.dart";
import "package:photos/db/entities_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/gateways/entity/entity_gateway.dart";
import "package:photos/gateways/entity/models/key.dart";
import "package:photos/gateways/entity/models/type.dart";
import "package:photos/models/local_entity_data.dart";
import 'package:shared_preferences/shared_preferences.dart';

class EntityService {
  static const int fetchLimit = 500;
  final _logger = Logger((EntityService).toString());
  final SharedPreferences _prefs;
  final EntityGateway _gateway;
  final _config = Configuration.instance;
  late final FilesDB _db = FilesDB.instance;

  EntityService(this._prefs, this._gateway) {
    debugPrint("EntityService constructor");
  }

  String _getEntityKeyPrefix(EntityType type) {
    return "entity_key_" + type.name;
  }

  String _getEntityHeaderPrefix(EntityType type) {
    return "entity_key_header_" + type.name;
  }

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
    bool addWithCustomID = false,
    int? expectedUpdatedAt,
  }) async {
    final String plainText = jsonEncode(jsonMap);
    // Offline fork: entities (persons) live only in the local entities
    // table. No entity key, no encryption, no server round trip.
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

  // Offline fork: there is no server, so there is nothing to sync.
  Future<void> syncEntities() async {}

  Future<int> syncEntity(EntityType type) async => 0;

  int lastSyncTime(EntityType type) {
    return _prefs.getInt(_getEntityLastSyncTimePrefix(type)) ?? 0;
  }

  Future<Uint8List> getOrCreateEntityKey(EntityType type) async {
    late String encryptedKey;
    late String header;
    try {
      if (_prefs.containsKey(_getEntityKeyPrefix(type)) &&
          _prefs.containsKey(_getEntityHeaderPrefix(type))) {
        encryptedKey = _prefs.getString(_getEntityKeyPrefix(type))!;
        header = _prefs.getString(_getEntityHeaderPrefix(type))!;
      } else {
        final EntityKey response = await _gateway.getKey(type);
        encryptedKey = response.encryptedKey;
        header = response.header;
        await _prefs.setString(_getEntityKeyPrefix(type), encryptedKey);
        await _prefs.setString(_getEntityHeaderPrefix(type), header);
      }
      final entityKey = CryptoUtil.decryptSync(
        CryptoUtil.base642bin(encryptedKey),
        _config.getKey()!,
        CryptoUtil.base642bin(header),
      );
      return entityKey;
    } on EntityKeyNotFound {
      _logger.info("EntityKeyNotFound generating key for type $type");
      final key = CryptoUtil.generateKey();
      final encryptedKeyData = CryptoUtil.encryptSync(key, _config.getKey()!);
      encryptedKey = CryptoUtil.bin2base64(encryptedKeyData.encryptedData!);
      header = CryptoUtil.bin2base64(encryptedKeyData.nonce!);
      await _gateway.createKey(type, encryptedKey, header);
      await _prefs.setString(_getEntityKeyPrefix(type), encryptedKey);
      await _prefs.setString(_getEntityHeaderPrefix(type), header);
      return key;
    } catch (e, s) {
      _logger.severe("Failed to getOrCreateKey for type $type", e, s);
      rethrow;
    }
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

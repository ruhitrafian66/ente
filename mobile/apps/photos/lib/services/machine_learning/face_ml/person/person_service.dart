import "dart:async";
import "dart:convert";
import "dart:developer";

import "package:computer/computer.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:flutter/foundation.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/models/entity_type.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/local_entity_data.dart";
import "package:photos/models/ml/face/detection.dart";
import 'package:photos/models/ml/face/face_with_embedding.dart';
import "package:photos/models/ml/face/person.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/services/machine_learning/ml_result.dart";
import "package:photos/settings/local_settings.dart";
import "package:photos/utils/contact_string_util.dart";
import "package:photos/utils/face/face_thumbnail_cache.dart";
import "package:photos/utils/face_crop_util.dart";
import "package:shared_preferences/shared_preferences.dart";

typedef ManualPersonAssignmentResult = ({
  PersonEntity person,
  List<int> addedFileIds,
  List<int> alreadyAssignedFileIds,
});
typedef PersonAvatarUpdateResult = ({
  PersonEntity person,
  bool contactPictureUpdateFailed,
});

class PersonService {
  static const Object _attributeNotProvided = Object();
  final EntityService entityService;
  final IMLDataDB<int> faceMLDataDB;
  final SharedPreferences prefs;
  final _personsByEmail = <String, PersonEntity>{};
  final _personsByUserId = <int, PersonEntity>{};

  PersonService(this.entityService, this.faceMLDataDB, this.prefs);

  static PersonService? _instance;
  static const double kDefaultAutoMergeThreshold = 0.24;
  static double autoMergeThreshold = kDefaultAutoMergeThreshold;

  Future<List<PersonEntity>>? _cachedPersonsFuture;
  Map<String, PersonEntity>? _cachedPersonsById;
  int _personCacheGeneration = 0;
  int _cachedRemoteSyncTime = 0;

  // Static so the feedback-sync state machine survives init() re-creating the
  // instance; an in-flight sync must keep serializing new requests.
  static bool _shouldReconcilePeople = false;
  static bool _syncRequested = false;
  static Future<void>? _syncFuture;

  static PersonService get instance {
    if (_instance == null) {
      throw Exception("PersonService not initialized");
    }
    return _instance!;
  }

  static bool get isInitialized => _instance != null;

  late Logger logger = Logger("PersonService");

  static void init(
    EntityService entityService,
    IMLDataDB<int> faceMLDataDB,
    SharedPreferences prefs,
  ) {
    final bool isFirstInit = _instance == null;
    _instance = PersonService(entityService, faceMLDataDB, prefs);
    if (isFirstInit) {
      Bus.instance.on<PeopleChangedEvent>().listen((event) {
        if (event.type != PeopleEventType.syncDone) {
          _shouldReconcilePeople = true;
          // Offline fork: no remote sync will ever trigger the reconcile, so
          // run it after each local people change.
          unawaited(instance.sync());
        }
      });
    }
    final settings = LocalSettings(prefs);
    final savedAutoMerge = settings.autoMergeThresholdOverride;
    if (savedAutoMerge != null) {
      autoMergeThreshold = savedAutoMerge.clamp(0.0, 1.0);
    }
  }

  Iterable<String> get cachedLinkedPersonEmails => _personsByEmail.values
      .map((person) => person.data.email)
      .whereType<String>();

  PersonEntity? getCachedPersonForUser(int? userID, String email) {
    final requestedUserID = userID != null && userID > 0 ? userID : null;
    final userIdMatch = requestedUserID == null
        ? null
        : _personsByUserId[requestedUserID];
    if (userIdMatch != null) return userIdMatch;

    final normalizedEmail = normalizeContactLinkEmail(email);
    if (normalizedEmail == null) return null;
    final emailMatch = _personsByEmail[normalizedEmail];
    return emailMatch != null &&
            _canUseEmailFallback(emailMatch, requestedUserID)
        ? emailMatch
        : null;
  }

  static PersonEntity? findPersonForUser(
    Iterable<PersonEntity> persons, {
    required int? userID,
    required String? email,
    String? excludedPersonID,
  }) {
    bool include(PersonEntity person) => person.remoteID != excludedPersonID;
    final requestedUserID = userID != null && userID > 0 ? userID : null;
    if (requestedUserID != null) {
      for (final person in persons) {
        if (include(person) && person.data.userID == requestedUserID) {
          return person;
        }
      }
    }

    final normalizedEmail = normalizeContactLinkEmail(email);
    if (normalizedEmail == null) return null;
    for (final person in persons) {
      if (include(person) &&
          _canUseEmailFallback(person, requestedUserID) &&
          normalizeContactLinkEmail(person.data.email) == normalizedEmail) {
        return person;
      }
    }
    return null;
  }

  // When an account ID was requested, email fallback is limited to legacy
  // persons without one.
  static bool _canUseEmailFallback(PersonEntity person, int? requestedUserID) {
    return requestedUserID == null || (person.data.userID ?? 0) <= 0;
  }

  void clearCache() {
    _personsByEmail.clear();
    _personsByUserId.clear();
    _invalidatePersonCache();
    _cachedRemoteSyncTime = 0;
  }

  void _invalidatePersonCache() {
    _cachedPersonsFuture = null;
    _cachedPersonsById = null;
    _personCacheGeneration++;
  }

  Future<void> refreshPersonCache({
    bool notifyListeners = false,
    String source = "",
  }) async {
    _invalidatePersonCache();
    await getPersons();
    if (notifyListeners) {
      Bus.instance.fire(
        PeopleChangedEvent(type: PeopleEventType.syncDone, source: source),
      );
    }
  }

  Future<List<PersonEntity>> getCertainPersons(List<String> ids) async {
    final entities = await entityService.getCertainEntities(
      EntityType.cgroup,
      ids,
    );
    return entities
        .map(
          (e) => PersonEntity(e.id, PersonData.fromJson(json.decode(e.data))),
        )
        .toList();
  }

  int lastRemoteSyncTime() {
    return entityService.lastSyncTime(EntityType.cgroup);
  }

  Future<List<PersonEntity>> getPersons() async {
    final remoteSyncTime = lastRemoteSyncTime();
    if (_cachedRemoteSyncTime != remoteSyncTime) {
      _cachedRemoteSyncTime = remoteSyncTime;
      _invalidatePersonCache();
    }
    if (_cachedPersonsFuture == null) {
      final generation = _personCacheGeneration;
      _cachedPersonsFuture = _fetchAndCachePersons(generation);
    }
    return _cachedPersonsFuture!;
  }

  Future<List<PersonEntity>> _fetchAndCachePersons(int generation) async {
    logger.finest("reading all persons from local db");
    final entities = await entityService.getEntities(EntityType.cgroup);
    final persons = await Computer.shared().compute(
      _decodePersonEntities,
      param: {"entity": entities},
      taskName: "decode_person_entities",
    );
    if (generation != _personCacheGeneration) {
      return persons;
    }
    _cachedPersonsById = {
      for (final person in persons) person.remoteID: person,
    };
    _personsByEmail.clear();
    _personsByUserId.clear();
    for (PersonEntity person in persons) {
      final email = normalizeContactLinkEmail(person.data.email);
      if (email != null) {
        _personsByEmail[email] = person;
      }
      final userID = person.data.userID;
      if (userID != null && userID > 0) {
        _personsByUserId[userID] = person;
      }
    }

    return persons;
  }

  static List<PersonEntity> _decodePersonEntities(Map<String, dynamic> param) {
    final entities = param["entity"] as List<LocalEntityData>;
    return entities
        .map(
          (e) => PersonEntity(e.id, PersonData.fromJson(json.decode(e.data))),
        )
        .toList();
  }

  Future<PersonEntity?> getPerson(String id) {
    return entityService.getEntity(EntityType.cgroup, id).then((e) {
      if (e == null) {
        return null;
      }
      return PersonEntity(e.id, PersonData.fromJson(json.decode(e.data)));
    });
  }

  PersonEntity? getCachedPerson(String id) {
    if (_cachedRemoteSyncTime != lastRemoteSyncTime()) {
      return null;
    }
    return _cachedPersonsById?[id];
  }

  Future<Map<String, PersonEntity>> getPersonsMap() async {
    final persons = await getPersons();
    return _cachedPersonsById ??
        {for (final person in persons) person.remoteID: person};
  }

  Future<void> sync() {
    _syncRequested = true;
    return _syncFuture ??= _runPendingSyncs();
  }

  Future<void> _runPendingSyncs() async {
    try {
      do {
        _syncRequested = false;
        await _syncOnce();
      } while (_syncRequested);
    } finally {
      _syncFuture = null;
    }
  }

  Future<void> _syncOnce() async {
    // Offline fork: there is nothing to pull, but the local reconcile still
    // runs. It keeps `PersonData.assigned` in step with the cluster -> person
    // table, which the People UI reads.
    if (_shouldReconcilePeople) {
      _shouldReconcilePeople = false;
      try {
        await _reconcileClusters();
      } catch (_) {
        _shouldReconcilePeople = true;
        rethrow;
      }
      Bus.instance.fire(PeopleChangedEvent(type: PeopleEventType.syncDone));
    }
  }

  Future<void> _reconcileClusters() async {
    final EnteWatch? w = kDebugMode ? EnteWatch("reconcileClusters") : null;
    w?.start();
    final dbPersonClusterInfo = await faceMLDataDB
        .getPersonToClusterIdToFaceIds();
    w?.log("Got DB person cluster info");
    final persons = await getPersonsMap();
    w?.log("Got persons");
    int orphanMappingsRemoved = 0;
    final entityUpdates = <Future<LocalEntityData>>[];
    for (var personID in dbPersonClusterInfo.keys) {
      final person = persons[personID];
      if (person == null) {
        logger.severe("Person $personID not found");
        await _removeOrphanedLocalPerson(personID);
        orphanMappingsRemoved++;
        continue;
      }
      final Map<String, Set<String>> dbPersonCluster =
          dbPersonClusterInfo[personID]!;
      final personData = person.data;
      final bool shouldUpdateAssigned = _shouldUpdateRemotePerson(
        personData,
        dbPersonCluster,
      );

      bool shouldUpdateManualAssignments = false;
      List<int>? updatedManualAssignments;
      if (personData.manuallyAssigned.isNotEmpty) {
        final manualFileIDs = personData.manuallyAssigned;
        final manualFileIDSet = manualFileIDs.toSet();
        final coveredManualFileIDs = <int>{};

        outerLoop:
        for (final faceIDs in dbPersonCluster.values) {
          for (final faceID in faceIDs) {
            final fileID = tryGetFileIdFromFaceId(faceID);
            if (fileID == null || !manualFileIDSet.contains(fileID)) {
              continue;
            }
            coveredManualFileIDs.add(fileID);
            if (coveredManualFileIDs.length == manualFileIDSet.length) {
              break outerLoop;
            }
          }
        }

        shouldUpdateManualAssignments = coveredManualFileIDs.isNotEmpty;
        if (shouldUpdateManualAssignments) {
          updatedManualAssignments = manualFileIDs
              .where((fileID) => !coveredManualFileIDs.contains(fileID))
              .toList();
        }
      }

      if (!shouldUpdateAssigned && !shouldUpdateManualAssignments) {
        continue;
      }

      var updatedPersonData = personData;
      if (shouldUpdateAssigned) {
        updatedPersonData = updatedPersonData.copyWith(
          assigned: dbPersonCluster.entries
              .map((e) => ClusterInfo(id: e.key, faces: e.value))
              .toList(),
        );
      }

      if (shouldUpdateManualAssignments) {
        updatedPersonData = updatedPersonData.copyWith(
          manuallyAssigned: updatedManualAssignments ?? <int>[],
        );
      }

      entityUpdates.add(
        _addOrUpdateEntity(
          EntityType.cgroup,
          updatedPersonData.toJson(),
          id: personID,
        ),
      );
      updatedPersonData.logStats();
    }
    await Future.wait(entityUpdates);
    if (orphanMappingsRemoved > 0) {
      logger.warning(
        "Removed $orphanMappingsRemoved orphaned local person mappings during reconcile",
      );
    }
    w?.log("Reconciled clusters for ${persons.length} persons");
  }

  bool _shouldUpdateRemotePerson(
    PersonData personData,
    Map<String, Set<String>> dbPersonCluster,
  ) {
    if (personData.assigned.length != dbPersonCluster.length) {
      log(
        "Person ${personData.name} has ${personData.assigned.length} clusters, but ${dbPersonCluster.length} clusters found in DB",
        name: "PersonService",
      );
      return true;
    } else {
      for (ClusterInfo info in personData.assigned) {
        final dbCluster = dbPersonCluster[info.id];
        if (dbCluster == null) {
          log(
            "Cluster ${info.id} not found in DB for person ${personData.name}",
            name: "PersonService",
          );
          return true;
        }
        if (info.faces.length != dbCluster.length) {
          log(
            "Cluster ${info.id} has ${info.faces.length} faces, but ${dbCluster.length} faces found in DB",
            name: "PersonService",
          );
          return true;
        }
        for (var faceId in info.faces) {
          if (!dbCluster.contains(faceId)) {
            log(
              "Face $faceId not found in cluster ${info.id} for person ${personData.name}",
              name: "PersonService",
            );
            return true;
          }
        }
      }
    }
    return false;
  }

  Future<PersonEntity> addPerson({
    required String name,
    required String clusterID,
    bool isHidden = false,
    bool isPinned = false,
    bool hideFromMemories = false,
    String? birthdate,
    String? email,
    int? userID,
  }) async {
    final faceIds = await faceMLDataDB.getFaceIDsForCluster(clusterID);
    final data = PersonData(
      name: name,
      assigned: <ClusterInfo>[
        ClusterInfo(id: clusterID, faces: faceIds.toSet()),
      ],
      isHidden: isHidden,
      isPinned: isPinned,
      hideFromMemories: hideFromMemories,
      birthDate: birthdate,
      email: email,
      userID: userID,
    );
    final result = await _addOrUpdateEntity(EntityType.cgroup, data.toJson());
    await faceMLDataDB.assignClusterToPerson(
      personID: result.id,
      clusterID: clusterID,
    );
    if (data.email != null) {
      await refreshPersonCache();
    }
    memoriesCacheService.queueUpdateCache();
    return PersonEntity(result.id, data);
  }

  Future<void> removeClusterToPerson({
    required String personID,
    required String clusterID,
  }) async {
    final person = (await getPerson(personID))!;
    final personData = person.data;
    final clusterInfo = personData.assigned.firstWhere(
      (element) => element.id == clusterID,
      orElse: () => ClusterInfo(id: "noSuchClusterInRemotePerson", faces: {}),
    );
    if (clusterInfo.id == "noSuchClusterInRemotePerson") {
      await faceMLDataDB.removeClusterToPerson(
        personID: personID,
        clusterID: clusterID,
      );
      return;
    }
    personData.rejectedFaceIDs.addAll(clusterInfo.faces);
    personData.assigned.removeWhere((element) => element.id == clusterID);
    await _addOrUpdateEntity(
      EntityType.cgroup,
      personData.toJson(),
      id: personID,
    );
    await faceMLDataDB.removeClusterToPerson(
      personID: personID,
      clusterID: clusterID,
    );
    personData.logStats();
  }

  Future<void> removeFacesFromPerson({
    required PersonEntity person,
    required Set<String> faceIDs,
  }) async {
    final personData = person.data;

    final List<String> emptiedClusters = [];
    for (final cluster in personData.assigned) {
      cluster.faces.removeWhere((faceID) => faceIDs.contains(faceID));
      if (cluster.faces.isEmpty) {
        emptiedClusters.add(cluster.id);
      }
    }

    for (final emptyClusterID in emptiedClusters) {
      personData.assigned.removeWhere(
        (element) => element.id == emptyClusterID,
      );
      await faceMLDataDB.removeClusterToPerson(
        personID: person.remoteID,
        clusterID: emptyClusterID,
      );
    }

    personData.rejectedFaceIDs.addAll(faceIDs);

    await _addOrUpdateEntity(
      EntityType.cgroup,
      personData.toJson(),
      id: person.remoteID,
    );
    personData.logStats();
  }

  Future<void> deletePerson(String personID, {bool onlyMapping = false}) async {
    final entity = await getPerson(personID);
    if (onlyMapping) {
      if (entity == null) {
        return;
      }
      final PersonEntity justName = PersonEntity(
        personID,
        PersonData(name: entity.data.name),
      );
      await _addOrUpdateEntity(
        EntityType.cgroup,
        justName.data.toJson(),
        id: personID,
      );
      await faceMLDataDB.removePerson(personID);
      justName.data.logStats();

      if (entity.data.email != null) {
        await refreshPersonCache();
      }
    } else {
      await entityService.deleteEntry(personID);
      await faceMLDataDB.removePerson(personID);
      _invalidatePersonCache();

      if (entity != null) {
        if (entity.data.email != null) {
          await refreshPersonCache();
        }
      }
    }

    Bus.instance.fire(PeopleChangedEvent());
  }

  /// Offline fork: merges person [sourceID] into person [targetID].
  ///
  /// Every face cluster and manual file assignment of the source moves to the
  /// target, then the source person is deleted. The target keeps its own
  /// name, avatar and other attributes. Upstream has no person-to-person
  /// merge; it can only assign an unnamed cluster to a person.
  Future<PersonEntity> mergePersons({
    required String sourceID,
    required String targetID,
  }) async {
    if (sourceID == targetID) {
      throw ArgumentError("Cannot merge a person into itself");
    }
    final source = await getPerson(sourceID);
    final target = await getPerson(targetID);
    if (source == null || target == null) {
      throw Exception("Person not found for merge ($sourceID -> $targetID)");
    }

    final sourceClusterIDs = await faceMLDataDB.getPersonClusterIDs(sourceID);
    // Remove the source mappings first so that a cluster never maps to two
    // persons, whatever the uniqueness rules of the mapping table are.
    await faceMLDataDB.removePerson(sourceID);
    if (sourceClusterIDs.isNotEmpty) {
      await faceMLDataDB.bulkAssignClusterToPersonID({
        for (final clusterID in sourceClusterIDs) clusterID: targetID,
      });
    }

    final mergedManual = <int>{
      ...target.data.manuallyAssigned,
      ...source.data.manuallyAssigned,
    }.toList();
    final targetClusters = await faceMLDataDB.getPersonToClusterIdToFaceIds();
    final updatedTarget = target.copyWith(
      data: target.data.copyWith(
        manuallyAssigned: mergedManual,
        assigned: (targetClusters[targetID] ?? const {}).entries
            .map((e) => ClusterInfo(id: e.key, faces: e.value))
            .toList(),
      ),
    );
    await updatePerson(updatedTarget);
    await entityService.deleteEntry(sourceID);
    _invalidatePersonCache();
    await refreshPersonCache();
    memoriesCacheService.queueUpdateCache();
    Bus.instance.fire(PeopleChangedEvent());
    return updatedTarget;
  }

  Future<FaceWithoutEmbedding?> getCoverFace({
    required int fileID,
    String? personID,
    String? avatarFaceID,
    String? clusterID,
  }) async {
    final face = await faceMLDataDB.getCoverFaceForPerson(
      recentFileID: fileID,
      personID: personID,
      avatarFaceId: avatarFaceID,
      clusterID: clusterID,
    );
    if (face != null) return face;
    Set<String>? assignedIDs;
    if (avatarFaceID != null &&
        tryGetFileIdFromFaceId(avatarFaceID) == fileID &&
        tryParseFaceBoxFromFaceID(avatarFaceID) != null) {
      final faceClusterID = await faceMLDataDB.getClusterIDForFaceID(
        avatarFaceID,
      );
      final isAssigned =
          faceClusterID != null &&
          (personID != null
              ? (await faceMLDataDB.getPersonClusterIDs(
                  personID,
                )).contains(faceClusterID)
              : faceClusterID == clusterID);
      if (isAssigned) assignedIDs = {avatarFaceID};
    }
    assignedIDs ??=
        (personID != null
                ? await faceMLDataDB.getFaceIDsForPerson(personID)
                : await faceMLDataDB.getFaceIDsForCluster(clusterID!))
            .toSet();
    final candidates = [?avatarFaceID, ...assignedIDs];
    for (final faceID in candidates) {
      if (!assignedIDs.contains(faceID) ||
          tryGetFileIdFromFaceId(faceID) != fileID) {
        continue;
      }
      final box = tryParseFaceBoxFromFaceID(faceID);
      if (box == null) continue;
      return FaceWithoutEmbedding(
        faceID,
        fileID,
        0,
        Detection(box: box, landmarks: []),
        0,
      );
    }
    return null;
  }

  Future<PersonAvatarUpdateResult> updateAvatar(
    PersonEntity p,
    EnteFile file,
  ) async {
    final FaceWithoutEmbedding? face = await getCoverFace(
      fileID: file.mlFileID!,
      personID: p.remoteID,
    );
    if (face == null) {
      throw Exception(
        "No face found for person ${p.remoteID} in file ${file.mlFileID}",
      );
    }

    final person = (await getPerson(p.remoteID))!;
    final updatedPerson = person.copyWith(
      data: person.data.copyWith(avatarFaceId: face.faceID),
    );
    await updatePerson(updatedPerson);
    await putFaceIdCachedForPersonOrCluster(p.remoteID, face.faceID);
    // Offline fork: there are no linked contacts, so this is always false.
    return (person: updatedPerson, contactPictureUpdateFailed: false);
  }

  Future<PersonEntity> updateAttributes(
    String id, {
    String? name,
    String? avatarFaceId,
    bool? isHidden,
    bool? isPinned,
    bool? hideFromMemories,
    Object? birthDate = _attributeNotProvided,
    Object? email = _attributeNotProvided,
    Object? userID = _attributeNotProvided,
    // Offline fork: no linked contacts exist. The parameter has no effect.
    bool syncLinkedContactName = true,
  }) async {
    final person = (await getPerson(id))!;
    var updatedData = person.data.copyWith(
      name: name,
      avatarFaceId: avatarFaceId,
      isHidden: isHidden,
      isPinned: isPinned,
      hideFromMemories: hideFromMemories,
    );
    if (!identical(birthDate, _attributeNotProvided)) {
      updatedData = updatedData.copyWith(birthDate: birthDate as String?);
    }
    if (!identical(email, _attributeNotProvided)) {
      updatedData = updatedData.copyWith(email: email as String?);
    }
    if (!identical(userID, _attributeNotProvided)) {
      updatedData = updatedData.copyWith(userID: userID as int?);
    }
    final updatedPerson = person.copyWith(data: updatedData);
    await updatePerson(updatedPerson);
    await refreshPersonCache();
    if (hideFromMemories == true && !person.data.hideFromMemories) {
      // Offline fork: there is no account, so no person is the current user.
      unawaited(
        memoriesCacheService.purgePersonFromMemoriesCache(
          id,
          isCurrentUser: false,
        ),
      );
    }
    return updatedPerson;
  }

  Future<ManualPersonAssignmentResult> addManualFileAssignments({
    required String personID,
    required Set<int> fileIDs,
  }) async {
    final person = await getPerson(personID);
    if (person == null) {
      throw Exception("Person $personID not found");
    }
    if (fileIDs.isEmpty) {
      return (
        person: person,
        addedFileIds: const <int>[],
        alreadyAssignedFileIds: const <int>[],
      );
    }
    final existingClusterFileIds = await faceMLDataDB.getFileIdToClusterIDSet(
      personID,
    );
    final manualFileIDs = person.data.manuallyAssigned.toSet();
    final addedFileIDs = <int>[];
    final alreadyAssigned = <int>[];
    for (final id in fileIDs) {
      if (existingClusterFileIds.containsKey(id) ||
          manualFileIDs.contains(id)) {
        alreadyAssigned.add(id);
        continue;
      }
      addedFileIDs.add(id);
    }
    if (addedFileIDs.isEmpty) {
      return (
        person: person,
        addedFileIds: const <int>[],
        alreadyAssignedFileIds: alreadyAssigned,
      );
    }
    final updatedPerson = person.copyWith(
      data: person.data.copyWith(
        manuallyAssigned: [...manualFileIDs, ...addedFileIDs],
      ),
    );
    await updatePerson(updatedPerson);
    await refreshPersonCache();
    return (
      person: updatedPerson,
      addedFileIds: addedFileIDs,
      alreadyAssignedFileIds: alreadyAssigned,
    );
  }

  Future<void> updatePerson(PersonEntity updatePerson) async {
    try {
      await _addOrUpdateEntity(
        EntityType.cgroup,
        updatePerson.data.toJson(),
        id: updatePerson.remoteID,
      );
      updatePerson.data.logStats();
    } catch (e, s) {
      logger.severe("Failed to update person", e, s);
      rethrow;
    }
  }

  Future<LocalEntityData> _addOrUpdateEntity(
    EntityType type,
    Map<String, dynamic> jsonMap, {
    String? id,
  }) async {
    final result = await entityService.addOrUpdate(type, jsonMap, id: id);
    _invalidatePersonCache();
    return result;
  }

  Future<void> _removeOrphanedLocalPerson(String personID) async {
    logger.warning(
      "Removing local ML mappings for person $personID because entity no longer exists",
    );
    await faceMLDataDB.removePerson(personID);
  }
}

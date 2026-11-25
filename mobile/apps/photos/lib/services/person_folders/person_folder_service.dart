// Offline fork: device side of the "Sort photos into person folders" tool.
//
// The rules (who gets a folder, which file moves where, how the move records
// stay correct) are in person_folder_planner.dart. This file connects them
// to MediaStore (photo_manager), the ML database, the person list and the
// local file database.
//
// How a file moves: the app sets the MediaStore `RELATIVE_PATH` column of the
// image (`PhotoManager.editor.android.moveAssetsToPath`). MediaStore renames
// the file on disk and keeps the row, so the `_ID` of the image (the app
// `localID`) does not change and all face data stays valid. With the
// "media management" special access (`MANAGE_MEDIA`) Android shows no prompt.
// The request needs an Activity, so the tool runs only while the app is in
// the foreground.

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:ente_photos_platform/ente_photos_platform.dart"
    show LocalMediaClient;
import "package:flutter/widgets.dart";
import "package:logging/logging.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/base.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/db/offline_files_db.dart";
import "package:photos/db/person_folders_db.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/models/ml/face/face_with_embedding.dart";
import "package:photos/services/app_lifecycle_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/ml_result.dart"
    show tryGetFileIdFromFaceId;
import "package:photos/services/person_folders/person_folder_planner.dart";
import "package:photos/services/search_service.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:synchronized/synchronized.dart";

export "package:photos/services/person_folders/person_folder_planner.dart"
    show
        PersonFolderSkipReason,
        isInPersonFoldersRoot,
        kPersonFoldersRoot,
        kPersonFolderSourceRoots;

/// Files in one move request.
///
/// The plugin does the MediaStore updates of one request on the platform
/// main thread, and each update makes MediaStore scan the file again. A large
/// request can thus block the UI for seconds. Keep this number small.
const int kPersonFolderMoveBatchSize = 50;

/// Wait after the last people change or ML run before the tool runs.
const Duration kPersonFolderDebounce = Duration(seconds: 30);

/// An image in MediaStore.
class PersonFolderDeviceImage {
  final String id;

  /// Folder relative to the volume root. Null when MediaStore does not give
  /// the location.
  final String? folder;
  final String name;
  final bool isTrashed;
  final bool isVideo;

  const PersonFolderDeviceImage({
    required this.id,
    required this.folder,
    required this.name,
    this.isTrashed = false,
    this.isVideo = false,
  });
}

/// The device operations of the tool. Tests replace it with a fake.
abstract class PersonFolderPlatform implements PersonFolderMover {
  /// False on a platform or OS version that cannot move files in MediaStore.
  bool get isSupported;

  /// True when Android moves files without a prompt for each request.
  Future<bool> canMoveWithoutPrompt();

  /// True when the app can read all photos (not "selected photos" only).
  Future<bool> hasFullAccess();

  /// Waits a short time for the app to be in the foreground. Returns false
  /// when it is not.
  Future<bool> waitUntilForeground();

  /// All images in MediaStore that are not in the trash.
  Future<List<PersonFolderDeviceImage>> listImages();

  /// One image, also when it is in the trash. Null when the device does not
  /// return it. Null is not a proof that the file is gone, see
  /// [isConfirmedAbsent].
  Future<PersonFolderDeviceImage?> find(String id);

  /// True only when the device confirms that no file has this ID, also not
  /// in the trash or on storage that was removed a short time ago.
  Future<bool> isConfirmedAbsent(String id);

  /// Absolute path of the directory that holds the image now.
  Future<String?> absoluteFolderOf(String id);

  /// Removes the directory when it is an empty person folder. Never removes
  /// a directory that has an entry.
  Future<bool> deleteFolderIfEmpty(String absolutePath);

  /// Makes the local file database read the new folders of the files.
  Future<void> refreshGallery();
}

enum PersonFolderPhase { idle, preparing, moving, finishing }

class PersonFolderProgress {
  final PersonFolderPhase phase;
  final int done;
  final int total;
  final bool isRestore;

  const PersonFolderProgress(
    this.phase, {
    this.done = 0,
    this.total = 0,
    this.isRestore = false,
  });

  bool get isRunning => phase != PersonFolderPhase.idle;
}

/// What a run would do. Nothing is changed.
class PersonFolderDryRun {
  final int toSort;
  final int toResort;
  final int toRestore;

  /// Number of person folders that get a file.
  final int folderCount;
  final Map<PersonFolderSkipReason, int> skipped;

  const PersonFolderDryRun({
    required this.toSort,
    required this.toResort,
    required this.toRestore,
    required this.folderCount,
    required this.skipped,
  });

  int get total => toSort + toResort + toRestore;
}

class PersonFolderRunSummary {
  final int finishedAtMs;
  final bool isRestoreAll;
  final bool isAutomatic;

  /// Files moved into a person folder (first move or a different person).
  final int moved;

  /// Files moved back to their original folder.
  final int restored;

  /// [PersonFolderSkipReason] name to the number of files.
  final Map<String, int> skipped;

  /// Records removed because the file is gone or was moved by something
  /// else.
  final int recordsDropped;

  /// Planned moves that the run did not try.
  final int notTried;
  final bool stopped;
  final String? error;

  const PersonFolderRunSummary({
    required this.finishedAtMs,
    required this.isRestoreAll,
    required this.isAutomatic,
    this.moved = 0,
    this.restored = 0,
    this.skipped = const {},
    this.recordsDropped = 0,
    this.notTried = 0,
    this.stopped = false,
    this.error,
  });

  int get skippedTotal => skipped.values.fold(0, (sum, count) => sum + count);

  Map<String, dynamic> toJson() => {
    "finishedAtMs": finishedAtMs,
    "isRestoreAll": isRestoreAll,
    "isAutomatic": isAutomatic,
    "moved": moved,
    "restored": restored,
    "skipped": skipped,
    "recordsDropped": recordsDropped,
    "notTried": notTried,
    "stopped": stopped,
    "error": error,
  };

  factory PersonFolderRunSummary.fromJson(Map<String, dynamic> json) {
    return PersonFolderRunSummary(
      finishedAtMs: json["finishedAtMs"] as int? ?? 0,
      isRestoreAll: json["isRestoreAll"] as bool? ?? false,
      isAutomatic: json["isAutomatic"] as bool? ?? false,
      moved: json["moved"] as int? ?? 0,
      restored: json["restored"] as int? ?? 0,
      skipped: {
        for (final entry
            in (json["skipped"] as Map<String, dynamic>? ?? const {}).entries)
          entry.key: entry.value as int,
      },
      recordsDropped: json["recordsDropped"] as int? ?? 0,
      notTried: json["notTried"] as int? ?? 0,
      stopped: json["stopped"] as bool? ?? false,
      error: json["error"] as String?,
    );
  }
}

class PersonFolderService {
  PersonFolderService._privateConstructor();

  static final PersonFolderService instance =
      PersonFolderService._privateConstructor();

  /// SharedPreferences key of the toggle. Off by default.
  static const String enabledKey = "offline_person_folders_enabled";
  static const String _lastRunKey = "offline_person_folders_last_run";

  /// Shortest time between two automatic runs that start because the app
  /// came back to the foreground.
  static const Duration _minRestartInterval = Duration(minutes: 10);

  /// Above this number of images with two or more named persons, the face
  /// boxes come from one query for all faces.
  static const int _maxFaceBoxQueries = 400;

  static final Logger _logger = Logger("PersonFolderService");

  /// Progress of the run in flight.
  final ValueNotifier<PersonFolderProgress> progress = ValueNotifier(
    const PersonFolderProgress(PersonFolderPhase.idle),
  );

  /// Result of the last run that changed something or was started by hand.
  final ValueNotifier<PersonFolderRunSummary?> lastRun = ValueNotifier(null);

  SharedPreferences? _prefs;
  PersonFolderPlatform _platform = _PhotoManagerPlatform();
  final Lock _lock = Lock();
  Timer? _debounceTimer;
  StreamSubscription<PeopleChangedEvent>? _peopleSubscription;
  AppLifecycleListener? _lifecycleListener;
  bool _isRunning = false;
  bool _rerunRequested = false;
  bool _stopRequested = false;
  bool _autoRunPending = false;
  DateTime? _lastAutoRunAt;

  /// Moves that failed in this app session. An automatic run does not try
  /// them again, so a file that Android refuses does not cause a request in
  /// each run. "Sort now" clears the list.
  final Set<String> _failedMoves = {};

  bool get isInitialized => _prefs != null;

  bool get isSupported => _platform.isSupported;

  bool get isRunning => _isRunning;

  bool get isEnabled => _prefs?.getBool(enabledKey) ?? false;

  /// Call one time in the foreground isolate, after `PersonService.init`.
  /// Do not call it in the background isolate: a move needs an Activity.
  void init(SharedPreferences prefs, {PersonFolderPlatform? platform}) {
    if (_prefs != null) return;
    _prefs = prefs;
    if (platform != null) _platform = platform;
    lastRun.value = _readLastRun();
    _peopleSubscription = Bus.instance.on<PeopleChangedEvent>().listen(
      (event) => scheduleReconcile("people changed (${event.type.name})"),
    );
    try {
      _lifecycleListener = AppLifecycleListener(onRestart: _onAppRestart);
    } catch (e) {
      _logger.warning("No lifecycle listener", e);
    }
    if (isEnabled) scheduleReconcile("startup");
  }

  /// For tests.
  @visibleForTesting
  Future<void> dispose() async {
    _debounceTimer?.cancel();
    await _peopleSubscription?.cancel();
    _lifecycleListener?.dispose();
    _peopleSubscription = null;
    _lifecycleListener = null;
    _prefs = null;
  }

  /// Turns the automatic sort on or off. Off stops a sort run in flight and
  /// all further moves. It does not move a file back.
  Future<void> setEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) throw StateError("PersonFolderService is not ready");
    await prefs.setBool(enabledKey, enabled);
    _logger.info("Person folders ${enabled ? "on" : "off"}");
    if (!enabled) {
      _debounceTimer?.cancel();
      _autoRunPending = false;
    }
  }

  /// Hook for the end of an ML indexing and clustering run. Safe to call in
  /// each isolate: it does nothing where [init] did not run.
  void onMlRunFinished() => scheduleReconcile("ML run finished");

  /// Starts an automatic run [kPersonFolderDebounce] after the last call.
  void scheduleReconcile(String reason) {
    if (!isInitialized || !isEnabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(kPersonFolderDebounce, () {
      unawaited(_autoRun(reason));
    });
  }

  Future<bool> canMoveWithoutPrompt() => _platform.canMoveWithoutPrompt();

  Future<int> getRecordCount() => PersonFoldersDB.instance.getRecordCount();

  /// Asks the run in flight to stop after the current request.
  void requestStop() {
    if (_isRunning) _stopRequested = true;
  }

  /// Counts what "Sort now" would do. Changes nothing.
  Future<PersonFolderDryRun> dryRun() {
    return _lock.synchronized(() async {
      if (!await _platform.hasFullAccess()) {
        throw StateError("The app does not have access to all photos");
      }
      final plan = await _plan(restoreAll: false, failedMoves: const {});
      return PersonFolderDryRun(
        toSort: plan.count(PersonFolderMoveKind.sort),
        toResort: plan.count(PersonFolderMoveKind.resort),
        toRestore: plan.count(PersonFolderMoveKind.restore),
        folderCount: {
          for (final move in plan.moves)
            if (move.kind != PersonFolderMoveKind.restore)
              personFolderKey(move.toFolder),
        }.length,
        skipped: plan.skipCounts,
      );
    });
  }

  /// Runs the sort now. The toggle must be on.
  Future<PersonFolderRunSummary> sortNow() {
    _debounceTimer?.cancel();
    _failedMoves.clear();
    return _run(restoreAll: false, isAutomatic: false);
  }

  /// Turns the toggle off and moves each recorded file back to its original
  /// folder.
  Future<PersonFolderRunSummary> restoreAll() async {
    await setEnabled(false);
    // Stop a sort run in flight; the restore starts when it is done.
    requestStop();
    return _run(restoreAll: true, isAutomatic: false);
  }

  void _onAppRestart() {
    if (!isEnabled) return;
    final last = _lastAutoRunAt;
    if (_autoRunPending ||
        last == null ||
        DateTime.now().difference(last) >= _minRestartInterval) {
      scheduleReconcile("app in foreground");
    }
  }

  Future<void> _autoRun(String reason) async {
    if (!isEnabled || !_platform.isSupported) return;
    if (_isRunning) {
      _rerunRequested = true;
      return;
    }
    try {
      if (!await _platform.waitUntilForeground()) {
        _logger.info("Not in the foreground, run later ($reason)");
        _autoRunPending = true;
        return;
      }
      if (!await _platform.canMoveWithoutPrompt()) {
        _logger.warning("No media management access, automatic run skipped");
        return;
      }
    } catch (e, s) {
      _logger.warning("Could not check the run conditions", e, s);
      return;
    }
    _logger.info("Automatic run: $reason");
    _autoRunPending = false;
    await _run(restoreAll: false, isAutomatic: true);
    _lastAutoRunAt = DateTime.now();
  }

  Future<PersonFolderRunSummary> _run({
    required bool restoreAll,
    required bool isAutomatic,
  }) {
    return _lock.synchronized(() async {
      _isRunning = true;
      _stopRequested = false;
      PersonFolderRunSummary summary;
      try {
        summary = await _runLocked(
          restoreAll: restoreAll,
          isAutomatic: isAutomatic,
        );
      } catch (e, s) {
        _logger.severe("Person folder run failed", e, s);
        summary = PersonFolderRunSummary(
          finishedAtMs: DateTime.now().millisecondsSinceEpoch,
          isRestoreAll: restoreAll,
          isAutomatic: isAutomatic,
          error: "$e",
        );
      } finally {
        _isRunning = false;
        _stopRequested = false;
        progress.value = const PersonFolderProgress(PersonFolderPhase.idle);
      }
      final changedSomething =
          summary.moved > 0 ||
          summary.restored > 0 ||
          summary.recordsDropped > 0 ||
          summary.error != null;
      if (!isAutomatic || changedSomething) {
        lastRun.value = summary;
        await _prefs?.setString(_lastRunKey, jsonEncode(summary.toJson()));
      }
      if (_rerunRequested) {
        _rerunRequested = false;
        scheduleReconcile("change during a run");
      }
      return summary;
    });
  }

  Future<PersonFolderRunSummary> _runLocked({
    required bool restoreAll,
    required bool isAutomatic,
  }) async {
    final stopwatch = Stopwatch()..start();
    PersonFolderRunSummary refused(String error) => PersonFolderRunSummary(
      finishedAtMs: DateTime.now().millisecondsSinceEpoch,
      isRestoreAll: restoreAll,
      isAutomatic: isAutomatic,
      error: error,
    );
    if (!_platform.isSupported) {
      return refused("This device cannot move files in the media library");
    }
    if (!restoreAll && !isEnabled) {
      return refused("The sort is off");
    }
    if (!await _platform.waitUntilForeground()) {
      return refused("The app is not in the foreground");
    }
    if (!await _platform.hasFullAccess()) {
      return refused("The app does not have access to all photos");
    }

    progress.value = PersonFolderProgress(
      PersonFolderPhase.preparing,
      isRestore: restoreAll,
    );
    final plan = await _plan(
      restoreAll: restoreAll,
      failedMoves: isAutomatic ? _failedMoves : const {},
    );
    _logger.info(
      "Plan (${restoreAll ? "restore all" : "sort"}): "
      "${plan.count(PersonFolderMoveKind.sort)} sort, "
      "${plan.count(PersonFolderMoveKind.resort)} resort, "
      "${plan.count(PersonFolderMoveKind.restore)} restore, "
      "${plan.skips.length} skipped, ${plan.recordDrops.length} records "
      "dropped, ${stopwatch.elapsedMilliseconds}ms",
    );

    // Person folders that this run can empty. Their absolute paths are read
    // now, while a file is still in them.
    final foldersToCheck = await _personFoldersLeftBy(plan);

    final executor = PersonFolderExecutor(
      store: PersonFoldersDB.instance,
      mover: _platform,
      batchSize: kPersonFolderMoveBatchSize,
    );
    final execution = await executor.execute(
      plan,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      onProgress: (done, total) {
        progress.value = PersonFolderProgress(
          PersonFolderPhase.moving,
          done: done,
          total: total,
          isRestore: restoreAll,
        );
      },
      // The toggle can go off during a sort run.
      shouldStop: () => _stopRequested || (!restoreAll && !isEnabled),
    );
    _failedMoves.addAll(execution.failedMoves);

    if (execution.moved > 0) {
      progress.value = PersonFolderProgress(
        PersonFolderPhase.finishing,
        done: plan.moves.length - execution.notTried - execution.unverified,
        total: plan.moves.length,
        isRestore: restoreAll,
      );
      for (final folder in foldersToCheck) {
        try {
          if (await _platform.deleteFolderIfEmpty(folder)) {
            _logger.info("Removed an empty person folder");
          }
        } catch (e) {
          _logger.info("Could not remove an empty person folder", e);
        }
      }
      try {
        await _platform.refreshGallery();
      } catch (e, s) {
        _logger.warning("Gallery refresh after the moves failed", e, s);
      }
    }

    final skipped = <String, int>{};
    for (final skip in [...plan.skips, ...execution.skips]) {
      skipped[skip.reason.name] = (skipped[skip.reason.name] ?? 0) + 1;
    }
    final summary = PersonFolderRunSummary(
      finishedAtMs: DateTime.now().millisecondsSinceEpoch,
      isRestoreAll: restoreAll,
      isAutomatic: isAutomatic,
      moved: execution.sorted + execution.resorted,
      restored: execution.restored,
      skipped: skipped,
      recordsDropped: plan.recordDrops.length,
      notTried: execution.notTried + execution.unverified,
      stopped: execution.stopped,
      error: execution.error,
    );
    _logger.info(
      "Run done in ${stopwatch.elapsedMilliseconds}ms: "
      "${summary.moved} moved, ${summary.restored} restored, "
      "$skipped skipped, ${summary.notTried} not tried, "
      "error: ${summary.error}",
    );
    return summary;
  }

  /// Reads the state of the device and makes the plan.
  Future<PersonFolderPlan> _plan({
    required bool restoreAll,
    required Set<String> failedMoves,
  }) async {
    final db = PersonFoldersDB.instance;
    final records = await db.getRecords();
    if (restoreAll && records.isEmpty) {
      return PersonFolderPlanner.planRestoreAll(
        files: const [],
        records: const [],
      );
    }

    final persons = <PersonFolderPerson>[];
    final faces = <PersonFolderFace>[];
    final manual = <String, Set<String>>{};
    if (!restoreAll) {
      final namedPersonIds = <String>{};
      final manualMlFileIds = <String, List<int>>{};
      for (final entity in await PersonService.instance.getPersons()) {
        final person = PersonFolderPerson(
          id: entity.remoteID,
          name: entity.data.name,
          isIgnored: entity.data.isIgnored,
        );
        persons.add(person);
        if (!person.isNamed) continue;
        namedPersonIds.add(person.id);
        if (entity.data.manuallyAssigned.isNotEmpty) {
          manualMlFileIds[person.id] = entity.data.manuallyAssigned;
        }
      }
      final IMLDataDB<int> mlDb = MLDataDB.instance;
      final facesByFile = await _loadPersonFaces(mlDb, namedPersonIds);

      // The ML database keys a file by an int ID. This table (the source of
      // `EnteFile.mlFileID`) gives the MediaStore ID. It is read from the
      // database, not from a cache: an incomplete map would look like
      // "these images have no person" and would move them back.
      final localIdByMlId = await OfflineFilesDB.instance.getLocalIdsForIntIds({
        ...facesByFile.keys,
        for (final ids in manualMlFileIds.values) ...ids,
      });
      faces.addAll(await _toFaces(mlDb, facesByFile, localIdByMlId));
      for (final entry in manualMlFileIds.entries) {
        final localIds = <String>{
          for (final mlFileId in entry.value)
            if (localIdByMlId[mlFileId] != null) localIdByMlId[mlFileId]!,
        };
        if (localIds.isNotEmpty) manual[entry.key] = localIds;
      }
    }

    final files = <PersonFolderFile>[];
    final seen = <String>{};
    for (final image in await _platform.listImages()) {
      final folder = image.folder;
      if (folder == null || !seen.add(image.id)) continue;
      files.add(
        PersonFolderFile(
          id: image.id,
          folder: folder,
          name: image.name,
          isVideo: image.isVideo,
        ),
      );
    }

    // A record whose file is not in the list: look at that one file. The
    // list can have missed it, it can be in the trash, or its storage can be
    // away. The record is dropped only when the device confirms that the
    // file is gone. If not, a restore would not be possible later.
    final unavailable = <String>{};
    for (final record in records) {
      final id = record.localId;
      if (seen.contains(id)) continue;
      final image = await _platform.find(id);
      final folder = image?.folder;
      if (image != null && !image.isTrashed && folder != null) {
        seen.add(id);
        files.add(
          PersonFolderFile(
            id: id,
            folder: folder,
            name: image.name,
            isVideo: image.isVideo,
          ),
        );
      } else if (image != null || !await _platform.isConfirmedAbsent(id)) {
        unavailable.add(id);
      }
    }

    if (restoreAll) {
      return PersonFolderPlanner.planRestoreAll(
        files: files,
        records: records,
        unavailableFileIds: unavailable,
      );
    }

    // Files of named persons that the device list does not have (not an
    // image, not a video), so that the plan can report them. This has no
    // effect on the moves.
    final notListed = <String>{
      for (final face in faces) face.fileId,
      for (final ids in manual.values) ...ids,
    }.difference(seen);
    if (notListed.isNotEmpty) {
      for (final file in await SearchService.instance.getAllFilesForSearch()) {
        final localId = file.localID;
        if (localId == null ||
            file.fileType == FileType.image ||
            file.fileType == FileType.video ||
            !notListed.contains(localId) ||
            !seen.add(localId)) {
          continue;
        }
        files.add(
          PersonFolderFile(
            id: localId,
            folder: "",
            name: file.title ?? "",
            isImage: false,
          ),
        );
      }
    }

    return PersonFolderPlanner.plan(
      files: files,
      faces: faces,
      persons: persons,
      manualAssignments: manual,
      records: records,
      folderNames: await db.getFolderNames(),
      unavailableFileIds: unavailable,
      failedMoves: failedMoves,
    );
  }

  /// The face IDs of the named persons: ML file ID -> person ID -> face IDs.
  ///
  /// A face belongs to a person when its cluster is assigned to the person
  /// (the same rule as the People screen).
  Future<Map<int, Map<String, List<String>>>> _loadPersonFaces(
    IMLDataDB<int> mlDb,
    Set<String> namedPersonIds,
  ) async {
    final byFile = <int, Map<String, List<String>>>{};
    if (namedPersonIds.isEmpty) return byFile;
    final personToClusters = await mlDb.getPersonToClusterIdToFaceIds();
    for (final entry in personToClusters.entries) {
      if (!namedPersonIds.contains(entry.key)) continue;
      for (final faceIds in entry.value.values) {
        for (final faceId in faceIds) {
          final mlFileId = tryGetFileIdFromFaceId(faceId);
          if (mlFileId == null) continue;
          byFile
              .putIfAbsent(mlFileId, () => {})
              .putIfAbsent(entry.key, () => [])
              .add(faceId);
        }
      }
    }
    return byFile;
  }

  /// Makes planner faces from [facesByFile].
  ///
  /// The face boxes are read only for images with two or more named persons.
  /// For the other images the box has no effect on the result.
  Future<List<PersonFolderFace>> _toFaces(
    IMLDataDB<int> mlDb,
    Map<int, Map<String, List<String>>> facesByFile,
    Map<int, String> localIdByMlId,
  ) async {
    final contested = [
      for (final entry in facesByFile.entries)
        if (entry.value.length > 1 && localIdByMlId.containsKey(entry.key))
          entry.key,
    ];
    final boxes = <String, ({double area, double score})>{};
    void addBoxes(List<FaceWithoutEmbedding>? faces) {
      for (final face in faces ?? const <FaceWithoutEmbedding>[]) {
        final box = face.detection.box;
        boxes[face.faceID] = (area: box.width * box.height, score: face.score);
      }
    }

    if (contested.length > _maxFaceBoxQueries) {
      final all = await mlDb.getFileIDsToFacesWithoutEmbedding();
      for (final mlFileId in contested) {
        addBoxes(all[mlFileId]);
      }
    } else {
      for (final mlFileId in contested) {
        addBoxes(await mlDb.getFacesForGivenFileID(mlFileId));
      }
    }

    final faces = <PersonFolderFace>[];
    for (final entry in facesByFile.entries) {
      final localId = localIdByMlId[entry.key];
      if (localId == null) continue;
      if (entry.value.length == 1) {
        faces.add(
          PersonFolderFace(fileId: localId, personId: entry.value.keys.first),
        );
        continue;
      }
      for (final personFaces in entry.value.entries) {
        for (final faceId in personFaces.value) {
          final box = boxes[faceId];
          faces.add(
            PersonFolderFace(
              fileId: localId,
              personId: personFaces.key,
              area: box?.area ?? 0,
              score: box?.score ?? 0,
            ),
          );
        }
      }
    }
    return faces;
  }

  /// Absolute paths of the person folders out of which [plan] moves a file,
  /// then of their parent (the people root).
  Future<List<String>> _personFoldersLeftBy(PersonFolderPlan plan) async {
    final sampleFileByFolder = <String, String>{};
    for (final move in plan.moves) {
      if (move.kind == PersonFolderMoveKind.sort) continue;
      if (!isInPersonFoldersRoot(move.fromFolder)) continue;
      sampleFileByFolder.putIfAbsent(
        personFolderKey(move.fromFolder),
        () => move.fileId,
      );
    }
    final folders = <String>{};
    final parents = <String>{};
    for (final fileId in sampleFileByFolder.values) {
      try {
        final folder = await _platform.absoluteFolderOf(fileId);
        if (folder == null) continue;
        folders.add(folder);
        parents.add(Directory(folder).parent.path);
      } catch (e) {
        _logger.info("Could not read the path of a person folder", e);
      }
    }
    return [...folders, ...parents.difference(folders)];
  }

  PersonFolderRunSummary? _readLastRun() {
    final encoded = _prefs?.getString(_lastRunKey);
    if (encoded == null) return null;
    try {
      return PersonFolderRunSummary.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
    } catch (e) {
      _logger.warning("Could not read the last run summary", e);
      return null;
    }
  }
}

/// [PersonFolderPlatform] on top of photo_manager and the local sync.
class _PhotoManagerPlatform implements PersonFolderPlatform {
  static const int _pageSize = 2000;

  /// A request that has no answer after this time is taken as failed. The
  /// time is long, because Android can show a prompt.
  static const Duration _requestTimeout = Duration(minutes: 3);

  static final Logger _logger = Logger("PersonFolderPlatform");

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<bool> canMoveWithoutPrompt() async {
    if (!Platform.isAndroid) return false;
    try {
      return await PhotoManager.canManageMedia();
    } catch (e) {
      _logger.warning("canManageMedia failed", e);
      return false;
    }
  }

  @override
  Future<bool> hasFullAccess() async {
    try {
      final state = await PhotoManager.getPermissionState(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.common,
            mediaLocation: true,
          ),
        ),
      );
      return state == PermissionState.authorized;
    } catch (e) {
      _logger.warning("Could not read the photo permission", e);
      return false;
    }
  }

  @override
  Future<bool> isConfirmedAbsent(String id) async {
    try {
      // With partial access MediaStore hides files, so "not found" proves
      // nothing.
      if (!await hasFullAccess()) return false;
      // Null on Android 11 and earlier: not confirmed.
      return await LocalMediaClient.instance.assetExists(id) == false;
    } catch (e) {
      _logger.warning("Could not check if a file exists", e);
      return false;
    }
  }

  @override
  Future<bool> waitUntilForeground() async {
    // Each move request starts a system activity for a moment, so the state
    // can be "inactive" between two requests.
    for (var attempt = 0; attempt < 20; attempt++) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == AppLifecycleState.resumed) return true;
      // No state: an isolate without a UI, or a very early call.
      if (state == null) return AppLifecycleService.instance.isForeground;
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  @override
  Future<List<PersonFolderDeviceImage>> listImages() async {
    final filter = FilterOptionGroup(
      imageOption: const FilterOption(
        needTitle: true,
        sizeConstraint: SizeConstraint(ignoreSize: true),
      ),
      videoOption: const FilterOption(
        needTitle: true,
        sizeConstraint: SizeConstraint(ignoreSize: true),
        durationConstraint: DurationConstraint(
          max: Duration(days: 365),
          allowNullable: true,
        ),
      ),
      createTimeCond: DateTimeCond.def().copyWith(ignore: true),
    );
    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      onlyAll: true,
      type: RequestType.common,
      filterOption: filter,
    );
    final images = <PersonFolderDeviceImage>[];
    for (final path in paths) {
      if (!path.isAll) continue;
      var page = 0;
      while (true) {
        final assets = await path.getAssetListPaged(
          page: page,
          size: _pageSize,
        );
        for (final asset in assets) {
          final image = _imageOf(asset);
          if (image != null && !image.isTrashed) images.add(image);
        }
        if (assets.length < _pageSize) break;
        page++;
      }
    }
    return images;
  }

  @override
  Future<PersonFolderDeviceImage?> find(String id) async {
    final asset = await AssetEntity.fromId(id);
    return asset == null ? null : _imageOf(asset);
  }

  PersonFolderDeviceImage? _imageOf(AssetEntity asset) {
    if (asset.type != AssetType.image && asset.type != AssetType.video) {
      return null;
    }
    final relativePath = asset.relativePath;
    return PersonFolderDeviceImage(
      id: asset.id,
      folder: relativePath == null
          ? null
          : normalizePersonFolderPath(relativePath),
      name: asset.title ?? "",
      isTrashed: asset.isTrashed,
      isVideo: asset.type == AssetType.video,
    );
  }

  @override
  Future<Map<String, PersonFolderMoveOutcome>> move(
    List<PersonFolderMove> batch,
  ) async {
    final outcomes = <String, PersonFolderMoveOutcome>{};
    // One plugin request moves files to one folder.
    final byTarget = <String, List<PersonFolderMove>>{};
    for (final move in batch) {
      byTarget
          .putIfAbsent(normalizePersonFolderPath(move.toFolder), () => [])
          .add(move);
    }
    String? interruption;
    for (final entry in byTarget.entries) {
      final target = entry.key;
      if (target.isEmpty) continue;
      interruption ??= await waitUntilForeground()
          ? null
          : "The app is not in the foreground";
      if (interruption != null) {
        // No request for the other files of the batch.
        for (final move in entry.value) {
          outcomes[move.fileId] = PersonFolderMoveOutcome.notTried(
            interruption,
          );
        }
        continue;
      }

      // Look at each file immediately before the request. The plan can be
      // old, and the plugin refuses a request that has a missing file.
      final ready = <PersonFolderMove>[];
      for (final move in entry.value) {
        final image = await find(move.fileId);
        if (image == null) {
          // No request is sent for this file, so it does not move. Its
          // record goes away only when the device confirms the file is gone.
          outcomes[move.fileId] = await isConfirmedAbsent(move.fileId)
              ? const PersonFolderMoveOutcome.missing()
              : const PersonFolderMoveOutcome.notMoved("not readable now");
        } else if (image.isTrashed || image.folder == null) {
          outcomes[move.fileId] = const PersonFolderMoveOutcome.notMoved(
            "in the trash",
          );
        } else if (personFolderKey(image.folder) ==
            personFolderKey(move.fromFolder)) {
          ready.add(move);
        } else if (personFolderKey(image.folder) == personFolderKey(target)) {
          outcomes[move.fileId] = PersonFolderMoveOutcome.moved(image.folder!);
        } else {
          outcomes[move.fileId] = const PersonFolderMoveOutcome.notMoved(
            "not in the expected folder",
          );
        }
      }
      if (ready.isEmpty) continue;

      String? requestError;
      var timedOut = false;
      try {
        final accepted = await PhotoManager.editor.android
            .moveAssetsToPath(
              entities: [
                for (final move in ready)
                  AssetEntity(id: move.fileId, typeInt: 1, width: 0, height: 0),
              ],
              targetPath: "$target/",
            )
            .timeout(_requestTimeout);
        if (!accepted) requestError = "Android refused the request";
      } on TimeoutException {
        timedOut = true;
        requestError = "No answer from Android";
      } catch (e) {
        requestError = "$e";
      }
      if (requestError != null) {
        _logger.warning("Move request to a person folder: $requestError");
      }

      // The result of the request says little (true when one file moved).
      // Read where each file is now.
      for (final move in ready) {
        final image = await find(move.fileId);
        final folder = image?.folder;
        if (image == null || folder == null) {
          // The file can be in the target folder now. Without a proof that
          // it is gone, the pending record must stay.
          outcomes[move.fileId] =
              image == null && await isConfirmedAbsent(move.fileId)
              ? const PersonFolderMoveOutcome.missing()
              : const PersonFolderMoveOutcome.unknown(
                  "The device did not confirm where a file is",
                );
        } else if (personFolderKey(folder) ==
            personFolderKey(move.fromFolder)) {
          outcomes[move.fileId] = PersonFolderMoveOutcome.notMoved(
            requestError,
          );
        } else {
          outcomes[move.fileId] = PersonFolderMoveOutcome.moved(folder);
        }
      }
      if (timedOut) {
        // The plugin can still hold the request. Do not send a new one.
        interruption = "No answer from Android to a move request";
      }
    }
    return outcomes;
  }

  @override
  Future<String?> absoluteFolderOf(String id) async {
    final asset = await AssetEntity.fromId(id);
    final relativePath = asset?.relativePath;
    if (asset == null || relativePath == null) return null;
    final file = await asset.originFile;
    if (file == null) return null;
    final folder = file.parent.path;
    // On old Android versions the plugin can return a copy in its cache.
    final expectedEnd = "/${personFolderKey(relativePath)}";
    return folder.toLowerCase().endsWith(expectedEnd) ? folder : null;
  }

  @override
  Future<bool> deleteFolderIfEmpty(String absolutePath) async {
    final root = "/${personFolderKey(kPersonFoldersRoot)}";
    final key = absolutePath.toLowerCase();
    if (!key.endsWith(root) && !key.contains("$root/")) return false;
    final directory = Directory(absolutePath);
    try {
      if (!await directory.exists()) return false;
      // Not recursive: the delete fails when the directory has an entry.
      await directory.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<void> refreshGallery() async {
    // The same full comparison that upstream uses to repair the device
    // folder mappings: it adds the files to their new device folder, removes
    // them from the old one, updates the folder counts and covers, and fires
    // the gallery events.
    await LocalSyncService.instance.syncAll();
  }
}

// Offline fork: rules of the "Sort photos into person folders" tool.
//
// This file is pure Dart. It has no Flutter import and no plugin import, so
// the unit tests run it without a device. It holds:
//
// * the data model (files, faces, persons, move records, folder names),
// * [PersonFolderPlanner], which compares "where each image is" with "where
//   it must be" and returns the moves, and
// * [PersonFolderExecutor], which applies a plan in batches and keeps the
//   move records correct when a move fails or the app stops in the middle.
//
// The device side (MediaStore, databases) is in person_folder_service.dart.
//
// Rules (owner decisions):
//
// * Only images move. Only named persons (not ignored, not hidden) count.
// * The target is `Pictures/People/<person name>`.
// * An image with two or more named persons goes to the person with the
//   largest face box. Ties: higher face score, then smaller person ID.
// * A manual assignment (no face) wins only when no detected face of a named
//   person is in the image.
// * An image that has no named person any more returns to its original
//   folder.
// * A file in `Pictures/People` that the tool did not put there stays there.
// * Android permits images only below `DCIM` and `Pictures` (see
//   [kPersonFolderSourceRoots]). An image from another folder (for example
//   `Download`) is still sorted (owner's decision), but it cannot go back to
//   that folder: its recorded "original" folder is a folder below `Pictures`
//   (see [restoreFolderForPersonFolderSource]).
// * A file whose name is already in the target folder is skipped.

/// Parent of all person folders, relative to the root of the storage volume.
const String kPersonFoldersRoot = "Pictures/People";

/// Top-level folders in which Android permits image files (MediaStore image
/// collection). An image moves out of a folder only when the folder is below
/// one of these, because only then can Android put the image back.
const List<String> kPersonFolderSourceRoots = ["DCIM", "Pictures"];

/// Folder name for a person whose name has no usable character.
const String kPersonFolderFallbackName = "Person";

/// Longest folder name (UTF-16 code units) before the "(2)" suffix.
const int kPersonFolderMaxNameLength = 80;

/// Removes empty segments and the leading and trailing slash.
/// `"DCIM/Camera/"` becomes `"DCIM/Camera"`.
String normalizePersonFolderPath(String? path) {
  if (path == null) return "";
  return path.split("/").where((part) => part.isNotEmpty).join("/");
}

/// Key for folder comparison. Android shared storage ignores letter case.
String personFolderKey(String? path) =>
    normalizePersonFolderPath(path).toLowerCase();

/// True when [folder] is the people root or is below it.
bool isInPersonFoldersRoot(String? folder) {
  final key = personFolderKey(folder);
  final root = personFolderKey(kPersonFoldersRoot);
  return key == root || key.startsWith("$root/");
}

/// True when Android can put an image back into [folder].
bool isRestorablePersonFolderSource(String? folder) {
  final key = personFolderKey(folder);
  if (key.isEmpty) return false;
  final top = key.split("/").first;
  return kPersonFolderSourceRoots.any((root) => root.toLowerCase() == top);
}

/// Folder below `Pictures` for restored files whose source folder has no name
/// that can be reused (for example the root of the storage volume).
const String kPersonFolderRestoreFallback = "Pictures/Restored";

/// The folder a file returns to when it leaves its person folder.
///
/// For a source below `DCIM` or `Pictures` this is the source itself. Android
/// cannot put an image back into any other folder, so for those the file
/// returns to `Pictures/<last part of the source folder>`: `Download` becomes
/// `Pictures/Download`, and
/// `Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images` becomes
/// `Pictures/WhatsApp Images`.
String restoreFolderForPersonFolderSource(String? folder) {
  final normalized = normalizePersonFolderPath(folder);
  if (isRestorablePersonFolderSource(normalized)) return normalized;
  if (normalized.isEmpty) return kPersonFolderRestoreFallback;
  final last = normalized.split("/").last;
  // Never restore into the people root itself.
  if (last.toLowerCase() == "people") return kPersonFolderRestoreFallback;
  return "Pictures/$last";
}

/// A file on the device.
class PersonFolderFile {
  /// MediaStore ID (the app `localID`).
  final String id;

  /// Folder of the file, relative to the volume root. Not used when
  /// [isImage] is false.
  final String folder;

  /// File name with extension.
  final String name;

  final bool isImage;

  const PersonFolderFile({
    required this.id,
    required this.folder,
    required this.name,
    this.isImage = true,
  });
}

/// A detected face that belongs to a person.
class PersonFolderFace {
  final String fileId;
  final String personId;

  /// Area of the detection box. Only the order within one file matters.
  final double area;
  final double score;

  const PersonFolderFace({
    required this.fileId,
    required this.personId,
    this.area = 1,
    this.score = 1,
  });
}

class PersonFolderPerson {
  final String id;
  final String name;

  /// True for a hidden or ignored person.
  final bool isIgnored;

  const PersonFolderPerson({
    required this.id,
    required this.name,
    this.isIgnored = false,
  });

  bool get isNamed => !isIgnored && name.trim().isNotEmpty;
}

/// One file that the tool moved, and where the file came from.
class PersonFolderRecord {
  final String localId;

  /// Folder of the file before the first move. "Restore" moves it there.
  final String originalFolder;
  final String originalName;

  /// Folder where the tool put the file (or is putting it, see
  /// [previousFolder]).
  final String personFolder;

  /// Not null only while a move is in flight: the folder of the file before
  /// that move. The executor writes it before the move request and clears it
  /// after the move is verified. A record that still has it after a crash is
  /// resolved by the location of the file.
  final String? previousFolder;

  final String personId;
  final int movedAtMs;

  const PersonFolderRecord({
    required this.localId,
    required this.originalFolder,
    required this.originalName,
    required this.personFolder,
    required this.personId,
    required this.movedAtMs,
    this.previousFolder,
  });

  bool get isPending => previousFolder != null;

  PersonFolderRecord confirmedAt(
    String folder, {
    String? personId,
    int? movedAtMs,
  }) {
    return PersonFolderRecord(
      localId: localId,
      originalFolder: originalFolder,
      originalName: originalName,
      personFolder: folder,
      personId: personId ?? this.personId,
      movedAtMs: movedAtMs ?? this.movedAtMs,
    );
  }

  PersonFolderRecord pendingMove({
    required String from,
    required String to,
    required String personId,
  }) {
    return PersonFolderRecord(
      localId: localId,
      originalFolder: originalFolder,
      originalName: originalName,
      personFolder: to,
      previousFolder: from,
      personId: personId,
      movedAtMs: movedAtMs,
    );
  }

  @override
  String toString() =>
      "PersonFolderRecord($localId, original: $originalFolder, "
      "person: $personFolder, previous: $previousFolder, id: $personId)";
}

/// The folder name of one person. Persisted, so that the name is the same in
/// each run.
class PersonFolderName {
  final String personId;

  /// The sanitised person name from which [folderName] was made.
  final String baseName;

  /// Name of the folder below [kPersonFoldersRoot]. It is [baseName], or
  /// [baseName] plus " (2)", " (3)" for persons with the same name.
  final String folderName;

  const PersonFolderName({
    required this.personId,
    required this.baseName,
    required this.folderName,
  });

  String get folder => "$kPersonFoldersRoot/$folderName";

  @override
  bool operator ==(Object other) =>
      other is PersonFolderName &&
      other.personId == personId &&
      other.baseName == baseName &&
      other.folderName == folderName;

  @override
  int get hashCode => Object.hash(personId, baseName, folderName);
}

enum PersonFolderMoveKind {
  /// From the original folder into a person folder.
  sort,

  /// From one person folder into a different person folder (rename, merge,
  /// a different person now has the largest face).
  resort,

  /// From a person folder back to the original folder.
  restore,
}

class PersonFolderMove {
  final String fileId;
  final String fileName;
  final String fromFolder;
  final String toFolder;
  final PersonFolderMoveKind kind;

  /// Null for [PersonFolderMoveKind.restore].
  final String? personId;

  /// The folder to which a later restore must go.
  final String originalFolder;

  /// The record of the file. Null for [PersonFolderMoveKind.sort].
  final PersonFolderRecord? record;

  const PersonFolderMove({
    required this.fileId,
    required this.fileName,
    required this.fromFolder,
    required this.toFolder,
    required this.kind,
    required this.originalFolder,
    this.personId,
    this.record,
  });

  @override
  String toString() =>
      "PersonFolderMove(${kind.name} $fileId: $fromFolder -> $toFolder)";
}

enum PersonFolderSkipReason {
  /// A video (or other non-image) of a named person.
  notImage,

  /// The file is in `Pictures/People`, but the tool did not put it there.
  foreignInPeopleFolder,

  /// The file is outside `DCIM` and `Pictures`. Android cannot put an image
  /// back into such a folder.
  sourceNotRestorable,

  /// A different file with the same name is in the target folder.
  nameCollision,

  /// The tool moved the file, then something else moved it again.
  movedExternally,

  /// The tool moved the file, and the file is not readable now: it is in
  /// the device trash, or the device does not confirm that it is gone. The
  /// record stays.
  unavailable,

  /// A move of this file to the same target failed earlier in this session.
  failedBefore,

  /// Android did not move the file.
  moveRefused,

  /// The file went away during the run.
  missing,
}

class PersonFolderSkip {
  final String fileId;
  final PersonFolderSkipReason reason;

  const PersonFolderSkip(this.fileId, this.reason);

  @override
  String toString() => "PersonFolderSkip($fileId, ${reason.name})";
}

enum PersonFolderRecordDropReason {
  /// The file is not on the device any more.
  fileMissing,

  /// The file is not in the folder where the tool put it.
  movedExternally,

  /// The app stopped before the first move of the file took place.
  moveNotDone,
}

class PersonFolderRecordDrop {
  final String localId;
  final PersonFolderRecordDropReason reason;

  const PersonFolderRecordDrop(this.localId, this.reason);

  @override
  String toString() => "PersonFolderRecordDrop($localId, ${reason.name})";
}

class PersonFolderPlan {
  /// Sorted by target folder, then by file ID.
  final List<PersonFolderMove> moves;
  final List<PersonFolderSkip> skips;

  /// Records to delete.
  final List<PersonFolderRecordDrop> recordDrops;

  /// Records to write without a move (a pending move that is now resolved, a
  /// different person ID for a file that is already in the right folder).
  final List<PersonFolderRecord> recordUpdates;

  /// The complete folder name table after this plan. Null in a "restore all"
  /// plan, which does not change the table.
  final List<PersonFolderName>? folderNames;

  const PersonFolderPlan({
    required this.moves,
    required this.skips,
    required this.recordDrops,
    required this.recordUpdates,
    required this.folderNames,
  });

  int count(PersonFolderMoveKind kind) =>
      moves.where((move) => move.kind == kind).length;

  Map<PersonFolderSkipReason, int> get skipCounts {
    final counts = <PersonFolderSkipReason, int>{};
    for (final skip in skips) {
      counts[skip.reason] = (counts[skip.reason] ?? 0) + 1;
    }
    return counts;
  }

  bool get isEmpty =>
      moves.isEmpty && recordDrops.isEmpty && recordUpdates.isEmpty;
}

/// Key of a (file, target folder) pair for the "failed before" list.
String personFolderMoveKey(String fileId, String toFolder) =>
    "$fileId|${personFolderKey(toFolder)}";

class PersonFolderPlanner {
  const PersonFolderPlanner._();

  /// Makes a folder name from a person name.
  ///
  /// * `/ \ : * ? " < > |` and control characters become a space.
  /// * Direction marks and unpaired surrogates are removed. Letters of all
  ///   scripts, joiners and emoji stay.
  /// * Spaces are collapsed. Leading dots (a hidden folder) and trailing dots
  ///   and spaces (not valid on FAT) are removed.
  /// * The name is cut at [kPersonFolderMaxNameLength] code units.
  /// * An empty result becomes [kPersonFolderFallbackName].
  static String sanitizeFolderName(String name) {
    final buffer = StringBuffer();
    for (final rune in name.runes) {
      if (rune >= 0xD800 && rune <= 0xDFFF) continue; // unpaired surrogate
      if (_removedRunes.contains(rune) ||
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069)) {
        continue;
      }
      if (rune < 0x20 ||
          (rune >= 0x7F && rune <= 0x9F) ||
          _forbiddenRunes.contains(rune) ||
          _spaceRunes.contains(rune) ||
          (rune >= 0x2000 && rune <= 0x200A)) {
        buffer.write(" ");
        continue;
      }
      buffer.writeCharCode(rune);
    }
    var result = _trimFolderName(buffer.toString());
    if (result.length > kPersonFolderMaxNameLength) {
      var end = kPersonFolderMaxNameLength;
      final last = result.codeUnitAt(end - 1);
      // Do not cut a surrogate pair in two.
      if (last >= 0xD800 && last <= 0xDBFF) end--;
      result = _trimFolderName(result.substring(0, end));
    }
    return result.isEmpty ? kPersonFolderFallbackName : result;
  }

  static const Set<int> _forbiddenRunes = {
    0x22, // "
    0x2A, // *
    0x2F, // /
    0x3A, // :
    0x3C, // <
    0x3E, // >
    0x3F, // ?
    0x5C, // \
    0x7C, // |
  };

  static const Set<int> _spaceRunes = {
    0xA0,
    0x1680,
    0x2028,
    0x2029,
    0x202F,
    0x205F,
    0x3000,
  };

  static const Set<int> _removedRunes = {
    0x200E, // left-to-right mark
    0x200F, // right-to-left mark
    0xFEFF, // byte order mark
    0xFFFC,
    0xFFFD,
    0xFFFE,
    0xFFFF,
  };

  static String _trimFolderName(String value) {
    return value
        .replaceAll(RegExp(r" {2,}"), " ")
        .replaceFirst(RegExp(r"^[ .]+"), "")
        .replaceFirst(RegExp(r"[ .]+$"), "");
  }

  /// Gives each named person a folder name.
  ///
  /// A person keeps the name in [existing] while the sanitised person name is
  /// the same. A new or renamed person gets the sanitised name, or the first
  /// free "name (2)", "name (3)" when a different person has that folder.
  /// Persons are handled in the order of their IDs, so the result does not
  /// depend on the order of the input. Folder names are compared without
  /// letter case.
  static List<PersonFolderName> assignFolderNames({
    required Iterable<PersonFolderPerson> persons,
    Iterable<PersonFolderName> existing = const [],
  }) {
    final named = <String, PersonFolderPerson>{};
    for (final person in persons) {
      if (person.isNamed) named.putIfAbsent(person.id, () => person);
    }
    final ids = named.keys.toList()..sort();
    final existingById = {for (final entry in existing) entry.personId: entry};

    final used = <String>{};
    final result = <String, PersonFolderName>{};
    final baseNames = <String, String>{};
    for (final id in ids) {
      final base = baseNames[id] = sanitizeFolderName(named[id]!.name);
      final entry = existingById[id];
      if (entry != null &&
          entry.baseName == base &&
          entry.folderName.isNotEmpty &&
          used.add(entry.folderName.toLowerCase())) {
        result[id] = entry;
      }
    }
    for (final id in ids) {
      if (result.containsKey(id)) continue;
      final base = baseNames[id]!;
      var candidate = base;
      var number = 1;
      while (!used.add(candidate.toLowerCase())) {
        number++;
        candidate = "$base ($number)";
      }
      result[id] = PersonFolderName(
        personId: id,
        baseName: base,
        folderName: candidate,
      );
    }
    return [for (final id in ids) result[id]!];
  }

  /// Compares the state of the device with the wanted state.
  ///
  /// * [files]: all images on the device (also those without a person: their
  ///   names are necessary to find name collisions), plus the non-image files
  ///   of named persons with `isImage: false`.
  /// * [faces]: detected faces of persons. Faces of persons that are not in
  ///   [persons], or are not named, are ignored.
  /// * [manualAssignments]: person ID to the IDs of the files that the user
  ///   assigned to the person by hand.
  /// * [unavailableFileIds]: files of [records] that are not in [files], but
  ///   are not proven to be gone (in the device trash, storage not mounted).
  ///   Their records stay.
  /// * [failedMoves]: [personFolderMoveKey] of moves that must not be tried
  ///   again.
  ///
  /// The plan is idempotent: when all moves of a plan are done, the next plan
  /// has no moves.
  static PersonFolderPlan plan({
    required Iterable<PersonFolderFile> files,
    required Iterable<PersonFolderFace> faces,
    required Iterable<PersonFolderPerson> persons,
    Map<String, Iterable<String>> manualAssignments = const {},
    Iterable<PersonFolderRecord> records = const [],
    Iterable<PersonFolderName> folderNames = const [],
    Set<String> unavailableFileIds = const {},
    Set<String> failedMoves = const {},
  }) {
    final names = assignFolderNames(persons: persons, existing: folderNames);
    final folderOfPerson = {
      for (final name in names) name.personId: name.folder,
    };

    // The person of each file.
    final best = <String, _Candidate>{};
    void offer(String fileId, _Candidate candidate) {
      final current = best[fileId];
      if (current == null || candidate.isBetterThan(current)) {
        best[fileId] = candidate;
      }
    }

    for (final face in faces) {
      if (!folderOfPerson.containsKey(face.personId)) continue;
      offer(
        face.fileId,
        _Candidate(face.personId, face.area, face.score, isManual: false),
      );
    }
    for (final entry in manualAssignments.entries) {
      if (!folderOfPerson.containsKey(entry.key)) continue;
      for (final fileId in entry.value) {
        offer(fileId, _Candidate(entry.key, 0, 0, isManual: true));
      }
    }

    final state = _DeviceState(files);
    final recordsById = {for (final record in records) record.localId: record};
    final out = _PlanBuilder();

    final ids = <String>{...recordsById.keys, ...best.keys}.toList()..sort();
    for (final id in ids) {
      final file = state.filesById[id];
      var record = recordsById[id];
      final candidate = best[id];

      if (file == null) {
        if (record != null) {
          if (unavailableFileIds.contains(id)) {
            out.skip(id, PersonFolderSkipReason.unavailable);
          } else {
            out.drop(id, PersonFolderRecordDropReason.fileMissing);
          }
        }
        continue;
      }
      if (!file.isImage) {
        if (candidate != null) out.skip(id, PersonFolderSkipReason.notImage);
        continue;
      }

      final current = personFolderKey(file.folder);
      if (record != null) {
        final resolved = _resolveRecord(record, current, out);
        if (resolved == null && !_wasMoveNotDone(record, current)) {
          // Something else moved the file. Leave it alone in this run.
          out.skip(id, PersonFolderSkipReason.movedExternally);
          continue;
        }
        record = resolved;
      }

      final personId = candidate?.personId;
      if (record != null) {
        // The file is where the tool put it.
        if (personId == null) {
          out.move(
            state,
            failedMoves,
            PersonFolderMove(
              fileId: id,
              fileName: file.name,
              fromFolder: normalizePersonFolderPath(file.folder),
              toFolder: record.originalFolder,
              kind: PersonFolderMoveKind.restore,
              originalFolder: record.originalFolder,
              record: record,
            ),
          );
          continue;
        }
        final target = folderOfPerson[personId]!;
        if (personFolderKey(target) == current) {
          if (record.personId != personId) {
            out.update(
              record.confirmedAt(record.personFolder, personId: personId),
            );
          }
          continue;
        }
        out.move(
          state,
          failedMoves,
          PersonFolderMove(
            fileId: id,
            fileName: file.name,
            fromFolder: normalizePersonFolderPath(file.folder),
            toFolder: target,
            kind: PersonFolderMoveKind.resort,
            personId: personId,
            originalFolder: record.originalFolder,
            record: record,
          ),
        );
        continue;
      }

      // No record: the tool did not move this file (or not any more).
      if (personId == null) continue;
      final target = folderOfPerson[personId]!;
      if (personFolderKey(target) == current) continue;
      if (isInPersonFoldersRoot(file.folder)) {
        out.skip(id, PersonFolderSkipReason.foreignInPeopleFolder);
        continue;
      }
      final from = normalizePersonFolderPath(file.folder);
      out.move(
        state,
        failedMoves,
        PersonFolderMove(
          fileId: id,
          fileName: file.name,
          fromFolder: from,
          toFolder: target,
          kind: PersonFolderMoveKind.sort,
          personId: personId,
          originalFolder: restoreFolderForPersonFolderSource(from),
        ),
      );
    }
    return out.build(folderNames: names);
  }

  /// A plan that moves each recorded file back to its original folder.
  ///
  /// Persons and faces have no effect. A record whose file is missing, or is
  /// not in the folder where the tool put it, is dropped.
  static PersonFolderPlan planRestoreAll({
    required Iterable<PersonFolderFile> files,
    required Iterable<PersonFolderRecord> records,
    Set<String> unavailableFileIds = const {},
  }) {
    final state = _DeviceState(files);
    final out = _PlanBuilder();
    final sorted = records.toList()
      ..sort((a, b) => a.localId.compareTo(b.localId));
    for (final original in sorted) {
      final id = original.localId;
      final file = state.filesById[id];
      if (file == null) {
        if (unavailableFileIds.contains(id)) {
          out.skip(id, PersonFolderSkipReason.unavailable);
        } else {
          out.drop(id, PersonFolderRecordDropReason.fileMissing);
        }
        continue;
      }
      final current = personFolderKey(file.folder);
      final record = _resolveRecord(original, current, out);
      if (record == null) {
        // The file is in its original folder or in a folder that the user
        // chose. There is nothing to restore.
        continue;
      }
      out.move(
        state,
        const {},
        PersonFolderMove(
          fileId: id,
          fileName: file.name,
          fromFolder: normalizePersonFolderPath(file.folder),
          toFolder: record.originalFolder,
          kind: PersonFolderMoveKind.restore,
          originalFolder: record.originalFolder,
          record: record,
        ),
      );
    }
    return out.build(folderNames: null);
  }

  /// Makes [record] agree with the folder of its file.
  ///
  /// Returns the record that is true now, or null when the record is dropped
  /// (the drop is added to [out]).
  static PersonFolderRecord? _resolveRecord(
    PersonFolderRecord record,
    String currentKey,
    _PlanBuilder out,
  ) {
    if (currentKey == personFolderKey(record.personFolder)) {
      if (!record.isPending) return record;
      // The move took place, but the app stopped before it wrote that down.
      final confirmed = record.confirmedAt(record.personFolder);
      out.update(confirmed);
      return confirmed;
    }
    final previous = record.previousFolder;
    if (previous != null && currentKey == personFolderKey(previous)) {
      if (_wasMoveNotDone(record, currentKey)) {
        out.drop(record.localId, PersonFolderRecordDropReason.moveNotDone);
        return null;
      }
      // A move between two person folders did not take place. The file is
      // still in the first person folder, and the original folder is known.
      final reverted = record.confirmedAt(previous);
      out.update(reverted);
      return reverted;
    }
    out.drop(record.localId, PersonFolderRecordDropReason.movedExternally);
    return null;
  }

  /// True when [record] is a first move that never took place: the file is
  /// still in its original folder.
  static bool _wasMoveNotDone(PersonFolderRecord record, String currentKey) {
    final previous = record.previousFolder;
    return previous != null &&
        currentKey == personFolderKey(previous) &&
        currentKey == personFolderKey(record.originalFolder) &&
        currentKey != personFolderKey(record.personFolder);
  }
}

class _Candidate {
  final String personId;
  final double area;
  final double score;
  final bool isManual;

  const _Candidate(
    this.personId,
    this.area,
    this.score, {
    required this.isManual,
  });

  bool isBetterThan(_Candidate other) {
    if (isManual != other.isManual) return !isManual;
    if (area != other.area) return area > other.area;
    if (score != other.score) return score > other.score;
    return personId.compareTo(other.personId) < 0;
  }
}

class _DeviceState {
  final Map<String, PersonFolderFile> filesById = {};

  /// Folder key to the lower-case names of the image files in the folder.
  final Map<String, Set<String>> _names = {};

  _DeviceState(Iterable<PersonFolderFile> files) {
    for (final file in files) {
      if (filesById.containsKey(file.id)) continue;
      filesById[file.id] = file;
      if (file.isImage) reserve(file.folder, file.name);
    }
  }

  bool isNameTaken(String folder, String name) =>
      _names[personFolderKey(folder)]?.contains(name.toLowerCase()) ?? false;

  void reserve(String folder, String name) {
    _names
        .putIfAbsent(personFolderKey(folder), () => <String>{})
        .add(name.toLowerCase());
  }
}

class _PlanBuilder {
  final List<PersonFolderMove> _moves = [];
  final List<PersonFolderSkip> _skips = [];
  final List<PersonFolderRecordDrop> _drops = [];
  final Map<String, PersonFolderRecord> _updates = {};

  void skip(String id, PersonFolderSkipReason reason) =>
      _skips.add(PersonFolderSkip(id, reason));

  void drop(String id, PersonFolderRecordDropReason reason) {
    _updates.remove(id);
    _drops.add(PersonFolderRecordDrop(id, reason));
  }

  void update(PersonFolderRecord record) => _updates[record.localId] = record;

  /// Adds [move], or a skip when the move is not safe.
  void move(
    _DeviceState state,
    Set<String> failedMoves,
    PersonFolderMove move,
  ) {
    if (state.isNameTaken(move.toFolder, move.fileName)) {
      skip(move.fileId, PersonFolderSkipReason.nameCollision);
      return;
    }
    if (failedMoves.contains(personFolderMoveKey(move.fileId, move.toFolder))) {
      skip(move.fileId, PersonFolderSkipReason.failedBefore);
      return;
    }
    state.reserve(move.toFolder, move.fileName);
    _moves.add(move);
  }

  PersonFolderPlan build({required List<PersonFolderName>? folderNames}) {
    _moves.sort((a, b) {
      final byFolder = personFolderKey(
        a.toFolder,
      ).compareTo(personFolderKey(b.toFolder));
      return byFolder != 0 ? byFolder : a.fileId.compareTo(b.fileId);
    });
    return PersonFolderPlan(
      moves: _moves,
      skips: _skips,
      recordDrops: _drops,
      recordUpdates: _updates.values.toList(),
      folderNames: folderNames,
    );
  }
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

/// Storage of the move records and of the folder names.
abstract class PersonFolderStore {
  /// Writes [upserts] and removes the records of [deletes] in one
  /// transaction.
  Future<void> applyRecordChanges({
    Iterable<PersonFolderRecord> upserts = const [],
    Iterable<String> deletes = const [],
  });

  /// Replaces the folder name table.
  Future<void> saveFolderNames(List<PersonFolderName> names);
}

enum PersonFolderMoveStatus {
  /// The file is not in its source folder any more. `folder` is where it is.
  moved,

  /// The file is still in its source folder.
  notMoved,

  /// The file is not on the device.
  missing,

  /// The mover did not send a request for the file (the app left the
  /// foreground, or Android gave no answer to an earlier request). The run
  /// stops after the batch.
  notTried,

  /// A request was sent, but the device does not say where the file is now.
  /// The pending record stays as it is, and the next plan resolves it. The
  /// run stops after the batch.
  unknown,
}

class PersonFolderMoveOutcome {
  final PersonFolderMoveStatus status;

  /// The folder of the file after the request, when it is known.
  final String? folder;
  final String? detail;

  const PersonFolderMoveOutcome(this.status, {this.folder, this.detail});

  const PersonFolderMoveOutcome.moved(String this.folder)
    : status = PersonFolderMoveStatus.moved,
      detail = null;

  const PersonFolderMoveOutcome.notMoved([this.detail])
    : status = PersonFolderMoveStatus.notMoved,
      folder = null;

  const PersonFolderMoveOutcome.missing()
    : status = PersonFolderMoveStatus.missing,
      folder = null,
      detail = null;

  const PersonFolderMoveOutcome.notTried([this.detail])
    : status = PersonFolderMoveStatus.notTried,
      folder = null;

  const PersonFolderMoveOutcome.unknown([this.detail])
    : status = PersonFolderMoveStatus.unknown,
      folder = null;
}

/// Moves files on the device.
abstract class PersonFolderMover {
  /// Tries each move of [batch] and returns where each file is afterwards,
  /// by file ID. The answer must come from a look at the device after the
  /// request, not from the result of the request. A file without an entry
  /// counts as not tried.
  Future<Map<String, PersonFolderMoveOutcome>> move(
    List<PersonFolderMove> batch,
  );
}

class PersonFolderExecution {
  int sorted = 0;
  int resorted = 0;
  int restored = 0;

  /// Moves that did not take place, and files that went away.
  final List<PersonFolderSkip> skips = [];

  /// [personFolderMoveKey] of each move that must not be tried again in this
  /// session (not moved, or moved to a folder that is not the target).
  final Set<String> failedMoves = {};

  /// Planned moves for which no request was sent (stop request or abort).
  int notTried = 0;

  /// Moves with a request whose result the device did not confirm.
  int unverified = 0;

  bool stopped = false;

  /// Not null when the run was aborted.
  String? error;

  int get moved => sorted + resorted + restored;
}

/// Applies a [PersonFolderPlan].
///
/// The record protocol keeps "Restore all" correct at each point in time:
///
/// * First move of a file: the record is written before the request, with
///   `previousFolder` = the original folder. After the request the record is
///   confirmed (file moved) or deleted (file not moved).
/// * Move between person folders: the record is changed to the new folder
///   before the request, with `previousFolder` = the old person folder. After
///   the request it is confirmed or put back.
/// * Restore: the record is deleted only after the file is back.
///
/// When the app stops between the two writes, the next plan reads the pending
/// record and resolves it by the folder of the file.
class PersonFolderExecutor {
  final PersonFolderStore store;
  final PersonFolderMover mover;
  final int batchSize;

  /// The run is aborted after this number of batches in sequence in which no
  /// file moved. This stops a run that Android refuses as a whole (permission
  /// denied, app in the background).
  final int maxFailedBatchesInSequence;

  const PersonFolderExecutor({
    required this.store,
    required this.mover,
    this.batchSize = 50,
    this.maxFailedBatchesInSequence = 3,
  });

  Future<PersonFolderExecution> execute(
    PersonFolderPlan plan, {
    required int nowMs,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldStop,
  }) async {
    assert(batchSize > 0);
    final result = PersonFolderExecution();
    final names = plan.folderNames;
    if (names != null) await store.saveFolderNames(names);
    if (plan.recordUpdates.isNotEmpty || plan.recordDrops.isNotEmpty) {
      await store.applyRecordChanges(
        upserts: plan.recordUpdates,
        deletes: plan.recordDrops.map((drop) => drop.localId),
      );
    }

    final moves = plan.moves;
    final total = moves.length;
    var done = 0;
    var failedBatches = 0;
    onProgress?.call(0, total);
    while (done < total) {
      if (shouldStop?.call() ?? false) {
        result.stopped = true;
        break;
      }
      final end = done + batchSize > total ? total : done + batchSize;
      final batch = moves.sublist(done, end);

      final pending = <PersonFolderRecord>[
        for (final move in batch)
          if (move.kind != PersonFolderMoveKind.restore)
            _pendingRecord(move, nowMs),
      ];
      if (pending.isNotEmpty) {
        await store.applyRecordChanges(upserts: pending);
      }

      final Map<String, PersonFolderMoveOutcome> outcomes;
      try {
        outcomes = await mover.move(batch);
      } catch (e) {
        // The state of the files of this batch is not known. Their pending
        // records stay, and the next plan resolves them.
        result.error = "$e";
        break;
      }

      final upserts = <PersonFolderRecord>[];
      final deletes = <String>[];
      var movedInBatch = 0;
      String? interruption;
      for (final move in batch) {
        final outcome =
            outcomes[move.fileId] ?? const PersonFolderMoveOutcome.notTried();
        switch (outcome.status) {
          case PersonFolderMoveStatus.moved:
            movedInBatch++;
            final folder = normalizePersonFolderPath(
              outcome.folder ?? move.toFolder,
            );
            if (personFolderKey(folder) != personFolderKey(move.toFolder)) {
              result.failedMoves.add(
                personFolderMoveKey(move.fileId, move.toFolder),
              );
            }
            switch (move.kind) {
              case PersonFolderMoveKind.sort:
                result.sorted++;
                upserts.add(_pendingRecord(move, nowMs).confirmedAt(folder));
              case PersonFolderMoveKind.resort:
                result.resorted++;
                upserts.add(
                  move.record!.confirmedAt(
                    folder,
                    personId: move.personId,
                    movedAtMs: nowMs,
                  ),
                );
              case PersonFolderMoveKind.restore:
                result.restored++;
                deletes.add(move.fileId);
            }
          case PersonFolderMoveStatus.notMoved:
            result.skips.add(
              PersonFolderSkip(move.fileId, PersonFolderSkipReason.moveRefused),
            );
            result.failedMoves.add(
              personFolderMoveKey(move.fileId, move.toFolder),
            );
            switch (move.kind) {
              case PersonFolderMoveKind.sort:
                deletes.add(move.fileId);
              case PersonFolderMoveKind.resort:
                upserts.add(move.record!);
              case PersonFolderMoveKind.restore:
                break;
            }
          case PersonFolderMoveStatus.missing:
            result.skips.add(
              PersonFolderSkip(move.fileId, PersonFolderSkipReason.missing),
            );
            deletes.add(move.fileId);
          case PersonFolderMoveStatus.notTried:
            interruption ??= outcome.detail ?? "The run was interrupted";
            result.notTried++;
            // The file did not move: take back the pending record.
            switch (move.kind) {
              case PersonFolderMoveKind.sort:
                deletes.add(move.fileId);
              case PersonFolderMoveKind.resort:
                upserts.add(move.record!);
              case PersonFolderMoveKind.restore:
                break;
            }
          case PersonFolderMoveStatus.unknown:
            interruption ??=
                outcome.detail ?? "The device did not confirm a move";
            result.unverified++;
          // No record change. A pending record says where the file came
          // from and where it went, so the next plan can resolve it.
        }
      }
      if (upserts.isNotEmpty || deletes.isNotEmpty) {
        await store.applyRecordChanges(upserts: upserts, deletes: deletes);
      }
      done = end;
      onProgress?.call(done, total);
      if (interruption != null) {
        result.error = interruption;
        break;
      }

      failedBatches = movedInBatch == 0 ? failedBatches + 1 : 0;
      if (failedBatches >= maxFailedBatchesInSequence && done < total) {
        result.error = "Android did not move the files";
        break;
      }
    }
    result.notTried += total - done;
    return result;
  }

  static PersonFolderRecord _pendingRecord(PersonFolderMove move, int nowMs) {
    final record = move.record;
    if (record != null) {
      return record.pendingMove(
        from: move.fromFolder,
        to: move.toFolder,
        personId: move.personId ?? record.personId,
      );
    }
    return PersonFolderRecord(
      localId: move.fileId,
      originalFolder: move.originalFolder,
      originalName: move.fileName,
      personFolder: move.toFolder,
      previousFolder: move.fromFolder,
      personId: move.personId ?? "",
      movedAtMs: nowMs,
    );
  }
}

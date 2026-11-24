import "package:flutter_test/flutter_test.dart";
import "package:photos/services/person_folders/person_folder_planner.dart";

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

const _camera = "DCIM/Camera";

PersonFolderFile _image(String id, {String folder = _camera, String? name}) =>
    PersonFolderFile(id: id, folder: folder, name: name ?? "$id.jpg");

PersonFolderFace _face(
  String fileId,
  String personId, {
  double area = 1,
  double score = 1,
}) => PersonFolderFace(
  fileId: fileId,
  personId: personId,
  area: area,
  score: score,
);

PersonFolderPerson _person(String id, String name, {bool ignored = false}) =>
    PersonFolderPerson(id: id, name: name, isIgnored: ignored);

PersonFolderRecord _record(
  String id, {
  String original = _camera,
  String personFolder = "Pictures/People/Anna",
  String personId = "p1",
  String? previous,
}) => PersonFolderRecord(
  localId: id,
  originalFolder: original,
  originalName: "$id.jpg",
  personFolder: personFolder,
  previousFolder: previous,
  personId: personId,
  movedAtMs: 1,
);

/// A device and a record store in memory.
class _FakeDevice implements PersonFolderMover, PersonFolderStore {
  final Map<String, PersonFolderFile> files = {};
  final Map<String, PersonFolderRecord> records = {};
  List<PersonFolderName> names = [];

  /// Files that Android does not move.
  final Set<String> refused = {};

  /// Files for which the mover sends no request.
  final Set<String> notTried = {};

  /// Files that move, but whose new place the device does not confirm.
  final Set<String> unverified = {};

  /// When not null, the mover throws on the request with this number
  /// (1-based). [crashAfterMove] says if the files of that request move
  /// before the throw.
  int? crashOnRequest;
  bool crashAfterMove = false;

  int requests = 0;
  final List<int> batchSizes = [];

  _FakeDevice(Iterable<PersonFolderFile> initial) {
    for (final file in initial) {
      files[file.id] = file;
    }
  }

  String folderOf(String id) => files[id]!.folder;

  void _moveFile(PersonFolderMove move) {
    final file = files[move.fileId]!;
    files[move.fileId] = PersonFolderFile(
      id: file.id,
      folder: move.toFolder,
      name: file.name,
    );
  }

  @override
  Future<Map<String, PersonFolderMoveOutcome>> move(
    List<PersonFolderMove> batch,
  ) async {
    requests++;
    batchSizes.add(batch.length);
    final crash = crashOnRequest == requests;
    if (crash && !crashAfterMove) throw StateError("crash before the move");
    final outcomes = <String, PersonFolderMoveOutcome>{};
    for (final move in batch) {
      if (!files.containsKey(move.fileId)) {
        outcomes[move.fileId] = const PersonFolderMoveOutcome.missing();
      } else if (notTried.contains(move.fileId)) {
        outcomes[move.fileId] = const PersonFolderMoveOutcome.notTried("away");
      } else if (unverified.contains(move.fileId)) {
        _moveFile(move);
        outcomes[move.fileId] = const PersonFolderMoveOutcome.unknown("?");
      } else if (refused.contains(move.fileId)) {
        outcomes[move.fileId] = const PersonFolderMoveOutcome.notMoved("no");
      } else {
        _moveFile(move);
        outcomes[move.fileId] = PersonFolderMoveOutcome.moved(move.toFolder);
      }
    }
    if (crash) throw StateError("crash after the move");
    return outcomes;
  }

  @override
  Future<void> applyRecordChanges({
    Iterable<PersonFolderRecord> upserts = const [],
    Iterable<String> deletes = const [],
  }) async {
    for (final record in upserts) {
      records[record.localId] = record;
    }
    for (final id in deletes) {
      records.remove(id);
    }
  }

  @override
  Future<void> saveFolderNames(List<PersonFolderName> names) async {
    this.names = names;
  }

  PersonFolderPlan plan({
    required List<PersonFolderPerson> persons,
    List<PersonFolderFace> faces = const [],
    Map<String, Iterable<String>> manual = const {},
    Set<String> failedMoves = const {},
  }) {
    return PersonFolderPlanner.plan(
      files: files.values,
      faces: faces,
      persons: persons,
      manualAssignments: manual,
      records: records.values,
      folderNames: names,
      failedMoves: failedMoves,
    );
  }

  Future<PersonFolderExecution> run(
    PersonFolderPlan plan, {
    int batchSize = 50,
    bool Function()? shouldStop,
  }) {
    return PersonFolderExecutor(
      store: this,
      mover: this,
      batchSize: batchSize,
    ).execute(plan, nowMs: 1000, shouldStop: shouldStop);
  }
}

void main() {
  final anna = _person("p1", "Anna");
  final bob = _person("p2", "Bob");

  group("sanitizeFolderName", () {
    String clean(String name) => PersonFolderPlanner.sanitizeFolderName(name);

    test("keeps a normal name", () {
      expect(clean("Anna Smith"), "Anna Smith");
      expect(clean("St. John-O'Neil"), "St. John-O'Neil");
    });

    test("replaces slashes and other forbidden characters", () {
      expect(clean("Anna/Bob"), "Anna Bob");
      expect(clean(r"A\B:C*D?E"), "A B C D E");
      expect(clean('A"B<C>D|E'), "A B C D E");
      expect(clean("Anna\nBob\tCarl"), "Anna Bob Carl");
    });

    test("removes leading dots and trailing dots and spaces", () {
      expect(clean(".hidden"), "hidden");
      expect(clean("..Anna"), "Anna");
      expect(clean("An\u200Ena\u202E"), "Anna");
      expect(clean("An\u200Ena\u202E"), "Anna");
      expect(clean("An\u200Ena\u202E"), "Anna");
      expect(clean("  Anna"), "Anna");
      expect(clean("J.R."), "J.R");
    });

    test("collapses spaces", () {
      expect(clean("Anna    Maria\u00A0Smith"), "Anna Maria Smith");
    });

    test("keeps emoji and letters of other scripts", () {
      expect(clean("Anna 🎉"), "Anna 🎉");
      expect(clean("👨‍👩‍👧"), "👨‍👩‍👧");
      expect(clean("রুহিত"), "রুহিত");
      expect(clean("Zoë Müller"), "Zoë Müller");
    });

    test("removes direction marks and unpaired surrogates", () {
      expect(clean("An\u200Ena\u202E"), "Anna");
      expect(clean("Anna${String.fromCharCode(0xD83C)}"), "Anna");
    });

    test("uses the fallback when nothing is left", () {
      expect(clean("///"), kPersonFolderFallbackName);
      expect(clean("..."), kPersonFolderFallbackName);
      expect(clean(" . "), kPersonFolderFallbackName);
      expect(clean("\u200E"), kPersonFolderFallbackName);
    });

    test("cuts a long name and does not split an emoji", () {
      final long = clean("a" * 200);
      expect(long.length, kPersonFolderMaxNameLength);
      final withEmoji = clean("${"a" * (kPersonFolderMaxNameLength - 1)}🎉");
      expect(withEmoji, "a" * (kPersonFolderMaxNameLength - 1));
    });
  });

  group("assignFolderNames", () {
    Map<String, String> assign(
      List<PersonFolderPerson> persons, [
      List<PersonFolderName> existing = const [],
    ]) {
      return {
        for (final name in PersonFolderPlanner.assignFolderNames(
          persons: persons,
          existing: existing,
        ))
          name.personId: name.folderName,
      };
    }

    test("two persons with the same name get different folders", () {
      final persons = [_person("p2", "Anna"), _person("p1", "Anna")];
      expect(assign(persons), {"p1": "Anna", "p2": "Anna (2)"});
      // The order of the input has no effect.
      expect(assign(persons.reversed.toList()), {
        "p1": "Anna",
        "p2": "Anna (2)",
      });
    });

    test("names that differ only in letter case do not share a folder", () {
      expect(assign([_person("p1", "anna"), _person("p2", "Anna")]), {
        "p1": "anna",
        "p2": "Anna (2)",
      });
    });

    test("a stored name stays when other persons come and go", () {
      const stored = [
        PersonFolderName(personId: "p1", baseName: "Anna", folderName: "Anna"),
        PersonFolderName(
          personId: "p2",
          baseName: "Anna",
          folderName: "Anna (2)",
        ),
      ];
      // p1 is gone: p2 keeps "Anna (2)".
      expect(assign([_person("p2", "Anna")], stored), {"p2": "Anna (2)"});
      // A new person with a smaller ID does not take a folder that is in use.
      expect(
        assign([
          _person("p0", "Anna"),
          _person("p1", "Anna"),
          _person("p2", "Anna"),
        ], stored),
        {"p0": "Anna (3)", "p1": "Anna", "p2": "Anna (2)"},
      );
      // p1 is gone and p0 is new: p0 gets the free name.
      expect(assign([_person("p0", "Anna"), _person("p2", "Anna")], stored), {
        "p0": "Anna",
        "p2": "Anna (2)",
      });
    });

    test("a renamed person gets a new folder name", () {
      const stored = [
        PersonFolderName(personId: "p1", baseName: "Anna", folderName: "Anna"),
      ];
      expect(assign([_person("p1", "Anna Smith")], stored), {
        "p1": "Anna Smith",
      });
    });

    test("persons without a name and ignored persons get no folder", () {
      expect(
        assign([
          _person("p1", ""),
          _person("p2", "   "),
          _person("p3", "Carl", ignored: true),
          _person("p4", "Dora"),
        ]),
        {"p4": "Dora"},
      );
    });

    test("names that are empty after sanitising get different folders", () {
      expect(assign([_person("p1", "///"), _person("p2", "...")]), {
        "p1": "Person",
        "p2": "Person (2)",
      });
    });
  });

  group("plan", () {
    test("an image of one named person moves to the person folder", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1"), _image("2")],
        faces: [_face("1", "p1")],
        persons: [anna],
      );
      expect(plan.moves, hasLength(1));
      final move = plan.moves.single;
      expect(move.fileId, "1");
      expect(move.kind, PersonFolderMoveKind.sort);
      expect(move.fromFolder, _camera);
      expect(move.toFolder, "Pictures/People/Anna");
      expect(move.originalFolder, _camera);
      expect(move.personId, "p1");
      expect(plan.skips, isEmpty);
      expect(plan.folderNames!.single.folderName, "Anna");
    });

    test("a face cluster without a person is ignored", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: [_face("1", "cluster_without_person")],
        persons: [anna],
      );
      expect(plan.moves, isEmpty);
      expect(plan.skips, isEmpty);
    });

    test("a person without a name is ignored", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: [_face("1", "p9")],
        persons: [_person("p9", "")],
      );
      expect(plan.moves, isEmpty);
    });

    test("an ignored person is ignored", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: [_face("1", "p1", area: 0.9), _face("1", "p2", area: 0.1)],
        persons: [_person("p1", "Anna", ignored: true), bob],
      );
      // Bob has the smaller face, but Anna is ignored.
      expect(plan.moves.single.toFolder, "Pictures/People/Bob");
    });

    test("with two named persons the largest face wins", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: [
          _face("1", "p1", area: 0.02, score: 0.99),
          _face("1", "p2", area: 0.05, score: 0.60),
          _face("1", "p1", area: 0.01),
        ],
        persons: [anna, bob],
      );
      expect(plan.moves.single.personId, "p2");
      expect(plan.moves.single.toFolder, "Pictures/People/Bob");
    });

    test("equal face areas: higher score wins, then smaller person ID", () {
      final byScore = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: [
          _face("1", "p1", area: 0.05, score: 0.7),
          _face("1", "p2", area: 0.05, score: 0.8),
        ],
        persons: [anna, bob],
      );
      expect(byScore.moves.single.personId, "p2");

      for (final faces in [
        [_face("1", "p1", area: 0.05), _face("1", "p2", area: 0.05)],
        [_face("1", "p2", area: 0.05), _face("1", "p1", area: 0.05)],
      ]) {
        final byId = PersonFolderPlanner.plan(
          files: [_image("1")],
          faces: faces,
          persons: [anna, bob],
        );
        expect(byId.moves.single.personId, "p1");
      }
    });

    test("a manual assignment alone moves the image", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: const [],
        persons: [anna],
        manualAssignments: {
          "p1": ["1"],
        },
      );
      expect(plan.moves.single.toFolder, "Pictures/People/Anna");
    });

    test("a detected face wins against a manual assignment", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: [_face("1", "p2", area: 0.0001, score: 0.1)],
        persons: [anna, bob],
        manualAssignments: {
          "p1": ["1"],
        },
      );
      expect(plan.moves.single.personId, "p2");
    });

    test("a manual assignment to an ignored person is ignored", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1")],
        faces: const [],
        persons: [_person("p1", "Anna", ignored: true)],
        manualAssignments: {
          "p1": ["1"],
        },
      );
      expect(plan.moves, isEmpty);
    });

    test("a renamed person: the image moves to the new folder", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1", folder: "Pictures/People/Anna")],
        faces: [_face("1", "p1")],
        persons: [_person("p1", "Anna Smith")],
        records: [_record("1")],
        folderNames: const [
          PersonFolderName(
            personId: "p1",
            baseName: "Anna",
            folderName: "Anna",
          ),
        ],
      );
      final move = plan.moves.single;
      expect(move.kind, PersonFolderMoveKind.resort);
      expect(move.fromFolder, "Pictures/People/Anna");
      expect(move.toFolder, "Pictures/People/Anna Smith");
      // The original folder is kept for a later restore.
      expect(move.originalFolder, _camera);
      expect(plan.folderNames!.single.folderName, "Anna Smith");
    });

    test("merged persons: the image moves to the folder of the target", () {
      // p1 (Anna) was merged into p2 (Bob): p1 does not exist any more and
      // its faces belong to p2.
      final plan = PersonFolderPlanner.plan(
        files: [_image("1", folder: "Pictures/People/Anna")],
        faces: [_face("1", "p2")],
        persons: [bob],
        records: [_record("1")],
        folderNames: const [
          PersonFolderName(
            personId: "p1",
            baseName: "Anna",
            folderName: "Anna",
          ),
          PersonFolderName(personId: "p2", baseName: "Bob", folderName: "Bob"),
        ],
      );
      final move = plan.moves.single;
      expect(move.kind, PersonFolderMoveKind.resort);
      expect(move.toFolder, "Pictures/People/Bob");
      expect(move.personId, "p2");
      expect(plan.folderNames!.map((name) => name.personId), ["p2"]);
    });

    test("no named person any more: the image returns to its folder", () {
      for (final persons in [
        <PersonFolderPerson>[], // person deleted
        [_person("p1", "")], // name removed
        [_person("p1", "Anna", ignored: true)], // person ignored
      ]) {
        final plan = PersonFolderPlanner.plan(
          files: [_image("1", folder: "Pictures/People/Anna")],
          faces: [_face("1", "p1")],
          persons: persons,
          records: [_record("1", original: "DCIM/Trip 2024")],
        );
        final move = plan.moves.single;
        expect(move.kind, PersonFolderMoveKind.restore);
        expect(move.toFolder, "DCIM/Trip 2024");
        expect(move.personId, isNull);
      }
    });

    test("a face removed from the person: the image returns", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1", folder: "Pictures/People/Anna")],
        faces: const [],
        persons: [anna],
        records: [_record("1")],
      );
      expect(plan.moves.single.kind, PersonFolderMoveKind.restore);
      expect(plan.moves.single.toFolder, _camera);
    });

    test("an image that is in the right folder does not move", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1", folder: "Pictures/People/Anna/")],
        faces: [_face("1", "p1")],
        persons: [anna],
        records: [_record("1")],
      );
      expect(plan.moves, isEmpty);
      expect(plan.skips, isEmpty);
      expect(plan.recordDrops, isEmpty);
      expect(plan.recordUpdates, isEmpty);
    });

    test("folder comparison ignores letter case", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1", folder: "pictures/people/anna")],
        faces: [_face("1", "p1")],
        persons: [anna],
        records: [_record("1")],
      );
      expect(plan.moves, isEmpty);
      expect(plan.recordDrops, isEmpty);
    });

    test("the record gets the new person ID when the folder is the same", () {
      // p1 was deleted and p3 has the same name and now holds the face.
      final plan = PersonFolderPlanner.plan(
        files: [_image("1", folder: "Pictures/People/Anna")],
        faces: [_face("1", "p3")],
        persons: [_person("p3", "Anna")],
        records: [_record("1")],
      );
      expect(plan.moves, isEmpty);
      expect(plan.recordUpdates.single.personId, "p3");
      expect(plan.recordUpdates.single.originalFolder, _camera);
    });

    test("a video is skipped", () {
      final plan = PersonFolderPlanner.plan(
        files: const [
          PersonFolderFile(id: "1", folder: "", name: "1.mp4", isImage: false),
        ],
        faces: [_face("1", "p1")],
        persons: [anna],
      );
      expect(plan.moves, isEmpty);
      expect(plan.skips.single.reason, PersonFolderSkipReason.notImage);
    });

    test("a file in Pictures/People that the tool did not put there stays", () {
      final plan = PersonFolderPlanner.plan(
        files: [
          // In the folder of a different person.
          _image("1", folder: "Pictures/People/Bob"),
          // In a folder that is not a person folder of the tool.
          _image("2", folder: "Pictures/People/Party/2023"),
          // Directly in the people root.
          _image("3", folder: "Pictures/People"),
          // Already in the right folder.
          _image("4", folder: "Pictures/People/Anna"),
        ],
        faces: [
          _face("1", "p1"),
          _face("2", "p1"),
          _face("3", "p1"),
          _face("4", "p1"),
        ],
        persons: [anna, bob],
      );
      expect(plan.moves, isEmpty);
      expect(plan.skips.map((skip) => skip.fileId), ["1", "2", "3"]);
      expect(plan.skips.map((skip) => skip.reason).toSet(), {
        PersonFolderSkipReason.foreignInPeopleFolder,
      });
    });

    test("a folder with a similar name is not the people root", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1", folder: "Pictures/People2")],
        faces: [_face("1", "p1")],
        persons: [anna],
      );
      expect(plan.moves.single.kind, PersonFolderMoveKind.sort);
    });

    test(
      "an image outside DCIM and Pictures is sorted and restores below Pictures",
      () {
        final plan = PersonFolderPlanner.plan(
          files: [
            _image("1", folder: "Download"),
            _image("2", folder: "Android/media/com.whatsapp/WhatsApp/Media"),
            _image("3", folder: ""),
            _image("4", folder: "Pictures"),
            _image("5", folder: "dcim/Camera"),
          ],
          faces: [
            for (final id in ["1", "2", "3", "4", "5"]) _face(id, "p1"),
          ],
          persons: [anna],
        );
        // Owner's decision: these files are sorted too. They cannot return to
        // their source folder, so the recorded original is below Pictures.
        expect(plan.moves.map((move) => move.fileId), [
          "1",
          "2",
          "3",
          "4",
          "5",
        ]);
        expect(plan.skips, isEmpty);
        final original = {
          for (final move in plan.moves) move.fileId: move.originalFolder,
        };
        expect(original["1"], "Pictures/Download");
        expect(original["2"], "Pictures/Media");
        expect(original["3"], "Pictures/Restored");
        expect(original["4"], "Pictures");
        expect(original["5"], "dcim/Camera");
      },
    );

    test("a missing file: the record is dropped, no error", () {
      final plan = PersonFolderPlanner.plan(
        files: const [],
        faces: [_face("1", "p1")],
        persons: [anna],
        records: [_record("1")],
      );
      expect(plan.moves, isEmpty);
      expect(plan.recordDrops.single.localId, "1");
      expect(
        plan.recordDrops.single.reason,
        PersonFolderRecordDropReason.fileMissing,
      );
    });

    test("a file in the trash keeps its record", () {
      final plan = PersonFolderPlanner.plan(
        files: const [],
        faces: [_face("1", "p1")],
        persons: [anna],
        records: [_record("1")],
        unavailableFileIds: {"1"},
      );
      expect(plan.moves, isEmpty);
      expect(plan.recordDrops, isEmpty);
      expect(plan.skips.single.reason, PersonFolderSkipReason.unavailable);
    });

    test("a file moved by the user is skipped and its record is dropped", () {
      for (final folder in ["DCIM/Keep", _camera]) {
        final plan = PersonFolderPlanner.plan(
          files: [_image("1", folder: folder)],
          faces: [_face("1", "p1")],
          persons: [anna],
          records: [_record("1")],
        );
        expect(plan.moves, isEmpty);
        expect(
          plan.recordDrops.single.reason,
          PersonFolderRecordDropReason.movedExternally,
        );
        expect(
          plan.skips.single.reason,
          PersonFolderSkipReason.movedExternally,
        );
      }
    });

    test("a file with a name that is in the target folder is skipped", () {
      final plan = PersonFolderPlanner.plan(
        files: [
          _image("1", name: "IMG_0001.JPG"),
          // Not placed by the tool, same name without letter case.
          _image("9", folder: "Pictures/People/Anna", name: "img_0001.jpg"),
        ],
        faces: [_face("1", "p1")],
        persons: [anna],
      );
      expect(plan.moves, isEmpty);
      expect(plan.skips.single.fileId, "1");
      expect(plan.skips.single.reason, PersonFolderSkipReason.nameCollision);
    });

    test("two files with the same name: only the first one moves", () {
      final plan = PersonFolderPlanner.plan(
        files: [
          _image("1", folder: "DCIM/A", name: "IMG_0001.JPG"),
          _image("2", folder: "DCIM/B", name: "IMG_0001.JPG"),
        ],
        faces: [_face("1", "p1"), _face("2", "p1")],
        persons: [anna],
      );
      expect(plan.moves.single.fileId, "1");
      expect(plan.skips.single.fileId, "2");
      expect(plan.skips.single.reason, PersonFolderSkipReason.nameCollision);
    });

    test("a restore is skipped when the name is taken in the old folder", () {
      final plan = PersonFolderPlanner.plan(
        files: [
          _image("1", folder: "Pictures/People/Anna", name: "a.jpg"),
          _image("2", name: "a.jpg"),
        ],
        faces: const [],
        persons: [anna],
        records: [_record("1")],
      );
      expect(plan.moves, isEmpty);
      expect(plan.recordDrops, isEmpty);
      expect(plan.skips.single.reason, PersonFolderSkipReason.nameCollision);
    });

    test("a move that failed before is not planned again", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1"), _image("2")],
        faces: [_face("1", "p1"), _face("2", "p1")],
        persons: [anna],
        failedMoves: {personFolderMoveKey("1", "Pictures/People/Anna")},
      );
      expect(plan.moves.single.fileId, "2");
      expect(plan.skips.single.reason, PersonFolderSkipReason.failedBefore);
    });

    test("moves are sorted by target folder", () {
      final plan = PersonFolderPlanner.plan(
        files: [_image("1"), _image("2"), _image("3")],
        faces: [_face("1", "p2"), _face("2", "p1"), _face("3", "p2")],
        persons: [anna, bob],
      );
      expect(plan.moves.map((move) => move.fileId), ["2", "1", "3"]);
    });

    group("pending records (the app stopped during a move)", () {
      test("first move took place: the record is confirmed", () {
        final plan = PersonFolderPlanner.plan(
          files: [_image("1", folder: "Pictures/People/Anna")],
          faces: [_face("1", "p1")],
          persons: [anna],
          records: [_record("1", previous: _camera)],
        );
        expect(plan.moves, isEmpty);
        expect(plan.recordDrops, isEmpty);
        final update = plan.recordUpdates.single;
        expect(update.isPending, isFalse);
        expect(update.personFolder, "Pictures/People/Anna");
        expect(update.originalFolder, _camera);
      });

      test("first move did not take place: it is planned again", () {
        final plan = PersonFolderPlanner.plan(
          files: [_image("1")],
          faces: [_face("1", "p1")],
          persons: [anna],
          records: [_record("1", previous: _camera)],
        );
        expect(
          plan.recordDrops.single.reason,
          PersonFolderRecordDropReason.moveNotDone,
        );
        expect(plan.skips, isEmpty);
        expect(plan.moves.single.kind, PersonFolderMoveKind.sort);
        expect(plan.moves.single.originalFolder, _camera);
      });

      test("move between person folders did not take place", () {
        // The record says "Bob", but the file is still in "Anna".
        final plan = PersonFolderPlanner.plan(
          files: [_image("1", folder: "Pictures/People/Anna")],
          faces: [_face("1", "p2")],
          persons: [anna, bob],
          records: [
            _record(
              "1",
              personFolder: "Pictures/People/Bob",
              personId: "p2",
              previous: "Pictures/People/Anna",
            ),
          ],
        );
        expect(plan.recordDrops, isEmpty);
        final move = plan.moves.single;
        expect(move.kind, PersonFolderMoveKind.resort);
        expect(move.fromFolder, "Pictures/People/Anna");
        expect(move.toFolder, "Pictures/People/Bob");
        // The original folder is not lost.
        expect(move.originalFolder, _camera);
        expect(move.record!.personFolder, "Pictures/People/Anna");
        expect(move.record!.isPending, isFalse);
      });

      test("pending record and the file is in a third folder", () {
        final plan = PersonFolderPlanner.plan(
          files: [_image("1", folder: "DCIM/Other")],
          faces: [_face("1", "p1")],
          persons: [anna],
          records: [_record("1", previous: _camera)],
        );
        expect(plan.moves, isEmpty);
        expect(
          plan.recordDrops.single.reason,
          PersonFolderRecordDropReason.movedExternally,
        );
      });
    });
  });

  group("planRestoreAll", () {
    test("each recorded file returns to its original folder", () {
      final plan = PersonFolderPlanner.planRestoreAll(
        files: [
          _image("1", folder: "Pictures/People/Anna"),
          _image("2", folder: "Pictures/People/Bob"),
          _image("3", folder: "Pictures/People/Bob"),
        ],
        records: [
          _record("1"),
          _record(
            "2",
            original: "DCIM/Trip",
            personFolder: "Pictures/People/Bob",
          ),
        ],
      );
      expect(plan.folderNames, isNull);
      expect(plan.moves.map((move) => move.kind).toSet(), {
        PersonFolderMoveKind.restore,
      });
      expect(
        {for (final move in plan.moves) move.fileId: move.toFolder},
        {"1": _camera, "2": "DCIM/Trip"},
      );
    });

    test("missing, trashed and moved files", () {
      final plan = PersonFolderPlanner.planRestoreAll(
        files: [
          _image("3", folder: "DCIM/Keep"),
          _image("4"),
        ],
        records: [_record("1"), _record("2"), _record("3"), _record("4")],
        unavailableFileIds: {"2"},
      );
      expect(plan.moves, isEmpty);
      expect(
        {for (final drop in plan.recordDrops) drop.localId: drop.reason},
        {
          "1": PersonFolderRecordDropReason.fileMissing,
          "3": PersonFolderRecordDropReason.movedExternally,
          "4": PersonFolderRecordDropReason.movedExternally,
        },
      );
      expect(plan.skips.single.fileId, "2");
      expect(plan.skips.single.reason, PersonFolderSkipReason.unavailable);
    });

    test("a pending move between person folders is restored", () {
      final plan = PersonFolderPlanner.planRestoreAll(
        files: [_image("1", folder: "Pictures/People/Anna")],
        records: [
          _record(
            "1",
            personFolder: "Pictures/People/Bob",
            previous: "Pictures/People/Anna",
          ),
        ],
      );
      expect(plan.moves.single.fromFolder, "Pictures/People/Anna");
      expect(plan.moves.single.toFolder, _camera);
    });
  });

  group("plan and execute", () {
    test("a second plan after the run has nothing to do", () async {
      final device = _FakeDevice([
        _image("1"),
        _image("2", folder: "DCIM/Trip"),
        _image("3"),
        _image("4", folder: "Download"),
      ]);
      final faces = [
        _face("1", "p1"),
        _face("2", "p1", area: 0.1),
        _face("2", "p2", area: 0.2),
        _face("4", "p1"),
      ];
      final persons = [anna, bob];
      final first = device.plan(persons: persons, faces: faces);
      final execution = await device.run(first);

      expect(execution.sorted, 3);
      expect(execution.error, isNull);
      expect(device.folderOf("1"), "Pictures/People/Anna");
      expect(device.folderOf("2"), "Pictures/People/Bob");
      expect(device.folderOf("3"), _camera);
      // The image in "Download" is sorted too; it restores below Pictures.
      expect(device.folderOf("4"), "Pictures/People/Anna");
      expect(device.records.keys.toSet(), {"1", "2", "4"});
      expect(device.records["4"]!.originalFolder, "Pictures/Download");
      expect(device.records["2"]!.originalFolder, "DCIM/Trip");
      expect(device.records["2"]!.personId, "p2");
      expect(device.records.values.any((record) => record.isPending), isFalse);
      expect(device.names.map((name) => name.folderName), ["Anna", "Bob"]);

      final second = device.plan(persons: persons, faces: faces);
      expect(second.moves, isEmpty);
      expect(second.recordDrops, isEmpty);
      expect(second.recordUpdates, isEmpty);
      expect(second.skips, isEmpty);
    });

    test("rename, merge, removal and restore all", () async {
      final device = _FakeDevice([_image("1"), _image("2", folder: "DCIM/B")]);
      var faces = [_face("1", "p1"), _face("2", "p2")];
      await device.run(device.plan(persons: [anna, bob], faces: faces));
      expect(device.folderOf("1"), "Pictures/People/Anna");
      expect(device.folderOf("2"), "Pictures/People/Bob");

      // Rename Anna.
      final renamed = [_person("p1", "Anna Smith"), bob];
      var execution = await device.run(
        device.plan(persons: renamed, faces: faces),
      );
      expect(execution.resorted, 1);
      expect(device.folderOf("1"), "Pictures/People/Anna Smith");
      expect(device.records["1"]!.originalFolder, _camera);

      // Merge Bob into Anna Smith.
      faces = [_face("1", "p1"), _face("2", "p1")];
      execution = await device.run(
        device.plan(persons: [renamed.first], faces: faces),
      );
      expect(execution.resorted, 1);
      expect(device.folderOf("2"), "Pictures/People/Anna Smith");
      expect(device.records["2"]!.originalFolder, "DCIM/B");
      expect(device.records["2"]!.personId, "p1");

      // "Not this person" for image 1.
      faces = [_face("2", "p1")];
      execution = await device.run(
        device.plan(persons: [renamed.first], faces: faces),
      );
      expect(execution.restored, 1);
      expect(device.folderOf("1"), _camera);
      expect(device.records.keys, ["2"]);

      // Restore all.
      execution = await device.run(
        PersonFolderPlanner.planRestoreAll(
          files: device.files.values,
          records: device.records.values,
        ),
      );
      expect(execution.restored, 1);
      expect(device.folderOf("2"), "DCIM/B");
      expect(device.records, isEmpty);
    });

    test("a refused move leaves no record and is remembered", () async {
      final device = _FakeDevice([_image("1"), _image("2")])..refused.add("1");
      final faces = [_face("1", "p1"), _face("2", "p1")];
      final execution = await device.run(
        device.plan(persons: [anna], faces: faces),
      );
      expect(execution.sorted, 1);
      expect(device.folderOf("1"), _camera);
      expect(device.records.keys, ["2"]);
      expect(execution.skips.single.reason, PersonFolderSkipReason.moveRefused);
      expect(execution.failedMoves, {
        personFolderMoveKey("1", "Pictures/People/Anna"),
      });

      final next = device.plan(
        persons: [anna],
        faces: faces,
        failedMoves: execution.failedMoves,
      );
      expect(next.moves, isEmpty);
    });

    test("a refused restore keeps the record", () async {
      final device = _FakeDevice([_image("1")]);
      await device.run(device.plan(persons: [anna], faces: [_face("1", "p1")]));
      device.refused.add("1");
      final execution = await device.run(device.plan(persons: [anna]));
      expect(execution.restored, 0);
      expect(device.folderOf("1"), "Pictures/People/Anna");
      expect(device.records["1"]!.originalFolder, _camera);
      expect(device.records["1"]!.isPending, isFalse);
    });

    test(
      "a refused move between person folders keeps the old record",
      () async {
        final device = _FakeDevice([_image("1")]);
        await device.run(
          device.plan(persons: [anna], faces: [_face("1", "p1")]),
        );
        device.refused.add("1");
        await device.run(
          device.plan(persons: [anna, bob], faces: [_face("1", "p2")]),
        );
        final record = device.records["1"]!;
        expect(record.personFolder, "Pictures/People/Anna");
        expect(record.personId, "p1");
        expect(record.isPending, isFalse);
      },
    );

    test("a file that went away during the run loses its record", () async {
      final device = _FakeDevice([_image("1"), _image("2")]);
      final plan = device.plan(
        persons: [anna],
        faces: [_face("1", "p1"), _face("2", "p1")],
      );
      device.files.remove("1");
      final execution = await device.run(plan);
      expect(execution.sorted, 1);
      expect(execution.skips.single.reason, PersonFolderSkipReason.missing);
      expect(device.records.keys, ["2"]);
    });

    test("crash after the move: restore all still works", () async {
      final device = _FakeDevice([_image("1")])
        ..crashOnRequest = 1
        ..crashAfterMove = true;
      final faces = [_face("1", "p1")];
      final execution = await device.run(
        device.plan(persons: [anna], faces: faces),
      );
      expect(execution.error, isNotNull);
      // The file moved, and the record that was written before the move
      // knows the original folder.
      expect(device.folderOf("1"), "Pictures/People/Anna");
      expect(device.records["1"]!.isPending, isTrue);
      expect(device.records["1"]!.originalFolder, _camera);

      // Restore all without a sort run in between.
      device.crashOnRequest = null;
      final restore = await device.run(
        PersonFolderPlanner.planRestoreAll(
          files: device.files.values,
          records: device.records.values,
        ),
      );
      expect(restore.restored, 1);
      expect(device.folderOf("1"), _camera);
      expect(device.records, isEmpty);
    });

    test(
      "crash after the move: the next sort run confirms the record",
      () async {
        final device = _FakeDevice([_image("1")])
          ..crashOnRequest = 1
          ..crashAfterMove = true;
        final faces = [_face("1", "p1")];
        await device.run(device.plan(persons: [anna], faces: faces));
        device.crashOnRequest = null;
        final next = device.plan(persons: [anna], faces: faces);
        expect(next.moves, isEmpty);
        await device.run(next);
        expect(device.records["1"]!.isPending, isFalse);
        expect(device.records["1"]!.personFolder, "Pictures/People/Anna");
      },
    );

    test("crash before the move: the next run moves the file", () async {
      final device = _FakeDevice([_image("1")])..crashOnRequest = 1;
      final faces = [_face("1", "p1")];
      final execution = await device.run(
        device.plan(persons: [anna], faces: faces),
      );
      expect(execution.error, isNotNull);
      expect(device.folderOf("1"), _camera);
      expect(device.records["1"]!.isPending, isTrue);

      // "Restore all" has nothing to move and removes the record.
      final restorePlan = PersonFolderPlanner.planRestoreAll(
        files: device.files.values,
        records: device.records.values,
      );
      expect(restorePlan.moves, isEmpty);
      expect(restorePlan.recordDrops.single.localId, "1");

      device.crashOnRequest = null;
      final next = await device.run(device.plan(persons: [anna], faces: faces));
      expect(next.sorted, 1);
      expect(device.folderOf("1"), "Pictures/People/Anna");
      expect(device.records["1"]!.isPending, isFalse);
      expect(device.records["1"]!.originalFolder, _camera);
    });

    test("crash during a move between person folders", () async {
      for (final afterMove in [false, true]) {
        final device = _FakeDevice([_image("1", folder: "DCIM/Trip")]);
        await device.run(
          device.plan(persons: [anna], faces: [_face("1", "p1")]),
        );
        device
          ..crashOnRequest = 2
          ..crashAfterMove = afterMove;
        final faces = [_face("1", "p2")];
        await device.run(device.plan(persons: [anna, bob], faces: faces));
        expect(device.records["1"]!.isPending, isTrue);
        expect(device.records["1"]!.originalFolder, "DCIM/Trip");

        device.crashOnRequest = null;
        await device.run(device.plan(persons: [anna, bob], faces: faces));
        expect(device.folderOf("1"), "Pictures/People/Bob");
        final record = device.records["1"]!;
        expect(record.isPending, isFalse);
        expect(record.personFolder, "Pictures/People/Bob");
        expect(record.personId, "p2");
        expect(record.originalFolder, "DCIM/Trip");
      }
    });

    test("crash after a restore: the stale record is dropped", () async {
      final device = _FakeDevice([_image("1")]);
      await device.run(device.plan(persons: [anna], faces: [_face("1", "p1")]));
      device
        ..crashOnRequest = 2
        ..crashAfterMove = true;
      await device.run(device.plan(persons: [anna]));
      expect(device.folderOf("1"), _camera);
      expect(device.records, isNotEmpty);

      device.crashOnRequest = null;
      await device.run(device.plan(persons: [anna]));
      expect(device.folderOf("1"), _camera);
      expect(device.records, isEmpty);
    });

    test("moves run in batches", () async {
      final device = _FakeDevice([for (var i = 0; i < 7; i++) _image("$i")]);
      final plan = device.plan(
        persons: [anna],
        faces: [for (var i = 0; i < 7; i++) _face("$i", "p1")],
      );
      final progress = <int>[];
      final execution =
          await PersonFolderExecutor(
            store: device,
            mover: device,
            batchSize: 3,
          ).execute(
            plan,
            nowMs: 5,
            onProgress: (done, total) => progress.add(done),
          );
      expect(device.batchSizes, [3, 3, 1]);
      expect(progress, [0, 3, 6, 7]);
      expect(execution.sorted, 7);
      expect(
        device.records.values.every((record) => record.movedAtMs == 5),
        isTrue,
      );
    });

    test("a stop request ends the run after the current batch", () async {
      final device = _FakeDevice([for (var i = 0; i < 6; i++) _image("$i")]);
      final plan = device.plan(
        persons: [anna],
        faces: [for (var i = 0; i < 6; i++) _face("$i", "p1")],
      );
      final execution = await device.run(
        plan,
        batchSize: 2,
        shouldStop: () => device.requests >= 1,
      );
      expect(execution.stopped, isTrue);
      expect(execution.sorted, 2);
      expect(execution.notTried, 4);
      expect(device.records, hasLength(2));
    });

    test("files without a request end the run and leave no record", () async {
      final device = _FakeDevice([for (var i = 0; i < 6; i++) _image("$i")])
        ..notTried.addAll(["1"]);
      final plan = device.plan(
        persons: [anna],
        faces: [for (var i = 0; i < 6; i++) _face("$i", "p1")],
      );
      final execution = await device.run(plan, batchSize: 2);
      expect(execution.error, "away");
      expect(device.requests, 1);
      expect(execution.sorted, 1);
      expect(execution.notTried, 5);
      expect(execution.failedMoves, isEmpty);
      expect(device.records.keys, ["0"]);
    });

    test("a move that the device does not confirm keeps its record", () async {
      final device = _FakeDevice([_image("1"), _image("2")])
        ..unverified.add("1");
      final faces = [_face("1", "p1"), _face("2", "p1")];
      final execution = await device.run(
        device.plan(persons: [anna], faces: faces),
        batchSize: 1,
      );
      expect(execution.error, "?");
      expect(execution.unverified, 1);
      expect(execution.notTried, 1);
      expect(device.requests, 1);
      // The record that was written before the request is still there, so
      // "Restore all" can move the file back.
      expect(device.records["1"]!.isPending, isTrue);
      expect(device.records["1"]!.originalFolder, _camera);

      device.unverified.clear();
      final next = await device.run(device.plan(persons: [anna], faces: faces));
      expect(next.sorted, 1);
      expect(device.records["1"]!.isPending, isFalse);
      expect(device.records["1"]!.personFolder, "Pictures/People/Anna");
      expect(device.folderOf("2"), "Pictures/People/Anna");
    });

    test("the run is aborted when Android moves nothing", () async {
      final device = _FakeDevice([for (var i = 0; i < 10; i++) _image("$i")]);
      device.refused.addAll(device.files.keys);
      final plan = device.plan(
        persons: [anna],
        faces: [for (var i = 0; i < 10; i++) _face("$i", "p1")],
      );
      final execution = await device.run(plan, batchSize: 2);
      expect(execution.error, isNotNull);
      expect(device.requests, 3);
      expect(execution.notTried, 4);
      expect(device.records, isEmpty);
    });

    test("record changes of the plan are written without a move", () async {
      final device = _FakeDevice([_image("1", folder: "DCIM/Keep")]);
      device.records["1"] = _record("1");
      device.records["2"] = _record("2");
      final plan = device.plan(persons: [anna], faces: [_face("1", "p1")]);
      await device.run(plan);
      expect(device.records, isEmpty);
      expect(device.requests, 0);
    });
  });
}

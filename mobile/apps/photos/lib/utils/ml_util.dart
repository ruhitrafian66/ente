import "dart:io" show File, Platform;

import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:flutter/services.dart" show PlatformException;
import "package:logging/logging.dart";
import "package:photos/db/files_db.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/db/offline_files_db.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/models/ml/face/dimension.dart";
import "package:photos/models/ml/ml_typedefs.dart";
import "package:photos/models/ml/ml_versions.dart";
import "package:photos/module/download/file.dart";
import "package:photos/module/download/thumbnail.dart";
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/face_ml/face_alignment/alignment_result.dart";
import "package:photos/services/machine_learning/face_ml/face_detection/detection.dart";
import "package:photos/services/machine_learning/ml_exceptions.dart";
import "package:photos/services/machine_learning/ml_result.dart";
import "package:photos/services/machine_learning/ml_run_control.dart";
import "package:photos/services/search_service.dart";
import "package:photos/services/sync/origin_fetch_tracker.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust_ml;
import "package:photos/utils/network_util.dart";

final _logger = Logger("MlUtil");

enum FileDataForML { thumbnailData, fileData }

enum MLMode { enteGallery, localGallery }

class IndexStatus {
  final int indexedItems, pendingItems;
  final bool? hasWifiEnabled;

  IndexStatus(this.indexedItems, this.pendingItems, [this.hasWifiEnabled]);
}

class FileMLInstruction {
  final EnteFile file;
  final MLMode mode;
  final int? localGalleryFileKey;
  bool shouldRunFaces;
  bool shouldRunClip;
  bool shouldRunPets;

  FileMLInstruction({
    required this.file,
    required this.mode,
    this.localGalleryFileKey,
    required this.shouldRunFaces,
    required this.shouldRunClip,
    this.shouldRunPets = false,
  });
  bool get pendingML => shouldRunFaces || shouldRunClip || shouldRunPets;
  bool get isLocalGallery => mode == MLMode.localGallery;
  int get fileKey =>
      isLocalGallery ? localGalleryFileKey! : file.uploadedFileID!;
}

// Keep these eligibility rules in sync with candidate enumeration below.
Future<IndexStatus> getIndexStatus() async {
  try {
    final mlDataDB = MLDataDB.localGalleryInstance;
    final bool petActive =
        kOfflineRunPets && localSettings.petRecognitionEnabled;
    // Offline fork: CLIP does not run, so "fully indexed" (faces AND CLIP)
    // never becomes true. Count a file as done when its faces are indexed.
    final Set<int> indexedFileKeys = kOfflineRunClip
        ? await mlDataDB.getFullyIndexedFileIds(includePets: petActive)
        : (await mlDataDB.faceIndexedFileIds()).keys.toSet();
    final enteFiles = await SearchService.instance.getAllFilesForSearch();
    final Set<int> seenKeys = {};
    int total = 0;
    int indexed = 0;
    final localIds = <String>[];
    for (final EnteFile enteFile in enteFiles) {
      if (enteFile.fileType == FileType.other) {
        continue;
      }
      if ((enteFile.localID ?? '').isEmpty ||
          (enteFile.uploadedFileID != null && enteFile.uploadedFileID != -1)) {
        continue;
      }
      localIds.add(enteFile.localID!);
    }
    final localIdToIntId = await OfflineFilesDB.instance.ensureLocalIntIds(
      localIds,
    );
    for (final localId in localIds) {
      final localIntId = localIdToIntId[localId];
      if (localIntId == null || !seenKeys.add(localIntId)) {
        continue;
      }
      total++;
      if (indexedFileKeys.contains(localIntId)) {
        indexed++;
      }
    }
    final hasWifiEnabled = await canUseHighBandwidth();
    _logger.info(
      "IndexStatus: $indexed indexed of $total total (localGallery: true, petActive: $petActive, hasWifiEnabled: $hasWifiEnabled)",
    );
    return IndexStatus(indexed, total - indexed, hasWifiEnabled);
  } catch (e, s) {
    _logger.severe('Error getting ML status', e, s);
    rethrow;
  }
}

Future<List<FileMLInstruction>> getLocalGalleryFilesForMlIndexing() async {
  _logger.info('getLocalGalleryFilesForMlIndexing called');
  final mlDataDB = MLDataDB.localGalleryInstance;
  final Map<int, int> faceIndexedFileIDs = await mlDataDB.faceIndexedFileIds();
  final Map<int, int> clipIndexedFileIDs = await mlDataDB
      .clipIndexedFileWithVersion();
  final bool petEnabled =
      kOfflineRunPets && localSettings.petRecognitionEnabled;
  final Map<int, int> petIndexedFileIDs = petEnabled
      ? await mlDataDB.petIndexedFileIds()
      : const {};
  final Set<int> queuedFileIDs = {};

  final enteFiles = await SearchService.instance.getAllFilesForSearch();
  final candidateFiles = <EnteFile>[];
  final localIds = <String>[];
  final List<FileMLInstruction> instructions = [];

  for (final EnteFile enteFile in enteFiles) {
    if (enteFile.fileType == FileType.other) {
      continue;
    }
    if ((enteFile.localID ?? '').isEmpty ||
        (enteFile.uploadedFileID != null && enteFile.uploadedFileID != -1)) {
      continue;
    }
    final localID = enteFile.localID!;
    candidateFiles.add(enteFile);
    localIds.add(localID);
  }

  final localIdToIntId = await OfflineFilesDB.instance.ensureLocalIntIds(
    localIds,
  );

  for (final enteFile in candidateFiles) {
    final localID = enteFile.localID!;
    final localIntId = localIdToIntId[localID];
    if (localIntId == null) {
      continue;
    }
    if (queuedFileIDs.contains(localIntId)) {
      continue;
    }
    queuedFileIDs.add(localIntId);
    final shouldRunFaces = _shouldRunIndexingWithFileId(
      localIntId,
      faceIndexedFileIDs,
      faceMlVersion,
    );
    final shouldRunClip =
        kOfflineRunClip &&
        _shouldRunIndexingWithFileId(
          localIntId,
          clipIndexedFileIDs,
          clipMlVersion,
        );
    final shouldRunPets =
        petEnabled &&
        _shouldRunIndexingWithFileId(
          localIntId,
          petIndexedFileIDs,
          petMlVersion,
        );
    if (!shouldRunFaces && !shouldRunClip && !shouldRunPets) {
      continue;
    }
    instructions.add(
      FileMLInstruction(
        file: enteFile,
        mode: MLMode.localGallery,
        localGalleryFileKey: localIntId,
        shouldRunFaces: shouldRunFaces,
        shouldRunClip: shouldRunClip,
        shouldRunPets: shouldRunPets,
      ),
    );
  }
  _logger.info(
    "Getting list of ${instructions.length} files to index for offline ML",
  );
  return instructions;
}

Stream<List<FileMLInstruction>> fetchEmbeddingsAndInstructions(
  int yieldSize, {
  required MLMode mode,
  MlRunControl? control,
}) async* {
  if (control?.stopRequested ?? false) return;
  // Offline fork: only the local gallery has files to index.
  if (mode != MLMode.localGallery) return;
  final List<FileMLInstruction> filesToIndex =
      await getLocalGalleryFilesForMlIndexing();
  final List<List<FileMLInstruction>> chunks = filesToIndex.chunks(yieldSize);
  for (final batch in chunks) {
    if (control?.stopRequested ?? false) return;
    yield batch;
  }
}

Future<int> getIndexableFileCount() async {
  return FilesDB.instance.remoteFileCount();
}

Future<String> getImagePathForML(EnteFile enteFile) async {
  String? imagePath;

  final stopwatch = Stopwatch()..start();
  File? file;
  final bool isVideo = enteFile.fileType == FileType.video;
  if (isVideo) {
    try {
      file = await getThumbnailForUploadedFile(enteFile);
    } on PlatformException catch (e, s) {
      _logger.severe(
        "Could not get thumbnail for $enteFile due to PlatformException",
        e,
        s,
      );
      throw ThumbnailRetrievalException(e.toString(), s);
    }
  } else {
    if (enteFile.fileSize != null && enteFile.fileSize! > maxFileDownloadSize) {
      throw Exception(
        "FileSizeTooLargeForMobileIndexing: size is ${enteFile.fileSize}",
      );
    }
    try {
      if (Platform.isIOS) {
        originFetchTracker.record(
          localID: enteFile.localID,
          modificationTime: enteFile.modificationTime,
        );
      }
      file = await getFile(enteFile, isOrigin: true);
    } catch (e, s) {
      _logger.severe("Could not get file for $enteFile", e, s);
    }
  }
  imagePath = file?.path;
  stopwatch.stop();
  _logger.info(
    "Getting file data for fileID ${enteFile.uploadedFileID} took ${stopwatch.elapsedMilliseconds} ms",
  );

  if (imagePath == null) {
    final fileIdentifier = "localID ${enteFile.localID}";
    _logger.severe(
      "Failed to get any data for enteFile with $fileIdentifier and format ${enteFile.displayName.split('.').last} and size ${enteFile.fileSize} since its file path is null (isVideo: $isVideo)",
    );
    throw CouldNotRetrieveAnyFileData();
  }

  return imagePath;
}

bool _shouldRunIndexingWithFileId(
  int fileId,
  Map<int, int> indexedFileIds,
  int newestVersion,
) {
  return !indexedFileIds.containsKey(fileId) ||
      indexedFileIds[fileId]! < newestVersion;
}

Future<MLResult> analyzeImageRust(Map args) async {
  try {
    final int enteFileID = args["enteFileID"] as int;
    final String imagePath = args["filePath"] as String;
    final bool runFaces = args["runFaces"] as bool;
    final bool runClip = args["runClip"] as bool;
    final bool runPets = args["runPets"] as bool? ?? false;
    await rust_ml.setMlExecutionConfig(
      enableWebgpu: (args["enableWebGpu"] as bool?) ?? false,
    );

    Future<rust_ml.AnalyzeImageResult> runRustAnalyzeForPath(
      String analyzePath,
    ) {
      return rust_ml.analyzeImageRust(
        req: rust_ml.AnalyzeImageRequest(
          fileId: enteFileID,
          imagePath: analyzePath,
          runFaces: runFaces,
          runClip: runClip,
          runPets: runPets,
          assetsDir: args["assetsDir"] as String,
        ),
      );
    }

    final fileFormat = getExtension(imagePath);
    rust_ml.AnalyzeImageResult rustResult;
    try {
      rustResult = await runRustAnalyzeForPath(imagePath);
    } on rust_ml.RustMlError_ModelDownloadNetwork catch (e) {
      throw ModelDownloadNetworkException(e.message);
    } catch (e, s) {
      if (!_isRustImageIssue(e)) {
        if (_isRustCorruptModelIssue(e)) {
          rethrow;
        }
        _logger.severe(
          "Rust pipeline failed (non-image) for fileID $enteFileID (format: $fileFormat)",
          e,
          s,
        );
        rethrow;
      }

      // A Rust image error is deterministic for this file. In particular, a
      // decode error may be a resource-limit rejection, so retrying it through
      // an unbounded Dart decoder can exhaust the mobile process.
      throw _asInvalidImageFormatExceptionForRustImageFailure(
        enteFileID: enteFileID,
        fileFormat: fileFormat,
        primaryError: e,
      );
    }

    final result = MLResult.fromEnteFileID(
      enteFileID,
      remoteFlags:
          mlIndexFlagRuntimeRust |
          (rustResult.usedCoreml ? mlIndexFlagCoreML : 0) |
          (rustResult.usedWebgpu ? mlIndexFlagWebGPU : 0),
    );
    result.decodedImageSize = Dimensions(
      width: rustResult.decodedImageSize.width,
      height: rustResult.decodedImageSize.height,
    );

    // Null means the pipeline did not run; an empty result would overwrite
    // remote embeddings.
    if (!runFaces) result.faces = null;

    if (runFaces) {
      final rustFaces = rustResult.faces ?? const <rust_ml.RustFaceResult>[];
      result.faces = rustFaces
          .map((face) {
            final detection = FaceDetectionRelative(
              score: face.detection.score,
              box: face.detection.boxXyxy.toList(growable: false),
              allKeypoints: face.detection.allKeypoints
                  .map((point) => point.toList(growable: false))
                  .toList(growable: false),
            );
            final alignment = AlignmentResult(
              affineMatrix: face.alignment.affineMatrix
                  .map((row) => row.toList(growable: false))
                  .toList(growable: false),
              center: face.alignment.center.toList(growable: false),
              size: face.alignment.size,
              rotation: face.alignment.rotation,
            );
            return FaceResult(
              fileId: enteFileID,
              faceId: face.faceId,
              detection: detection,
              blurValue: face.blurValue,
              alignment: alignment,
              embedding: face.embedding,
            );
          })
          .toList(growable: false);
    }

    if (runClip) {
      final rustClip = rustResult.clip;
      if (rustClip == null) {
        throw Exception("RustMLMissingClipOutput: clip output was null");
      }
      result.clip = ClipResult(
        fileID: enteFileID,
        embedding: rustClip.embedding,
      );
    }

    if (runPets) {
      if (rustResult.petFaces != null) {
        result.petFaces = rustResult.petFaces!
            .map((face) {
              final detection = FaceDetectionRelative(
                score: face.detection.score,
                box: face.detection.boxXyxy.toList(growable: false),
                allKeypoints: face.detection.keypoints
                    .map((point) => point.toList(growable: false))
                    .toList(growable: false),
              );
              final alignment = AlignmentResult(
                // Rust already aligned pet faces; no Dart matrix is needed.
                affineMatrix: const [],
                center: face.alignment.center.toList(growable: false),
                size: face.alignment.cropSize,
                rotation: face.alignment.angle,
              );
              return PetFaceResult(
                fileId: enteFileID,
                petFaceId: face.petFaceId,
                detection: detection,
                alignment: alignment,
                species: face.species,
                embedding: Embedding.from(face.faceEmbedding),
              );
            })
            .toList(growable: false);
      }

      if (rustResult.petBodies != null) {
        result.petBodies = rustResult.petBodies!
            .map((body) {
              return PetBodyResult(
                boxXyxy: body.boxXyxy.toList(growable: false),
                score: body.score,
                cocoClass: body.cocoClass,
                petBodyId: body.petBodyId,
                embedding: Embedding.from(body.bodyEmbedding),
              );
            })
            .toList(growable: false);
      }
    }

    return result;
  } catch (e, s) {
    if (e is ModelDownloadNetworkException || isExpectedMlSkipError(e)) {
      rethrow;
    }
    _logger.severe("Could not analyze image with Rust pipeline", e, s);
    rethrow;
  }
}

bool isExpectedMlSkipError(Object error) {
  final message = _normalizedErrorMessage(error);
  const acceptedIssueMarkers = <String>[
    "thumbnailretrievalexception",
    "invalidimageformatexception",
    "unhandledexiforientation",
    "filesizetoolargeformobileindexing",
  ];
  return acceptedIssueMarkers.any(message.contains);
}

String formatExpectedMlSkipReasonForLogs(Object error) {
  final normalized = _normalizedErrorMessage(error);
  if (normalized.contains("invalidimageformatexception")) {
    return "image decode failed";
  }
  if (normalized.contains("thumbnailretrievalexception")) {
    return "thumbnail retrieval failed";
  }
  if (normalized.contains("unhandledexiforientation")) {
    return "unsupported EXIF orientation";
  }
  if (normalized.contains("filesizetoolargeformobileindexing")) {
    return "file is too large for mobile indexing";
  }
  final firstLine = error.toString().split('\n').first.trim();
  return firstLine.isEmpty ? "unknown ML skip reason" : firstLine;
}

bool _isRustImageIssue(Object error) {
  return error is rust_ml.RustMlError_InvalidImage;
}

bool _isRustCorruptModelIssue(Object error) {
  return error is rust_ml.RustMlError_CorruptModel;
}

String _normalizedErrorMessage(Object error) {
  if (error is PlatformException) {
    return <String>[
      error.code,
      error.message ?? "",
      "${error.details ?? ""}",
      error.toString(),
    ].join(" ").toLowerCase();
  }
  return error.toString().toLowerCase();
}

Exception _asInvalidImageFormatExceptionForRustImageFailure({
  required int enteFileID,
  required String fileFormat,
  required Object primaryError,
}) {
  final details = <String>[
    "InvalidImageFormatException: Rust image processing failed for fileID $enteFileID (format: $fileFormat)",
    "primary_error: $primaryError",
  ];
  return Exception(details.join("; "));
}

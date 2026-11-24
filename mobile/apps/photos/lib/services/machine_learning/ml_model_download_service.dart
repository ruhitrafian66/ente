import "dart:async";

import "package:logging/logging.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";
import "package:photos/service_locator.dart"
    show hasGrantedMLConsent, localSettings;
import "package:photos/services/machine_learning/bundled_ml_models.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust_ml;
import "package:synchronized/synchronized.dart";

class MLModelDownloadService {
  final _logger = Logger("MLModelDownloadService");

  final _downloadModelLock = Lock();
  final _progressController = StreamController<(String, int, int)>.broadcast();

  Stream<(String, int, int)> get progressStream => _progressController.stream;

  Future<String> getAssetsDirectory() async =>
      p.join((await getApplicationSupportDirectory()).path, "assets");

  final _activeModelDownloadTriggers = <bool>{};

  bool _areIndexingModelsDownloaded = false;
  bool _areNonIndexingModelsDownloaded = false;

  MLModelDownloadService._privateConstructor();
  static final instance = MLModelDownloadService._privateConstructor();
  factory MLModelDownloadService() => instance;

  bool get areIndexingModelsDownloaded => _areIndexingModelsDownloaded;

  bool areModelsDownloaded({required bool onlyIndexingModels}) {
    return _areIndexingModelsDownloaded &&
        (onlyIndexingModels || _areNonIndexingModelsDownloaded);
  }

  // Offline fork: nothing is downloaded, so the CLIP text model can load only
  // if its files are already on disk.
  Future<bool> canLoadClipTextModel() async {
    return rust_ml.isClipTextDownloaded(
      assetsDir: await getAssetsDirectory(),
      includeVocab: true,
    );
  }

  void invalidateModelDownloadCache({bool includeNonIndexingModels = false}) {
    _areIndexingModelsDownloaded = false;
    if (includeNonIndexingModels) {
      _areNonIndexingModelsDownloaded = false;
    }
  }

  void triggerModelsDownload({required bool onlyIndexingModels}) {
    if (areModelsDownloaded(onlyIndexingModels: onlyIndexingModels) ||
        _activeModelDownloadTriggers.contains(onlyIndexingModels)) {
      return;
    }
    _activeModelDownloadTriggers.add(onlyIndexingModels);
    ensureModelsDownloaded(onlyIndexingModels: onlyIndexingModels)
        .whenComplete(
          () => _activeModelDownloadTriggers.remove(onlyIndexingModels),
        )
        .ignore();
  }

  Future<void> ensureModelsDownloaded({
    required bool onlyIndexingModels,
  }) async {
    return _downloadModelLock.synchronized(() async {
      if (areModelsDownloaded(onlyIndexingModels: onlyIndexingModels)) {
        return;
      }
      if (!hasGrantedMLConsent) {
        _logger.info("Skipping ML model download because ML consent is off");
        return;
      }
      if (!localSettings.isMLLocalIndexingEnabled) {
        _logger.info(
          "Skipping ML model download because local indexing is disabled",
        );
        return;
      }
      // Offline fork: the face models ship inside the APK. Copy them into
      // place and never ask Rust to download anything.
      await installBundledMlModels(await getAssetsDirectory());
      _areIndexingModelsDownloaded = true;
      _areNonIndexingModelsDownloaded = true;
    });
  }
}

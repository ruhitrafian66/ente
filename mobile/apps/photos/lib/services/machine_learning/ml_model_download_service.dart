import "dart:async";

import "package:flutter/foundation.dart";
import "package:logging/logging.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart"
    show hasGrantedMLConsent, localSettings;
import "package:photos/services/machine_learning/bundled_ml_models.dart";
import "package:photos/services/machine_learning/ml_service.dart";
import "package:photos/services/machine_learning/semantic_search/semantic_search_service.dart";
import "package:photos/src/rust/api/ml_indexing_api.dart" as rust_ml;
import "package:shared_preferences/shared_preferences.dart";
import "package:synchronized/synchronized.dart";

/// Offline fork: where the CLIP (magic search) models are.
enum ClipModelPhase {
  /// `kOfflineRunClip` is false.
  off,

  /// Not on the device, and the owner did not ask for the download.
  notDownloaded,
  downloading,
  ready,

  /// The last download try failed. The next try starts with the next ML run
  /// after [MLModelDownloadService.clipRetryInterval], or on a tap.
  failed,
}

class ClipModelStatus {
  final ClipModelPhase phase;
  final int downloadedBytes;
  final String? error;

  const ClipModelStatus(this.phase, {this.downloadedBytes = 0, this.error});

  double get fraction =>
      (downloadedBytes / kOfflineClipDownloadBytes).clamp(0.0, 1.0);
}

class MLModelDownloadService {
  final _logger = Logger("MLModelDownloadService");

  final _downloadModelLock = Lock();

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

  // ---------------------------------------------------------------------
  // Offline fork: CLIP models. These are the only files that the app gets
  // from the network. The download starts only after the owner asked for it
  // on the ML settings page ([requestClipDownload]).
  // ---------------------------------------------------------------------

  static const clipRetryInterval = Duration(minutes: 10);
  static const _clipRequestedKey = "offline_fork_clip_download_requested";

  /// For the ML settings page.
  final ValueNotifier<ClipModelStatus> clipStatus = ValueNotifier(
    const ClipModelStatus(
      kOfflineRunClip ? ClipModelPhase.notDownloaded : ClipModelPhase.off,
    ),
  );

  Future<void>? _clipPreload;
  DateTime? _lastClipFailure;

  /// True when CLIP indexing and magic search can run: the switch is on and
  /// the image model, the text model and the vocabulary are on the device.
  bool get isClipActive =>
      kOfflineRunClip && clipStatus.value.phase == ClipModelPhase.ready;

  Future<bool> _isClipTextOnDisk() async {
    return rust_ml.isClipTextDownloaded(
      assetsDir: await getAssetsDirectory(),
      includeVocab: true,
    );
  }

  Future<bool> canLoadClipTextModel() async {
    return kOfflineRunClip && await _isClipTextOnDisk();
  }

  /// Makes CLIP active when its files are already on the device. Never
  /// starts a download of files that are not there. Returns [isClipActive].
  Future<bool> activateClipFromDisk() async {
    if (!kOfflineRunClip) return false;
    if (isClipActive) return true;
    // The text model is the last file of a download, so its presence means
    // that the download ended. The preload then only checks the files.
    if (await _isClipTextOnDisk()) {
      await _preloadClip(isDownload: false);
    }
    return isClipActive;
  }

  /// The owner asked for the download (ML settings page). Later runs
  /// continue or repeat the download without a new request.
  Future<void> requestClipDownload() async {
    if (!kOfflineRunClip || isClipActive) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_clipRequestedKey, true);
    _lastClipFailure = null;
    unawaited(_preloadClip(isDownload: true));
  }

  Future<void> _continueClipDownloadIfRequested() async {
    if (!kOfflineRunClip || isClipActive || _clipPreload != null) return;
    if (await activateClipFromDisk()) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_clipRequestedKey) ?? false)) return;
    final lastFailure = _lastClipFailure;
    if (lastFailure != null &&
        DateTime.now().difference(lastFailure) < clipRetryInterval) {
      return;
    }
    // Not awaited: face indexing must not wait for a large download.
    unawaited(_preloadClip(isDownload: true));
  }

  Future<void> _preloadClip({required bool isDownload}) {
    return _clipPreload ??= _runClipPreload(
      isDownload: isDownload,
    ).whenComplete(() => _clipPreload = null);
  }

  Future<void> _runClipPreload({required bool isDownload}) async {
    final progress = <String, int>{};
    var lastLoggedTenth = -1;
    if (isDownload) {
      clipStatus.value = const ClipModelStatus(ClipModelPhase.downloading);
      _logger.info("Downloading the CLIP models");
    }
    try {
      await for (final update in rust_ml.preloadMlModels(
        assetsDir: await getAssetsDirectory(),
        runFaces: false,
        runClip: true,
        runPets: false,
        includeClipText: true,
      )) {
        switch (update) {
          case rust_ml.ModelDownloadEvent_Progress():
            if (!isDownload) continue;
            progress[update.model] = update.downloadedBytes.toInt();
            final downloaded = progress.values.fold(0, (a, b) => a + b);
            final status = ClipModelStatus(
              ClipModelPhase.downloading,
              downloadedBytes: downloaded,
            );
            clipStatus.value = status;
            final tenth = (status.fraction * 10).floor();
            if (tenth != lastLoggedTenth) {
              lastLoggedTenth = tenth;
              _logger.info("CLIP model download: ${tenth * 10}%");
            }
          case rust_ml.ModelDownloadEvent_Failed():
            throw update.error;
        }
      }
      clipStatus.value = const ClipModelStatus(ClipModelPhase.ready);
      _logger.info("CLIP models are ready");
      if (isDownload) {
        // Load the text model and index the library for CLIP.
        unawaited(SemanticSearchService.instance.init());
        MLService.instance.triggerML();
      }
    } catch (e, s) {
      _lastClipFailure = DateTime.now();
      _logger.warning("CLIP model preload failed", e, s);
      clipStatus.value = ClipModelStatus(
        ClipModelPhase.failed,
        error: e.toString(),
      );
    }
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
      if (!areModelsDownloaded(onlyIndexingModels: onlyIndexingModels)) {
        // Offline fork: the face models ship inside the APK. Copy them into
        // place. Face indexing never needs the network.
        await installBundledMlModels(await getAssetsDirectory());
        _areIndexingModelsDownloaded = true;
        _areNonIndexingModelsDownloaded = true;
      }
      await _continueClipDownloadIfRequested();
    });
  }
}

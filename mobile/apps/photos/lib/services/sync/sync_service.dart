import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/sync_finished_event.dart';
import 'package:photos/events/sync_status_update_event.dart';
import 'package:photos/main.dart';
import 'package:photos/services/sync/local_sync_service.dart';
import 'package:photos/services/sync/offline_import_metadata_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SyncService {
  final _logger = Logger("SyncService");
  final _localSyncService = LocalSyncService.instance;
  Completer<bool>? _existingSync;
  SyncStatusUpdate? _lastSyncStatusEvent;
  bool _isInitialized = false;

  SyncService._privateConstructor();

  static final SyncService instance = SyncService._privateConstructor();

  Future<void> init(SharedPreferences preferences) async {
    if (Platform.isIOS) {
      _logger.info("Clearing file cache");
      await PhotoManager.clearFileCache();
      _logger.info("Cleared file cache");
    }
    if (!_isInitialized) {
      _isInitialized = true;
      _registerListeners();
    }
  }

  void _registerListeners() {
    Bus.instance.on<SyncStatusUpdate>().listen((event) {
      _logger.info("Sync status received " + event.toString());
      _lastSyncStatusEvent = event;
    });
  }

  Future<bool> sync() async {
    if (!_isInitialized) {
      _logger.warning("Sync requested before init, skipping");
      return false;
    }
    if (_existingSync != null) {
      _logger.warning("Sync already in progress, skipping.");
      return _existingSync!.future;
    }
    _existingSync = Completer<bool>();
    bool successful = false;
    try {
      await _doSync();
      if (_lastSyncStatusEvent != null &&
          _lastSyncStatusEvent!.status !=
              SyncStatus.completedFirstGalleryImport &&
          _lastSyncStatusEvent!.status != SyncStatus.completedBackup) {
        Bus.instance.fire(SyncStatusUpdate(SyncStatus.completedBackup));
      }
      successful = true;
    } catch (e) {
      _logger.severe("backup failed", e, StackTrace.current);
      Bus.instance.fire(SyncStatusUpdate(SyncStatus.error));
      rethrow;
    } finally {
      _existingSync?.complete(successful);
      _existingSync = null;
      _lastSyncStatusEvent = null;
      _logger.info("Syncing completed");
      Bus.instance.fire(SyncFinishedEvent());
    }
    return successful;
  }

  bool isSyncInProgress() {
    return _existingSync != null;
  }

  SyncStatusUpdate? getLastSyncStatusEvent() {
    return _lastSyncStatusEvent;
  }

  Future<void> onPermissionGranted() async {
    final runningSync = _existingSync?.future;
    if (runningSync != null) {
      await runningSync;
    }
    await sync();
  }

  Future<void> _doSync() async {
    _logger.info("[SYNC] Starting local sync");
    await _localSyncService.sync();
    await _localSyncService.syncAll();
    if (Platform.isAndroid) {
      final processing = OfflineImportMetadataService.instance
          .processPendingFiles(
            batchSize: isProcessBg
                ? 10
                : OfflineImportMetadataService.kDefaultBatchSize,
          );
      if (isProcessBg) {
        await processing;
      } else {
        unawaited(processing);
      }
    }
    _logger.info(
      "[SYNC] Local gallery mode${Platform.isAndroid ? '' : ' (non-Android, no metadata processing)'}, skipping remote sync",
    );
  }
}

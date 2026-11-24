import "package:package_info_plus/package_info_plus.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/ml_consent_changed_event.dart";
import "package:photos/offline_fork.dart";
import "package:photos/services/backup_preference_service.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/services/location_service.dart";
import "package:photos/services/machine_learning/compute_controller.dart";
import "package:photos/services/machine_learning/ml_decryption_record_store.dart";
import "package:photos/services/magic_cache_service.dart";
import "package:photos/services/memories/dart_memories_computer.dart";
import "package:photos/services/memories/memories_computer.dart";
import "package:photos/services/memories/rust_memories_computer.dart";
import "package:photos/services/memories/smart_memories_service.dart";
import "package:photos/services/memories_cache_service.dart";
import "package:photos/services/permission/service.dart";
import "package:photos/services/rewind/rewind_service.dart";
import "package:photos/services/text_embeddings_cache_service.dart";
import "package:photos/services/wake_lock_service.dart";
import "package:photos/settings/backup_settings.dart";
import "package:photos/settings/local_settings.dart";
import "package:shared_preferences/shared_preferences.dart";

class ServiceLocator {
  late final SharedPreferences prefs;
  late final PackageInfo packageInfo;
  late final LocalSettings localSettings;
  late final BackupSettings backupSettings;
  late final EnteWakeLockService wakeLockService;
  late final MlDecryptionRecordStore mlDecryptionRecordStore;

  ServiceLocator._privateConstructor();

  static final ServiceLocator instance = ServiceLocator._privateConstructor();

  void init(SharedPreferences prefs, PackageInfo packageInfo) {
    this.prefs = prefs;
    this.packageInfo = packageInfo;
    localSettings = LocalSettings(prefs);
    backupSettings = BackupSettings(prefs);
    wakeLockService = EnteWakeLockService();
    mlDecryptionRecordStore = MlDecryptionRecordStore(prefs);
  }
}

LocalSettings get localSettings => ServiceLocator.instance.localSettings;

BackupSettings get backupSettings => ServiceLocator.instance.backupSettings;

EnteWakeLockService get wakeLockService =>
    ServiceLocator.instance.wakeLockService;

MlDecryptionRecordStore get mlDecryptionRecordStore =>
    ServiceLocator.instance.mlDecryptionRecordStore;

bool get hasGrantedMLConsent => localSettings.localGalleryMLConsent;

Future<void> setMLConsent(bool enabled) async {
  await localSettings.setLocalGalleryMLConsent(enabled);
  Bus.instance.fire(MLConsentChangedEvent(enabled));
}

BackupPreferenceService? _backupPreferenceService;
BackupPreferenceService get backupPreferenceService {
  _backupPreferenceService ??= BackupPreferenceService(
    ServiceLocator.instance.prefs,
  );
  return _backupPreferenceService!;
}

EntityService? _entityService;

EntityService get entityService {
  _entityService ??= EntityService(ServiceLocator.instance.prefs);
  return _entityService!;
}

LocationService? _locationService;
LocationService get locationService {
  _locationService ??= LocationService();
  return _locationService!;
}

MagicCacheService? _magicCacheService;
MagicCacheService get magicCacheService {
  _magicCacheService ??= MagicCacheService(ServiceLocator.instance.prefs);
  return _magicCacheService!;
}

MemoriesCacheService? _memoriesCacheService;
MemoriesCacheService get memoriesCacheService {
  _memoriesCacheService ??= MemoriesCacheService(ServiceLocator.instance.prefs);
  return _memoriesCacheService!;
}

RewindService? _rewindService;
RewindService get rewindService {
  _rewindService ??= RewindService(ServiceLocator.instance.prefs);
  return _rewindService!;
}

SmartMemoriesService? _smartMemoriesService;
SmartMemoriesService get smartMemoriesService {
  _smartMemoriesService ??= SmartMemoriesService();
  return _smartMemoriesService!;
}

DartMemoriesComputer? _dartMemoriesComputer;
RustMemoriesComputer? _rustMemoriesComputer;
RustMemoriesComputer get rustMemoriesComputer =>
    _rustMemoriesComputer ??= RustMemoriesComputer();
MemoriesComputer get memoriesComputer {
  if (kOfflineRustMemories && MLDataDB.isRustBackend) {
    return rustMemoriesComputer;
  }
  return _dartMemoriesComputer ??= DartMemoriesComputer();
}

TextEmbeddingsCacheService? _textEmbeddingsCacheService;
TextEmbeddingsCacheService get textEmbeddingsCacheService {
  _textEmbeddingsCacheService ??= TextEmbeddingsCacheService.instance;
  return _textEmbeddingsCacheService!;
}

ComputeController? _computeController;
ComputeController get computeController {
  _computeController ??= ComputeController(localSettings);
  return _computeController!;
}

PermissionService? _permissionService;
PermissionService get permissionService {
  _permissionService ??= PermissionService(ServiceLocator.instance.prefs);
  return _permissionService!;
}

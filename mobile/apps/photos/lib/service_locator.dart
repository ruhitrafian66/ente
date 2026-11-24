import "package:dio/dio.dart";
import "package:ente_install_source/ente_install_source.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/core/network/endpoint_config.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/ml_consent_changed_event.dart";
import "package:photos/gateways/entity/entity_gateway.dart";
import "package:photos/gateways/users/users_gateway.dart";
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
  late final Dio enteDio;
  late final Dio nonEnteDio;
  late final Dio downloadDio;
  late final PackageInfo packageInfo;
  late final EndpointConfig endpointConfig;
  late final LocalSettings localSettings;
  late final BackupSettings backupSettings;
  late final EnteWakeLockService wakeLockService;
  late final MlDecryptionRecordStore mlDecryptionRecordStore;

  ServiceLocator._privateConstructor();

  static final ServiceLocator instance = ServiceLocator._privateConstructor();

  void init(
    SharedPreferences prefs,
    Dio enteDio,
    Dio nonEnteDio,
    Dio downloadDio,
    PackageInfo packageInfo,
  ) {
    this.prefs = prefs;
    this.enteDio = enteDio;
    this.nonEnteDio = nonEnteDio;
    this.downloadDio = downloadDio;
    this.packageInfo = packageInfo;
    endpointConfig = EndpointConfig(prefs);
    localSettings = LocalSettings(prefs);
    backupSettings = BackupSettings(prefs);
    wakeLockService = EnteWakeLockService();
    mlDecryptionRecordStore = MlDecryptionRecordStore(prefs);
  }
}

EndpointConfig get endpointConfig => ServiceLocator.instance.endpointConfig;

LocalSettings get localSettings => ServiceLocator.instance.localSettings;

BackupSettings get backupSettings => ServiceLocator.instance.backupSettings;

EnteWakeLockService get wakeLockService =>
    ServiceLocator.instance.wakeLockService;

MlDecryptionRecordStore get mlDecryptionRecordStore =>
    ServiceLocator.instance.mlDecryptionRecordStore;

// True when showing local-device photos instead of an Ente account. Network
// access may still be used.
bool get isLocalGalleryMode => localSettings.isLocalGalleryMode;

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
  _entityService ??= EntityService(
    ServiceLocator.instance.prefs,
    EntityGateway(ServiceLocator.instance.enteDio),
  );
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

InstallSourceService? _installSourceService;
InstallSourceService get installSourceService {
  _installSourceService ??= InstallSourceService(
    ServiceLocator.instance.enteDio,
    app: "photos",
    getToken: Configuration.instance.getToken,
  );
  return _installSourceService!;
}

UsersGateway? _usersGateway;
UsersGateway get usersGateway {
  _usersGateway ??= UsersGateway(
    ServiceLocator.instance.enteDio,
    ServiceLocator.instance.nonEnteDio,
    endpointConfig,
  );
  return _usersGateway!;
}

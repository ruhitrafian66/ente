// Central switches for the offline fork of Ente Photos.
//
// This fork always runs in local gallery mode and never signs in to an Ente
// account. Its only network use is the one-time download of the CLIP models
// (`MLModelDownloadService`), which the owner starts on the ML settings page.
// See CLAUDE.md at the repository root.

/// Only the face models ship inside the APK. The CLIP models (semantic
/// search, Discover) are downloaded once from `models.ente.com` when the
/// owner asks for it. This switch only permits CLIP; code must read
/// `MLModelDownloadService.instance.isClipActive`, which is true when the
/// models are on the device. Pet recognition and OCR stay off.
const bool kOfflineRunClip = true;
const bool kOfflineRunPets = false;

/// Bytes of the CLIP download (MobileCLIP-S2 image model, text model and
/// vocabulary; see `model_asset_spec` in `rust/crates/ml/src/assets.rs`).
const int kOfflineClipDownloadBytes = 143057352 + 67144712 + 3194984;

/// The OCR models (text selection in the photo viewer) are not bundled, and
/// the app cannot download them. When false, no file is eligible for OCR.
const bool kOfflineRunOcr = false;

// Former `FlagService` values (package `ente_feature_flag`). Each constant
// holds the value the flag had in a release build with no account. The flag
// service is gone; change a value only on purpose.

/// ML database backend. False = the Dart database. Never set this to true
/// without a migration: the existing face index would be orphaned.
const bool kOfflineRustMlDb = false;

/// Rust memories computer. It needs the Rust ML database (`kOfflineRustMlDb`).
const bool kOfflineRustMemories = false;

/// Former remote (account) ML consent flag. It is not the local consent
/// (`hasGrantedMLConsent` in `service_locator.dart`). It gates usearch use.
const bool kOfflineRemoteMlConsent = false;

/// Former `enableVectorDb` (= remote ML consent). Gates vector DB writes.
const bool kOfflineEnableVectorDb = false;

/// Former `manualTagFileToPerson` (= remote ML consent). Gates manual tagging.
const bool kOfflineManualTagFileToPerson = false;

/// Former `usearchForSearch`. Has an effect only with remote ML consent.
const bool kOfflineUsearchForSearch = true;

/// Former `usearchForSuggestions`. Has an effect only with remote ML consent.
const bool kOfflineUsearchForSuggestions = true;

/// Former `useRustForHeicDecoder`. False = the full-image viewer decodes HEIC
/// with the Android decoder, not with the Rust decoder.
const bool kOfflineUseRustForHeicDecoder = false;

/// Former `rewind` flag. Rewind also needs an asset pack that is not bundled.
const bool kOfflineRewind = false;

// S25 tuning constants. Each comment gives the upstream value.

/// Minimum battery level (percent) for ML compute. Upstream: 20.
const int kOfflineMinimumBatteryLevel = 10;

/// Maximum Android battery temperature (Celsius) for ML compute. Upstream: 42.
const double kOfflineMaximumAndroidBatteryTemperature = 45;

/// Unclustered face count that forces clustering before indexing. Upstream: 100.
const int kOfflineForceClusteringFaceCount = 2000;

/// Idle time before the ML indexing isolate is disposed. Upstream: 60 seconds.
const Duration kOfflineMlIndexingIsolateIdleTimeout = Duration(minutes: 10);

/// Files fetched per ML indexing chunk on Android. Upstream: 10.
const int kOfflineFileDownloadMlLimit = 24;

/// Set with `--dart-define=OFFLINE_FORK_LOGCAT=true` to print the app log to
/// the console (logcat) in release builds. Off by default.
const bool kOfflineLogToConsole = bool.fromEnvironment("OFFLINE_FORK_LOGCAT");

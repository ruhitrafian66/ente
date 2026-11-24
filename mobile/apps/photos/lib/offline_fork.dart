// Central switches for the offline fork of Ente Photos.
//
// This fork always runs in local gallery mode, never signs in to an Ente
// account, and never uses the network. See CLAUDE.md at the repository root.

/// Only the face models ship inside the APK. CLIP (semantic search), pet
/// recognition and OCR need models that are not bundled, so they stay off.
const bool kOfflineRunClip = false;
const bool kOfflineRunPets = false;

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

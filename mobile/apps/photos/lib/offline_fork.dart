// Central switches for the offline fork of Ente Photos.
//
// This fork always runs in local gallery mode, never signs in to an Ente
// account, and never uses the network. See CLAUDE.md at the repository root.

/// True for every build of this fork. Kept as a named constant so each
/// deviation from upstream is easy to grep for.
const bool kOfflineFork = true;

/// Only the face models ship inside the APK. CLIP (semantic search), pet
/// recognition and OCR need models that are not bundled, so they stay off.
const bool kOfflineRunClip = false;
const bool kOfflineRunPets = false;

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

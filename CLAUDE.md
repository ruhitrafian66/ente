# Ente Photos offline fork

Personal, Android-only fork of [ente-io/ente](https://github.com/ente-io/ente). The app shows on-device photos only, runs face recognition on device, and has no Ente account and no network access. Personal use only: do not assume anything here may be redistributed (see "Models").

- Fork: `<owner>/ente` (remote `origin`). Upstream: remote `upstream`. Work branch: `offline-faces`.
- Forked from upstream commit `6ace5d3` (2026-11-23), shallow clone (`--depth 1`).
- Target device: Samsung Galaxy S25 (arm64, Snapdragon 8 Elite, 12 GB RAM).
- Owner decisions so far are recorded under "Decisions". Do not reopen them without being asked.

## Layout

| Path | What |
|---|---|
| `mobile/apps/photos` | The Flutter app. All app work happens here. |
| `mobile/packages`, `mobile/apps/photos/plugins` | Shared Dart packages and app plugins (pub workspace rooted at `mobile/`). |
| `rust/` | Rust workspace. The app links `rust/bindings/frb/photos` through flutter_rust_bridge. ML lives in `rust/crates/ml`, image decode in `rust/crates/image`. |
| `infra/ml` | Kept only because a Rust ML test reads `infra/ml/test/ml_indexing/assets.json`. |
| `mobile/apps/photos/docs/offline-fork-removal-plan.md` | Staged plan for the full removal of network and account code. Read it before removal work. |

Deleted from the fork: `web/ server/ desktop/ cli/ docs/ apple/ android/ architecture/` and most of `infra/`. Still present but scheduled for deletion: `mobile/apps/auth`, `mobile/apps/locker`, unused packages and Rust crates (plan stages 5 and 7).

## Toolchain (this Mac)

- Flutter 3.47.8 at `~/development/flutter/bin` (not on PATH). Rust stable at `~/.cargo/bin` with Android targets.
- JDK 21: `/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home`. Android SDK: `/opt/homebrew/share/android-commandlinetools`. NDK 27.0.12077973 (needed by `rive_native`) and 28.2.13676358 are installed. Build tools: `build-tools/35.0.0` (`aapt2`, `apksigner`).
- Export `JAVA_HOME` and `ANDROID_HOME` to those paths and put `~/.cargo/bin` and `~/development/flutter/bin` on `PATH` before a build. The default `java` is JDK 24, which Gradle 8.14 does not accept.
- If an NDK download is interrupted, Gradle fails with "NDK ... did not have a source.properties file". Remove that NDK folder and run `sdkmanager --sdk_root=$ANDROID_HOME "ndk;<version>"` (redirect its output; the progress bar is very noisy).
- VS Code's Gradle/Java extension keeps starting Gradle daemons (JDK 24) that eat memory. The permission system blocks `kill`/`pkill` from the agent; ask the owner to run `pkill -f GradleDaemon`. Stop your own background tasks with TaskStop.
- The Mac has 8 GB RAM. Run ONE heavy tool at a time (`flutter analyze`, `flutter test`, `build_runner`, cargo, Gradle). Parallel runs push it deep into swap and stall for 10+ minutes. Tell subagents not to run these; run them yourself, in sequence.
- `rustfmt` is not installed; `cargo codegen frb` prints a formatting error at the end that is harmless.

## Commands

Run from `mobile/apps/photos` unless noted.

```sh
# One-time / after model changes: fetch the bundled face models (needs internet; sha256-checked)
./tool/fetch_bundled_ml_models.sh

# Dart deps (from mobile/). Do NOT pass --enforce-lockfile: the fork changed pubspec.
(cd ../.. && ~/development/flutter/bin/flutter pub get)

# Regenerate the Rust bridge + freezed/json code (slow: ~20-30 min on this Mac). Output: lib/src/rust (git-ignored)
(cd ../../../rust && PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH" cargo codegen frb photos)

# Gates
~/development/flutter/bin/flutter analyze --no-pub          # must print "No issues found!"
~/development/flutter/bin/flutter test --no-pub test/services

# Build (release, debug-signed when no keystore is configured). arm64 only.
~/development/flutter/bin/flutter build apk --release --flavor fdroid \
  --dart-define=cronetHttpNoPlay=true --target-platform android-arm64
# -> build/app/outputs/flutter-apk/app-fdroid-release.apk (about 200 MB)
# Test build: add --dart-define=OFFLINE_FORK_LOGCAT=true so the app log reaches `adb logcat`
```

- Do NOT pass `--no-pub` to `flutter build`: the release plugin registrant is then not regenerated and the Java compile fails on dev-only plugins (`flutter_native_splash`, `integration_test`). `--no-pub` is fine for `analyze` and `test`.
- Build times on this Mac: first build about 25 min (Rust cross-compile with thin LTO); later builds with Rust cached 2.5 to 4 min.

- Flavor `fdroid` is the only one that builds: its applicationId is `io.ente.photos.offline`, label "Ente Offline". Keep `namespace "io.ente.photos"` (Dart refers to Kotlin classes by that name).
- `analysis_options` treats lints such as import ordering as errors. `dart fix --apply lib` fixes most of them.
- Check the merged manifest after a build: `aapt2 dump permissions <apk>` must show no `INTERNET` and no `BILLING` (verified on 2026-11-23).

## Testing on the phone

The owner's S25 is connected over adb (serial `<serial>`). It is their daily phone with their real photo library (about 2,240 files).

- Tell the owner before each install or UI session and wait for their reply. They need to stop using the phone. Tell them when the session ends.
- Never tap Delete, Convert or a merge confirmation on the device. Open the tools only up to that step, unless the owner asks for more.
- The phone locks after a short idle time. The agent cannot and must not unlock it; ask the owner. A black screenshot means the screen is off (`adb shell dumpsys power | grep mWakefulness`).
- Install: `adb install -r <apk>` (keeps app data). Start: `adb shell monkey -p io.ente.photos.offline -c android.intent.category.LAUNCHER 1`.
- Screenshots: `adb exec-out screencap -p > x.png`, then `sips -Z 1000 x.png --out small.png` before reading it. Screen is 1080x2340; bottom tabs are at y≈2200 (home x≈325, albums x≈540, search x≈755); the settings menu icon is at (62,165).
- Waiting: local `sleep` is blocked; use `adb shell "sleep N"`.
- Logs: a release build writes its log to private app storage that adb cannot read. Build with `--dart-define=OFFLINE_FORK_LOGCAT=true`, then `adb logcat -d | grep "flutter :"`. Useful filters: `ML result for fileID` (one line per indexed file), `[rust]` (model load, execution provider), `ComputeController`, `clusterAllImages`, `IndexStatus`, `SEVERE`.
- `adb shell dumpsys battery | grep -m1 temperature` gives tenths of a degree. Do not print the whole dump; it is huge.

## How the fork works

Upstream already had an account-free "local gallery" mode (`AppMode.localGallery`, `isLocalGalleryMode`). The fork forces that mode and fills its gaps.

- `lib/offline_fork.dart` holds `kOfflineFork = true` and the tuning constants. Every deviation in an upstream file is guarded by `kOfflineFork` and/or marked with a comment starting `Offline fork:`. `grep -rn "Offline fork" lib` lists them.
- **Mode**: `LocalSettings.appMode` always returns `localGallery`. First start goes straight to the photo permission screen (`GrantPermissionsWidget(startWithoutAccount: true)`), which also sets ML consent.
- **ML file ID**: ML data (face IDs, cluster maps, `PersonData.manuallyAssigned`) is keyed by an int. Upstream account mode uses `uploadedFileID`; local mode uses the int that `OfflineFilesDB` assigns per device `localID`. Use the synchronous getter `EnteFile.mlFileID` (`lib/models/file/extensions/file_props.dart`) in all people/face code. It reads an in-memory cache (`OfflineFilesDB.refreshIntIdCache()`, loaded at startup). `getMlFileIdToCreationTime()` in `lib/utils/ml_file_ids.dart` and `getFilesForMlFileIDs()` in `lib/utils/face/face_thumbnail_cache.dart` are the batch helpers. `uploadedFileID` is null or -1 for every file.
- **ML databases**: there is no account database. `MLDataDB.instance`, `DartMLDataDB.instance`, `RustMLDataDB.instance`, `FaceClustering.instance`, `ClipVectorDB.instance`, `ClusterCentroidVectorDB.instance` all resolve to their `localGalleryInstance` (`ente.ml.offline.db`).
- **Persons are local**: `EntityService.addOrUpdate/deleteEntry` write straight to the local `entities` table (in `FilesDB`), IDs `local_<nanoid>`, no keys, no gateway. `PersonService._syncOnce` only reconciles `PersonData.assigned` with the cluster-person table. `PersonService.mergePersons(sourceID, targetID)` is new (upstream cannot merge two named persons). Contact linking is off.
- **Models**: only the two face models ship in the APK (`assets/ml_models/`, git-ignored, fetched by the script): YOLOv5-face 640 and MobileFaceNet (192-d). `installBundledMlModels()` copies them to `<app support>/assets/models/<key>/<file>`, where the Rust asset store treats an existing file as downloaded. CLIP, pets and OCR are off (`kOfflineRunClip`, `kOfflineRunPets`), so semantic search does not work.
- **Videos**: face detection sees one 512 px thumbnail frame per video. Accepted limitation.
- **Network**: `INTERNET` is removed from the release manifest (`tools:node="remove"`; debug/profile manifests keep it for Flutter tooling). Firebase, in-app purchase, install referrer and google-services were removed by running `scripts/prepare_fdroid_source.sh` once. Sentry, update checks, push, memory music and deep links are guarded off. WorkManager tasks no longer require a network.
- **S25 tuning**: XNNPACK threads 6 and ORT intra-op threads 4 (`rust/crates/ml/src/onnx/providers.rs`), thin LTO, arm64-only ABI, relaxed battery/temperature gates, warm ML sessions while in the foreground, larger indexing chunks. Execution provider order on Android: WebGPU, XNNPACK, CPU. Indexing is still one image at a time (`SuperIsolate` lock).
- **Flags**: `FlagService.internalUser` no longer returns true for debug builds, so debug and release use the same ML database backend (`rustMlDb` = false, the Dart DB).
- **New tools** (Settings > Free up space):
  - Exact duplicates: `lib/services/exact_duplicates/`, `lib/services/exact_duplicates_service.dart`, `lib/db/exact_duplicates_db.dart`, `lib/ui/tools/exact_duplicates_page.dart`. Size grouping, then SHA-256 of the origin file; never flags similar images.
  - PNG to JPG: `lib/services/png_to_jpg_core.dart` (pure logic), `png_to_jpg_service.dart`, `lib/ui/tools/png_to_jpg_page.dart`. Encodes with the Rust `decodeFullToJpeg`; a PNG is trashed only after its JPEG is verified.

## Decisions

- Personal use only. InsightFace weights (non-commercial licence) are acceptable.
- Planned second step, not started: SCRFD-10G detector + ArcFace R50 (`w600k_r50`, 512-d, from the InsightFace `buffalo_l` pack) behind a build option. Needs DB schema, vector index and cluster threshold changes, and a check that the detector's 5-landmark alignment matches. Do it after the removal.
- Video faces: one thumbnail frame per video is acceptable. No frame sampling.
- Full removal of network and account code was chosen over keeping it switched off ("Full removal" option: also upload, sync, server collections, keys, gateways). Follow `mobile/apps/photos/docs/offline-fork-removal-plan.md` stage by stage; `flutter analyze` must be clean after each stage. Keep the `EnteFile` fields and the `FilesDB` schema and migrations untouched (the plan explains why).
- Unused monorepo projects are deleted (done for top-level dirs; `mobile/apps/auth`, `mobile/apps/locker`, unused packages and Rust crates still to go).
- Local checkpoint commits are fine at the agent's discretion. Never push unless asked.
- The owner said to wait with the final APK until the removal is done. Test builds for the phone are wanted and were made.
- For complex subagent tasks use Fable 5.2 at medium or high effort. Start subagents one after the other on this Mac, and tell them not to run analyzer, tests, Gradle or cargo.
- Text to the owner follows their Simplified Technical English rule (see their global CLAUDE.md).

## Status (update this section as work lands)

Last update: 2026-11-24.

Commits on `offline-faces` (local only, not pushed): `788c382` checkpoint with all features, analyzer clean; `7f949a1` index counter fix, logcat option, device test notes. Run `git log --oneline` for anything newer.

Verified on the S25 (release build, 2026-11-23):
- Install under `io.ente.photos.offline`, label "Ente Offline". First start opens the gallery with no sign-up screen.
- Bundled models install and load. Rust log: both models "loaded ... with WebGpu", zero-input warm-up and golden self-test passed (Adreno, Vulkan vendor allowlisted).
- Indexing runs: about 2.5 to 3 files per second (130 to 190 per minute), whole library of 2,242 files in roughly 13 minutes. The ML run starts about 30 s after app start (that is when `ComputeController` is constructed). Battery went from 30 °C to 37 °C; the limit is 45 °C.
- Exact duplicates: scan of 2,242 files took 835 ms (8 candidates hashed), 4 groups shown, keeper badge and delete bar render correctly. Delete not exercised.
- PNG to JPG: found 162 PNGs (411 MB), estimate about 343 MB saving, page renders. Convert not exercised.
- Settings: no login entries; "Free up space" shows Trash, Exact duplicates, Convert PNG to JPG, Manage device cache.

Found on the device and fixed in code:
- The "x out of N photos processed" counter stayed at 0, because `getIndexStatus` counted only files with faces AND CLIP. It now counts face-indexed files when `kOfflineRunClip` is false. The fixed build is installed but the fix is NOT yet confirmed on screen (the phone was locked).

Verified by the owner on the S25 (2026-11-24): "The people section is verified working correctly." The agent did not see the individual actions; which of them the owner exercised is not recorded.

NOT yet verified on the device:
- The corrected index counter (not confirmed on screen by the agent).
- App lock, memories, widgets, background (WorkManager) indexing, delete from gallery, video playback.

Open issues seen in the log (not fixed):
- `LocationService` tries to download `https://assets.ente.com/location/v2/cities.bin` through Rust and fails (no network). Location search is therefore empty. Either bundle the file or remove the feature in the removal.
- `SemanticSearchService` / `MagicCacheService` log SEVERE "Clip text loading failed" at start and on each magic-cache update. Harmless, but the callers should be switched off.
- Samsung HEIC files log "bounded decode refused: required auxiliary type" and fall back to a full decode. Results are stored, but this is a speed cost worth a look.
- DNG files fail to decode and are skipped. `FileUtil` logs "Could not capture file extension" for a few files.
- The Maps toggle showed as on in Settings even though the default was changed to off. Map tiles cannot load. The removal deletes maps.
- Unit tests for the PNG service were not re-run after two late edits in `png_to_jpg_service.dart` (they compiled and ran on the device).

Next steps, in order:
1. Removal stage 0 is done (`free_space_options.dart` now lives in `lib/ui/settings/`; flag values are recorded in the plan, section 4c-flags).
2. Removal stages 1 to 7 from the plan, one checkpoint commit per stage, device check after the risky ones (stage 2 and 4).
3. Final APK without the logcat define.
4. ArcFace R50 option.

## Notes for the removal (from the plan and the device run)

- `lib/module/download/file.dart` and `thumbnail.dart` look like network code but hold the local file and thumbnail access. Slim them, never delete them.
- `FlagService` values decide ML behaviour. Keep `rustMlDb` false in every build mode, or the face index is orphaned. Record the current values before replacing the flag service (table in the plan, section 4c-flags).
- `flagService.hasGrantedMLConsent` (the remote consent flag, false here) is read directly in about 25 places and currently hides manual face tagging and vector-DB use. Do not change that silently.
- `Configuration.init` used to wipe the secure store on every start without a token; that is switched off (`kOfflineFork`) because the app lock PIN lives there.
- `ACCESS_NETWORK_STATE`, `CAMERA`, `CHANGE_WIFI_MULTICAST_STATE` and `libcronet` are still in the APK; the plan's stages 5 and 6 remove them.

## Known gaps

- People pickers use `getAllFace(minClusterSize: ...)`; small named persons may be missing from the merge picker.
- A multi-person merge runs in sequence; a failure midway leaves a partial merge.
- The merge picker page title is the existing "Add to person" string.
- `showAddToPersonOption()` in `lib/models/gallery_type.dart` is false for device-folder galleries, so "Add to person" is missing there.
- PNG to JPG cannot save outside `DCIM/` and `Pictures/` (MediaStore rule); such files are reported as failed and kept. A converted file is a new MediaStore asset: its faces are re-indexed, and manual face corrections and photo-review decisions for it are lost.
- Exact duplicates hides upstream "large files" and "delete suggestions" (both need an account).
- About 20 files still open web links (`WebPage(`, `launchUrl`); they fail without `INTERNET`. The removal covers them.
- Without `INTERNET`, Android refuses all sockets, loopback included. A plugin that uses a localhost server (possibly video playback) would fail; not checked yet.

## History of this fork (for context)

1. Research showed upstream local gallery mode already detects and clusters faces but hides naming and merging behind sign-up banners, stores persons as encrypted server entities, and downloads models at run time.
2. Built in parallel by subagents: bundled models, local persons service layer, People UI, offline startup and Android config, S25 tuning, exact duplicates, PNG to JPG.
3. Parallel analyzers and builds exhausted the 8 GB Mac; the one-heavy-tool rule came from that.
4. Baseline APK built after two false starts (missing NDK 27, `--no-pub`), installed and partly tested on the S25.

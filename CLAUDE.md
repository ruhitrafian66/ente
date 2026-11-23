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
- JDK 21: `/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home`. Android SDK: `/opt/homebrew/share/android-commandlinetools` (NDK 28.2.13676358).
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

# Build (release, debug-signed when no keystore is configured)
~/development/flutter/bin/flutter build apk --release --flavor fdroid --dart-define=cronetHttpNoPlay=true
# -> build/app/outputs/flutter-apk/app-fdroid-release.apk
```

- Flavor `fdroid` is the only one that builds: its applicationId is `io.ente.photos.offline`, label "Ente Offline". Keep `namespace "io.ente.photos"` (Dart refers to Kotlin classes by that name).
- `analysis_options` treats lints such as import ordering as errors. `dart fix --apply lib` fixes most of them.
- A device is usually connected over adb. It holds the owner's real photo library: never run a delete or a PNG conversion on it without an explicit request. Check the merged manifest after a build: `aapt2 dump permissions <apk>` must show no `INTERNET`.

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
- Planned second step, not started: SCRFD-10G detector + ArcFace R50 (`w600k_r50`, 512-d) behind a build option. Needs DB schema, vector index and cluster threshold changes.
- Full removal of network and account code was chosen over keeping it switched off. Follow `mobile/apps/photos/docs/offline-fork-removal-plan.md` stage by stage; `flutter analyze` must be clean after each stage. Keep the `EnteFile` fields and the `FilesDB` schema and migrations untouched.
- Local checkpoint commits are fine. Never push unless asked.
- No APK build was to be made before the removal is done; device runs for testing are wanted.

## Status (update this section as work lands)

- Done and analyzer-clean (2026-11-23): offline startup, bundled models, local persons service layer, People UI enablement, person merge, S25 tuning, exact duplicates, PNG to JPG. Unit tests for the two tools and `test/services/machine_learning` pass.
- NOT yet verified on a device: everything above. No APK has been built. The Android-only Rust change (XNNPACK threads) and the Gradle changes have never been compiled.
- Next: baseline run on the S25, then removal stages 0 to 7.

## Known gaps

- People pickers use `getAllFace(minClusterSize: ...)`; small named persons may be missing from the merge picker.
- A multi-person merge runs in sequence; a failure midway leaves a partial merge.
- PNG to JPG cannot save outside `DCIM/` and `Pictures/` (MediaStore rule); such files are reported as failed and kept.
- About 20 files still open web links (`WebPage(`, `launchUrl`); they fail without `INTERNET`. The removal covers them.

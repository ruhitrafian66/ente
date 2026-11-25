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

Deleted from the fork: `web/ server/ desktop/ cli/ docs/ apple/ android/ architecture/`, most of `infra/`, `mobile/apps/auth`, `mobile/apps/locker` and the shared packages the app does not use. Unused Rust crates, apps and bindings are deleted too.

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

# Regenerate the Rust bridge (about 1 to 2 min now; exits 1 at the end because rustfmt is missing: harmless). Output: lib/src/rust and rust/bindings/frb/photos/src/frb_generated.rs (both git-ignored: a clean checkout needs this step)
(cd ../../../rust && PATH="$HOME/.cargo/bin:$HOME/development/flutter/bin:$PATH" cargo codegen frb photos)

# Gates
~/development/flutter/bin/flutter analyze --no-pub          # must print "No issues found!"
~/development/flutter/bin/flutter test --no-pub test/services

# Build (release, debug-signed when no keystore is configured). arm64 only.
~/development/flutter/bin/flutter build apk --release --flavor fdroid \
  --target-platform android-arm64
# -> build/app/outputs/flutter-apk/app-fdroid-release.apk (about 177 MB)
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

- `lib/offline_fork.dart` holds the fork's constants (ML switches and tuning). Since removal stage 4.2 there is no `kOfflineFork` or `isLocalGalleryMode` any more: the local path is the only path. Remaining deviations are marked with a comment starting `Offline fork:`.
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
- Person folder sort (requested 2026-11-24, in progress): a toggle, off by default, that MOVES images into `Pictures/People/<name>/`. Owner's choices: move, not copy; named persons only; images from all folders that Android lets the app move; a photo with several named persons goes to the folder of the largest face. Every move is recorded so "Restore all" can undo it. Since 2026-11-25 (owner reported "the app is skipping videos") videos move too: the device list uses `RequestType.common`, and a video from `Movies/...` returns to `Movies/...` on restore (`isVideo` in the planner). The video move is NOT yet verified on a device. Code: `lib/services/person_folders/`, `lib/db/person_folders_db.dart`, `lib/ui/tools/person_folders_page.dart`. Never run it on the owner's phone without an explicit request.
- Local checkpoint commits are fine at the agent's discretion. Never push unless asked.
- The owner said to wait with the final APK until the removal is done. Test builds for the phone are wanted and were made.
- For complex subagent tasks use Fable 5.2 at medium or high effort. Start subagents one after the other on this Mac, and tell them not to run analyzer, tests, Gradle or cargo.
- Text to the owner follows their Simplified Technical English rule (see their global CLAUDE.md).

## Status (update this section as work lands)

Last update: 2026-11-24.

Removal progress: stage 0 (`1249d3c`), stage 1 (`ef81248`, account-era feature leaves, 67k lines deleted) and stage 2 (data plane: upload, remote sync, download, streaming, server trash) are done; `lib/` is analyzer-clean and the unit tests pass after each. Stage 3 (collections: `CollectionsService`, favourites, hidden, archive, smart albums, the Albums home-screen widget and all server album UI are deleted; the Albums tab shows device folders only) is done. Stage 4.1 (`d3e9622`: the remote flag service is gone; values are constants in `lib/offline_fork.dart`, for example `kOfflineRustMlDb`, `kOfflineRemoteMlConsent`, `kOfflineEnableVectorDb`, `kOfflineManualTagFileToPerson`; photo review, memory video export, video speed page and debug settings were internal-user only and are deleted) and stage 4.2 (`acf1348`: `isLocalGalleryMode`, `kOfflineFork`, `AppMode` and the account conditions are deleted everywhere; `GrantPermissionsWidget` has no parameter; the location-tag menu is now visible on the location screen) are done. Stage 4.3 to 4.7 (`2aa268e`: `Configuration` is about 130 lines and no longer touches secure storage; `lib/core/network`, `lib/gateways`, Sentry and every web link are deleted; `EntityService` is local only; `EntityType` lives in `lib/models/entity_type.dart`; CLIP callers are off when `kOfflineRunClip` is false; `lib/utils/log_export_util.dart` plus About > "Export logs" replace the support e-mail flow) is done. Stages 5 and 6 (`c62adde`: `mobile/apps/auth`, `mobile/apps/locker`, `plugins/ente_cast` and 20 shared packages deleted; 39 dependencies removed; 13 packages remain: backup_exclusion, ente_components, ente_crypto_api, ente_icons, ente_pure_utils, ente_qr, frb, local_auth_linux, lock_screen, native_video_editor, screen_cover, strings, ui; manifest has no camera / network permission, no Albums widget, no picker or share target; only the `fdroid` flavor exists) are done. Log export uses the share sheet (`0221e44`); `file_saver` and `dio` are gone. Stage 7 (`c28bdca`: Rust workspace from 48 to 11 members: `bindings/frb/{log,photos}`, `crates/{assets,core,exif,image,location,ml,photos,vecdb}`, `tools/codegen`; the shared bridge lib `ente_frb_lib` and `mobile/packages/frb` are deleted; bridge regenerated) is done. All removal stages are done. Not done (optional R3): the HTTP stack (`reqwest`, `hyper`, `rustls`) is still linked into the native library through `rust/crates/assets/src/download.rs`, which also holds the path that accepts the bundled models; gating it behind a cargo feature is estimated at 2 to 4 hours in `ente-assets` only. `rust/Cargo.toml` pins `flate2` with `zlib-rs` so the image decode stack keeps its inflate backend. `mobile/apps/photos/ios` is unused and still present. Stale references to deleted things remain in `.github/workflows/{mobile-lint,warm-caches,pr-approval}.yml`, `README.md`, `mobile/apps/photos/docs/`, `android/permissions.md`. The phone check after the removal is done (see below). Still tell the owner before each install and wait for the reply.

Phone check after the removal (2026-11-24, S25, release build with the log option): passed. Note: the app was not installed in the main profile (user 0) any more; the owner's copy with the face index lives in the Secure Folder (user 150), which adb cannot open. `adb install -r` installs for both users, so the check ran on a new, empty copy in the main profile, and the Secure Folder copy was updated in place (not checked by the agent). Verified: first start (permission screen, gallery), Albums tab (device folders), Search tab, index counter ("889 out of 2,243", so the counter fix works), both models load with WebGPU, indexing at about 3 files per second, one photo, one video (playback works without `ACCESS_NETWORK_STATE`), file menu and details sheet, Settings, About > Export logs (share sheet opens with the zip), Trash, Exact duplicates (4 groups), PNG to JPG (162 PNGs), Person folders page, device cache page, ML page, Security page, memories strip. Not exercised: Delete, Convert, merge, folder sort, app lock PIN after update, home-screen widgets, People naming (index was not complete; the owner switched ML off during the check). Three defects found and fixed: (1) on the first start the index run started before the first local sync and found 0 files (`grant_permissions_widget.dart` now runs it again after the sync); (2) after the removal nothing created `ComputeController` in the foreground before the first touch, so indexing did not start on its own (`MLService.init` now creates it 5 s after the start); (3) the viewer tried to download OCR models (`kOfflineRunOcr = false` in `offline_fork.dart` makes no file eligible). Cosmetic leftovers: device cache page still lists "Remote images", "Remote thumbnails", "Pending sync"; the ML page text mentions bandwidth; `uiautomator dump` fails often while the app indexes (use screenshots).

Method that worked for stages 1 and 2: write one shared brief, give 4 or 5 workers disjoint ownership sets (one worker owns all hub files), workers only strip references and never delete kill-list files, workers verify through a serialised analyzer wrapper (a `mkdir` lock around `flutter analyze --no-pub <paths>`), then the integrator deletes the kill list, runs `dart fix --apply lib`, the analyzer and the tests, and fixes cross-worker leftovers.

Analyzer caveat: `analysis_options.yaml` excludes `test/**`, so `flutter analyze` (and `flutter analyze test`) reports "No issues found" for tests. Pass the test FILES explicitly: `flutter analyze --no-pub $(find test integration_test -name "*.dart")`. Ignore the `directives_ordering` lints there; they exist upstream.

Known test state: all unit tests pass except `test/services/memories/photo_selector_test.dart` and `smart_memories_source_selection_test.dart`, which fail in setUpAll because they need a host build of the Rust library (`ENTE_PHOTOS_FRB_LIBRARY`).

Person folder sort: implemented and connected (init in `main.dart` foreground only, re-sort hook after "ML finished running" in `ml_service.dart`, entry "Person folders" on the Free up space screen). 66 planner tests pass. NOT run on a device. It uses `PhotoManager.editor.android.moveAssetsToPath` (a MediaStore `RELATIVE_PATH` update, so the MediaStore ID and all face data should survive; verify on one file first with `adb shell content query --uri content://media/external/images/media --projection _id:relative_path --where "_id=<id>"`). Owner's decision (2026-11-24): images outside `DCIM/` and `Pictures/` are sorted too. Android cannot move them back to their source, so their recorded original folder is `Pictures/<last part of the source folder>` (`restoreFolderForPersonFolderSource`; `Download` becomes `Pictures/Download`, a nameless source becomes `Pictures/Restored`). The removal must keep `LocalSyncService.syncAll()`; the tool calls it after moves.

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
- Video viewer: when the device file is missing, the native player now shows an endless spinner (the server fallback and its error dialog are gone). The MediaKit player still has a hard-coded GitHub fallback URL. `lib/ui/tools/similar_images_page.dart` can delete nothing in the fork. Rewind needs a downloaded asset pack and is unavailable. `magic_util.dart` keeps four failing stubs (edit time, file name, caption, visibility) whose callers should be removed. Help & Support is gone, and with it the only UI entry to export or view logs.
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
- Stage 3 leftovers for stage 4: `SelectedAlbums` (`home_bottom_nav_bar.dart`, `home_widget.dart`), `isInSharedCollectionNotifier` (`lib/states/detail_page_state.dart`), unused `FileSelectionOverlayBar.collection`, `ThumbnailWidget.shouldShowFavoriteIcon` (no-op), `DetailPageConfiguration.galleryType`, `hiddenCollectionID` in `hierarchical_search_gallery.dart` / `hierarchical_search_util.dart`, `SearchService.getHiddenFiles()` (always empty) callers, `CollectionMetaEvent` listener in `large_files_page.dart`, the `Collection` model with `user.dart` and `public_url.dart`, dead `FilesDB` collection queries. `hooks/album_actions_sheet.dart` and `hooks/album_sort_sheet.dart` are used by People, location and magic galleries: keep. The location tag menu (edit / delete location) in `gallery_app_bar_widget.dart` is behind `hasConfiguredAccount()`: decide show or delete, do not collapse blindly. Share-to-app and the external media picker (`external_media_picker_page.dart`, loads uploaded files only) do nothing useful now. Stage 6 must remove `EnteAlbumsWidgetProvider` (manifest receiver and Kotlin class).
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

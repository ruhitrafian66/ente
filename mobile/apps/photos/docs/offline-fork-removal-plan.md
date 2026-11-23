# Full-removal plan for the offline fork (mobile/apps/photos)

## Read this first

- **Scope is large but tractable.** A regex import-graph over `lib/` (1,204 Dart files, ~300K LOC) shows that cutting a seed kill-set of 273 files (72K LOC) makes 322 files (78K LOC) unreachable from `lib/main.dart`. 157 surviving files import something in that set and need edits.
- **Nothing is unreachable today.** Only 22 files are currently unreachable from `main.dart`; every deletion needs survivor edits first. So the plan is "strip references in parallel, then one integrator deletes".
- **Four things would silently break runtime if done naively:**
  1. `lib/module/download/file.dart` and `thumbnail.dart` look like remote code but hold the local file and thumbnail access (`getFile`, `getThumbnail`, `getThumbnailFromLocal`, `cachedFaceCropPath`). 27 and 16 survivors import them. Slim them; do not delete.
  2. `lib/ui/settings/backup/free_space_options.dart` hosts the new tools (`ExactDuplicatesPage` at :106, `PngToJpgPage` at :115) plus trash and photo review. It sits in a directory that otherwise goes.
  3. `FlagService` values decide ML behaviour. `main.dart:337` and `:522` call `MLDataDB.initialize(preferRust: flagService.rustMlDb)`, and `rustMlDb => internalUser`, which is false in release and true in debug. Replacing it with different constants switches the ML DB backend, which would orphan the face index.
  4. `FilesDB` hosts the `device_files`, `device_collections` and `entities` tables (`files_db.dart:338`, `:345`, `:368`). Persons live in `entities`.
- **Likely existing bug, not verified by running:** `configuration.dart:143` calls `_secureStorage.deleteAll()` whenever the token is null, which is every start in this fork, including WorkManager starts (`main.dart:346`). `LockScreenSettings` keeps the PIN, password and salt in `const FlutterSecureStorage()` (`lock_screen_settings.dart:64`). Configuration's instance only sets `iOptions`, so on Android both should hit the same store. If so, a PIN or password lock is wiped on every cold start. Fix it when slimming `Configuration`.
- **Dropping `dio` and `sentry` from the app pubspec does not unlink them.** `ente_lock_screen` → `ente_accounts` → `ente_network` → `cronet_http` (present in `mobile/pubspec.lock`), and `ente_ui` → `ente_logging` → `sentry_flutter`. Shared packages must be edited too (stage 5).
- **My recommendation on the schema question: confirm your lean.** Keep the `EnteFile` fields and the `FilesDB` schema and remove only behaviour (details in section 4a).

The repo is a git work tree with about 3,868 staged changes. If you want a checkpoint commit per stage, the owner has to ask for it; I did not commit anything.

---

## 1. Dependency map

### 1.1 Clusters to delete

Survivor counts are files outside the kill-set that import the cluster.

| Cluster | Paths | Size | Who in surviving code depends on it |
|---|---|---|---|
| API gateways | `lib/gateways/**` | 31 files, 2.5K LOC | `service_locator.dart` (14 getters); `entity_service.dart` (gateway plus models); 5 survivors import `gateways/entity/models/type.dart`; `configuration.dart` imports `users/models/key_attributes.dart` |
| Network core | `lib/core/network/**`, `core/error-reporting/tunneled_transport.dart` | 5 files, ~630 LOC | `main.dart:328`, `:508` (`NetworkClient.init`); `service_locator.dart:73-79` (three `Dio` fields); `super_logging.dart` |
| Account / auth / 2FA / passkey / recovery | `lib/ui/account` (17 files, 4.6K), `lib/services/account` (4, 1.4K), `ui/settings/account`, `lib/emergency` (8, 1.8K), `services/legacy.dart`, `authenticated_session.dart`, `notification_key_service.dart`, `states/user_details_state.dart` | ~35 files | `main.dart:185`, `:373`, `:547` (`UserService`); `home_widget.dart`; `settings_page.dart:93`, `:112`, `:272`, `:333`; `security_settings_page.dart` (2FA, `deriveLoginKey`); `email_entry_page.dart` has 5 survivor importers |
| Billing / storage / growth / family | `ui/payment` (11, 2.1K), `ui/growth` (5), `ui/family` (5, 2.5K), `storage_bonus_service.dart`, `family_service.dart`, `ui/settings/storage_*` | ~28 files | `service_locator.dart`; `settings_page.dart:372`; `sync_service.dart:62` (`SubscriptionPurchasedEvent`); `subscription.dart` has 5 survivor importers |
| Upload | `lib/module/upload/**` | 15 files, 3.3K | `main.dart:366`, `:575` (`FileUploader.init`); `:367`, `:572` (`LocalFileUpdateService`); `sync_service.dart:34`, `:221-231`; `configuration.dart` (`upload_artifact.dart`); 7 survivors import `file_uploader.dart` |
| Remote sync | `services/sync/remote_sync_service.dart` (1,201), `diff_fetcher.dart`, `trash_sync_service.dart`, `large_backup_session_tracker.dart`, `db/upload_locks_db.dart`, `db/trash_db.dart` | 6 files, ~2.9K | 13 survivors import `RemoteSyncService` (`sync`, `isFirstRemoteSyncDone`, `whiteListVideosForUpload`, `updateDeviceFolderSyncStatus`); `home_widget.dart:156` (`DiffFetcher`); `trash_page.dart` |
| Download / cache / streaming | `module/download/{manager,decrypt,gallery,gallery_download_queue_service,progressive_video_stream,task,file_url,download_error}.dart`, `services/filedata/**`, `video_preview_service.dart`, `ui/settings/streaming`, `db/gallery_downloads_db.dart`, `remote_assets_service.dart` | ~20 files, ~4.5K | 11 survivors import `VideoPreviewService`; `file.dart` imports `file_url.dart` at line 10; `main.dart:596` |
| Sharing / public links / library sharing / memory share | `ui/sharing` (26, 6K), `ui/tabs/shared`, `library_sharing_*.dart`, `memory_share_service.dart`, `db/memory_shares_db.dart`, `models/api/**` | ~40 files | `user_avatar_widget.dart` (7 survivors); `models/api/collection/user.dart` (8); `collection_sharing_actions.dart` (imports 7 killed files); `main.dart:360`, `:544` |
| Social feed / comments | `ui/social` (19, 6.9K), `social_*.dart`, `db/social_db.dart` (770), `models/social` (10, 1.9K) | ~35 files | `main.dart:374`, `:553`; `home_widget.dart:158` (feed tab is already off in local mode); `file_social_overlay.dart` (2) |
| Cast | `ui/cast`, `ui/settings/cast`, `auto_cast_service.dart`, `plugins/ente_cast` | 6 files plus plugin | `service_locator.dart:103-119`; `settings_page.dart:431` |
| Contacts | `services/contacts/**`, `contacts.dart`, `photos_contacts_service.dart` | 5 files | 8 survivors, including `person_service.dart`, `contact_result_page.dart`, `edit_contact_page.dart`, `main.dart:639` |
| Rituals | `ui/rituals` (11, 7K), `services/rituals`, `models/rituals` | 13 files, 7.9K | `main.dart:601`. Album-based (`rituals_service.dart:179`, `:268` use collections), so no local value. Holds the only `package:camera` import. |
| Map | `ui/map` (11, 1.7K) | 11 files | `location_tags_widget.dart`, `update_location_data_widget.dart`, `gallery_app_bar_widget.dart:1353`, `search_map_navigation.dart`. Tiles come from `tile.openstreetmap.org` (`ui/map/tile/layers.dart:46`) and the fork already defaults the map off (`local_settings.dart:361`). No offline value: remove. |
| Server tools / update / push | `deduplication_service.dart`, `ui/tools/deduplicate_page.dart`, `free_space_page.dart`, `files_service.dart`, `file_magic_service.dart`, `update_service.dart`, `ui/notification/update`, `ui/settings/app_update_sheet.dart`, `push_service.dart`, `memories/memory_music_service.dart` | ~15 files | `free_space_options.dart:188`, `:216`, `:247`; `home_widget.dart:318`, `:325`; `main.dart:216`, `:381`, `:610` |
| Collections (second wave) | `collections_service.dart` (2,774), `favorites_service.dart`, `hidden_service.dart`, `smart_albums_service.dart`, `db/collections_db.dart`, `ui/collections/album`, `collection_list_page.dart`, `collection_action_sheet.dart`, `ui/actions/collection/*`, gallery pages (`collection_page`, `archive_page`, `hidden_page`, `uncategorized_page`, `shared_public_collection_page`, `delete_suggestions_page`, `cleanup_hidden_*`) | ~45 files, ~12K | **62 survivors import `CollectionsService`**, about 60 distinct methods; most used are `getCollectionByID` (24 calls in 16 files), `getHiddenCollectionIds` (9 in 7), `archivedOrHiddenCollectionIds` (8 in 5) |

### 1.2 Load-bearing account-era classes

| Class / file | Verdict | Evidence of local use | Slim to |
|---|---|---|---|
| `Configuration` (555 LOC, 280 uses in 125 files) | Keep, slim to ~120 LOC | `main.dart:346`, `:530` (init); `:182`, `:536` (`LockScreenHost`); `local_sync_service.dart:102`, `:211` (`getUserIDV2`); survivors call `getTempDirectory` (3 files), `getSharedMediaDirectory`, `getThumbnailCacheDirectory`, `getPersonFaceThumbnailCacheDirectory` | Directory creation (`configuration.dart:98-117`), `excludeFromBackup`, stale-temp cleanup, the four directory getters, `getUserID() => null`, `isLoggedIn() => false`, a no-op `logout()`. Remove token, key, secure-storage and logout fan-out code, the 15 killed imports, `AccountDeletionHost`. |
| `getUserIDV2` (`core/user_config.dart`) | Keep | Returns -1 in local mode; `files_db.dart:1026-1033` filters `owner_id IS NULL OR owner_id = ?` | Unchanged. Do not change -1 or null: `isOwner` (`file_props.dart:27`) depends on `getUserID()` staying null. |
| `FilesDB` (2,427 LOC, 79 async methods) | Keep, schema untouched | `local_sync_service.dart` (`getExistingLocalFileIDs`, `insertMultiple`, path mappings, `updateDeviceCoverWithCount`); `gallery_app_bar_widget.dart:1273` | Leave the migration list (`files_db.dart:81`) byte-identical. Method pruning is optional and last. |
| `EnteFile` fields | Keep all | `mlFileID` (`file_props.dart:17`) is the only mode-aware accessor; `uploadedFileID` appears 684 times in 115 files | Only collapse `mlFileID` to the offline branch. |
| `OfflineFilesDB`, `db/ml/**`, `MLDataDB.localGalleryInstance` | Keep | `main.dart:340`, `:521`; `search_service.dart:1329` | Untouched |
| `SyncService` (298 LOC) | Keep, slim to ~90 LOC | `sync_service.dart:239-258` is the whole local path; `main.dart:724` | `init`, `sync`, `_doSync` (local only), `isSyncInProgress`, `onPermissionGranted`, status events. Remove the listeners at `:62-102`, the Dio catch block, uploader hooks at `:221-231`. Keep firing `SyncStatusUpdate` and `SyncFinishedEvent`; `home_widget.dart:297` listens. |
| `LocalSyncService` (520), `OfflineImportMetadataService`, `services/sync/import/*`, `album_refresh_coordinator.dart` | Keep | Core importer | Collapse the 6 mode branches (`:71`, `:144`, `:147`, `:194`, `:202`, `:339`). |
| `FileUploader` | Delete | Only `init` at `main.dart:366`, `:575` and queue pruning in `SyncService` | — |
| `LocalFileUpdateService` | Delete after reading it | `main.dart:367`, `:572`. I did not read the body. | Confirm it only schedules re-uploads and has no local metadata side effects. |
| `RemoteSyncService` | Delete | No functional local use | `isFirstRemoteSyncDone()` callers must take the "done" path; verify each of the 3. |
| `NetworkClient`, `EndpointConfig`, the three `Dio` fields | Delete | `main.dart:328`, `:508`; `service_locator.dart:59-84` | `ServiceLocator.init(prefs, packageInfo)` |
| `UserService` | Delete | `main.dart:185`, `:373`, `:547` | Lock-screen `onLogout` becomes a no-op. |
| `FlagService` (`packages/feature_flag`) | Replace with a local constants class in `lib/` | 146 uses in 66 files | See section 4c-flags. |
| `hasGrantedMLConsent`, `setMLConsent`, `mapEnabled` | Keep local branch | `service_locator.dart:138-168` | Read `localSettings` directly. |
| `BackupPreferenceService` | Keep, slim | `local_sync_service.dart:152`, `:183`, `:347`; `hasSelectedAllFoldersForBackup` and `hasSkippedOnboardingPermission` are used in 3 survivors each | Keep the getters and setters survivors call; the first-import bypass logic depends on them. |
| `EntityService` (292) | Keep, slim to ~80 LOC | Local branch at `entity_service.dart:69-81`, `:126`, `:131`, `:142` | Remove the gateway, entity keys and encryption. Move `EntityType` and friends out of `lib/gateways/entity/models/` into `lib/models/`. |
| `PersonService`, `SearchService` | Keep | Core | Remove contacts linking (`person_service.dart` imports `package:ente_contacts`) and the collection search methods (`search_service.dart:534`, `:566`). Collapse `:1323` (`isLocalGalleryMode && !kOfflineFork` is dead). |
| `MLModelDownloadService` | Keep, slim | `ml_model_download_service.dart:97-103` installs the bundled models | Remove the connectivity retry and download paths. |
| `module/download/file.dart` (346), `thumbnail.dart` (487) | Keep at the same path, slim | Local helpers listed above | Remove `getFileFromServer`, `_downloadAndCache`, `_getLivePhotoFromServer`, the thumbnail download queue, and the `file_url.dart` import in `models/file/file.dart:10`. |
| `ente_crypto` plugin and `flutter_sodium` | Keep | `photos_crypto_api_adapter.dart` (PIN and password hashing); `main.dart:355`, `:505` | After stage 4 the only `CryptoUtil` users left should be the adapter and `main.dart`. |
| `ente_lock_screen` | Keep, edit | `main.dart:175-205`, `:535` | Remove the `ente_accounts` import (`lock_screen.dart:5`, `:204`); use `LockScreenHost.logout()`. |
| `CollectionsService`, `FavoritesService`, `HiddenService`, `CollectionsDB` | Delete in stage 3 | See section 4b | — |
| Trash | Keep device trash; delete `TrashDB`, `TrashSyncService`, `EnteTrashFile` | `trash_page.dart:61`, `:68`; `delete_file_util.dart:929` | Collapse `_isOnEnteTrash` to false. |
| Home-screen widgets | Memories: keep. Albums: collection-only, so dead in local mode (`album_home_widget_service.dart:192-251`). People: currently returns early in local mode (`people_home_widget_service.dart:220`). | | Decision for you: remove the Albums widget (service, `albums_widget_settings.dart`, `EnteAlbumsWidgetProvider.kt`, manifest receiver at lines 238-244) or leave it inert. Enabling the People widget belongs to the People UI task. |

---

## 2. Staged sequence

### Working method for every stage

1. **Parallel:** workers own disjoint sets of surviving files and remove every reference to that stage's kill-list. The tree compiles throughout because the targets still exist.
2. **Sequential:** one integrator re-runs the import check for zero inbound edges, deletes the directories and their tests in the same change (`flutter analyze` covers `test/`), then runs `flutter analyze` and `flutter test`.
3. **Let the analyzer enumerate.** Dart flow analysis does not flag branches guarded by a `const` (the tree is clean today with 102 `if (!kOfflineFork)` sites). To collapse flags, delete the symbol and fix every error.
4. **Hub files have one owner per stage:** `main.dart`, `service_locator.dart`, `core/configuration.dart`, `ui/tabs/home_widget.dart`, `ui/settings_page.dart`, `services/sync/sync_service.dart`, `ui/viewer/gallery/gallery_app_bar_widget.dart`, `ui/settings/search/settings_search_registry.dart`. Together they hold about 100 of the cut edges.

**Collapse rules** (three kinds of branch exist):
- `isLocalGalleryMode` → true.
- `kOfflineFork` → true.
- `isLocalGalleryMode && !kOfflineFork` → dead. Found at `search_service.dart:1323`; `settings_page.dart:70` is the same shape.
- `Configuration.instance.hasConfiguredAccount()` and `isLoggedIn()` → false; `getUserID()` → null.
- Leave `file.isUploaded` and `uploadedFileID != null` checks alone unless the branch references deleted code.

### Stage 0 — Baseline (sequential, half a day)

- Wait for the concurrent tasks (People UI, startup and manifest, ML tuning, tools) to land, or freeze their files.
- Record `flutter analyze` and `flutter test` results.
- Record current local-mode flag values (section 4c-flags) as a comment block for stage 4.
- Move the tools host out of the kill zone: `ui/settings/backup/free_space_options.dart` → for example `ui/settings/free_space_options.dart`. Update `settings_page.dart:387` and the search registry.

### Stage 1 — Account-era feature leaves (~170 files deleted, ~75 edited)

**Delete:**
- `lib/ui/{account,payment,sharing,social,cast,family,growth,rituals,map}`
- `lib/ui/settings/{account,cast,streaming,pending_sync,support}`, `ui/settings/backup/*` except the moved tools page
- `ui/notification/update`, `ui/tabs/shared`, `lib/emergency`
- `ui/settings/{app_update_sheet,storage_card_widget,storage_progress_widget,hide_shared_items_setting}.dart`, `ui/home/landing_page_widget.dart`, `ui/settings/debug/social_debug_screen.dart`
- `services/{rituals,contacts}/`, `models/{social,rituals,library_sharing}`, `models/api/memory_share`
- Services: `social_*`, `storage_bonus_service`, `family_service`, `library_sharing_*`, `memory_share_service`, `auto_cast_service`, `update_service`, `push_service`, `legacy`, `contacts`, `photos_contacts_service`, `deduplication_service`, `memories/memory_music_service`, `account/{billing_service,purchase_update_listener,passkey_service}`
- `db/{social_db,memory_shares_db}.dart`, `ui/tools/{deduplicate_page,free_space_page}.dart`
- Matching gateways (billing, cast, push, social, storage_bonus), `fdroid/overlay/`
- About 15 events become dead by cascade.

**Survivor edits:**
- `main.dart`: remove `configureStoreKit` (:119), `MemoryShareService.init` (:360, :544), `SocialNotificationCoordinator` (:374, :553), the update notification (:379-382), library sharing (:590), rituals (:601), push (:609-613, :802-839), the contacts warm-up (:622-643), memory music and install source (:215-222), the `!isLocalGalleryMode` person-sync block (:392-414).
- `service_locator.dart`: remove about 14 getters.
- `home_widget.dart`: deep links, public album link (:411), changelog (:1310), the landing branch (:1082-1090), `_getCredentials` (:1296), the missing-recovery-key handler.
- `settings_page.dart`: every `hasLoggedIn && !isLocalGalleryMode` block (:105, :145, :171, :181) and the routes at :93, :112, :120, :272, :333, :372, :422, :431.
- `security_settings_page.dart`: keep only the app-lock section.
- `gallery_app_bar_widget.dart`: 10 killed imports (share, cast, map at :1353).
- `ui/actions/collection/collection_sharing_actions.dart`: delete the sharing parts; the rest goes in stage 3.
- `file_app_bar.dart`, `detail_page.dart`, `full_screen_memory.dart`, `special_memory_chrome.dart`: social overlay, memory share, music.
- `person_service.dart`, `contact_result_page.dart`, `edit_contact_page.dart`, `contact_avatar_widget.dart`, `search_tab/contacts_section.dart`: contacts.
- `location_tags_widget.dart`, `update_location_data_widget.dart`, `search_map_navigation.dart`: map.
- `free_space_options.dart`: delete the `!kOfflineFork` block (:61) and `_free*`/deduplicate handlers (:188-266).
- `just_audio_memory_music_player.dart`, `memory_music_selector.dart`: delete with memory music unless the tracks are bundled. I did not check the assets.

**Tests to delete (about 30):** `test/ui/{account,cast,family,payment,sharing}/**`, `test/db/social_db_test.dart`, `test/models/social/**`, `test/models/ml/face/person_contact_link_test.dart`, `test/services/{auto_cast_service,library_sharing_service,library_sharing_store,photos_contacts_service,rituals_service}_test.dart`, `test/services/contacts/**`. Update `test/ui/settings/security/security_settings_page_test.dart`.

**Runtime risks to read for:**
- `home_widget.dart` holds about 15 `StreamSubscription`s; remove each one's `cancel()` in `dispose` with its creation.
- Removing `UserDetailsStateWidget` (wraps the scaffold at `home_widget.dart:896`): grep `InheritedUserDetails.of` in survivors (`header_widget.dart`, `status_bar_widget.dart`), or a null check will fail at runtime.
- `main.dart`: `PersonService.init` (:585) must still come before `refreshPersonCache` (:617) and `smartAlbumsService` use (:451-454). Keep the relative order of every remaining line.
- `settings_search_registry.dart` (840 LOC) builds routes from closures; a stale entry is a compile error only if the page class is gone, so audit entries for pages that survive but are now empty.

**Parallel split, 5 workers:** (A) hubs; (B) `ui/viewer/file/**` and `file_details/**`; (C) `ui/viewer/{gallery,search,search_tab,people,actions}/**` except the app bar; (D) `ui/home/**`, `services/memories/**`, `services/rewind/**`, `ui/rewind/**`; (E) `services/machine_learning/**`, `utils/**`, `models/**`, `db/**`, remaining `ui/settings/**`.

### Stage 2 — Data plane: upload, remote sync, download, streaming, server trash (~60 deleted, ~55 edited)

**Delete:**
- `lib/module/upload/**`
- `module/download/*` except `file.dart` and `thumbnail.dart`
- `module/live_photo/{download,upload}.dart` (keep `archive.dart` only if a survivor still imports it)
- `services/filedata/**`, `video_preview_service.dart`, `remote_assets_service.dart`, `files_service.dart`, `file_magic_service.dart`
- `services/sync/{remote_sync_service,diff_fetcher,trash_sync_service,large_backup_session_tracker}.dart`
- `db/{upload_locks_db,trash_db,gallery_downloads_db}.dart`
- `models/backup/**`, `ui/home/{gallery_download_banner,large_backup_screen}.dart`, `ui/collections/shared_media_backup_sheet.dart`
- Gateways `files/` and `trash/`, `utils/{hls_playlist,file_key}.dart`, `core/cache/video_cache_manager.dart`

**Survivor edits:**
- `file.dart` and `thumbnail.dart` slimmed as in 1.2. Worker rule: for a file with `localID != null`, the returned value must be identical before and after.
- `sync_service.dart`, `local_sync_service.dart` slimmed as in 1.2.
- `main.dart`: remove :366-369, :572-583, :594-598 and "Video streaming enabled" from `logLocalSettings` (:694).
- Video widgets (`video_widget_native.dart`, `video_widget_media_kit.dart`, `video_widget.dart`), `zoomable_image.dart`, `zoomable_live_image_new.dart`, `thumbnail_widget.dart` (6 killed imports): remove playlist, stream, download-progress and upload-icon branches.
- `status_bar_widget.dart` and `header_widget.dart`: backup status goes; keep first-import progress.
- `delete_file_util.dart` (1,451 LOC): keep the path at :929 and device trash only.
- `trash_page.dart`, `file_bottom_bar.dart`, `gallery_groups.dart`, `file_props.dart:57-64`: `EnteTrashFile` out.
- `utils/{ml_util,dialog_util,device_storage_error,magic_util}.dart`, `memory_video_exporter.dart`, `rewind_video_export.dart`, `rewind_request.dart`, `memory_video_prefetcher.dart`, `face_thumbnail_cache.dart`, `panorama.dart`.
- `ml_service.dart`: `remoteSyncOnly` (`main.dart:437`) and filedata fetch.

**Tests:** delete `test/module/upload/**`, `test/module/download/download_error_test.dart`, `test/services/{video_preview_service,remote_assets_service}_test.dart`, `test/services/sync/backup_preparation_test.dart`. Update `ml_file_retrieval_test.dart`, `gallery_thumbnail_demand_test.dart`, `delete_file_util_test.dart`, `full_screen_memory_test.dart`.

**Runtime risks (highest-risk stage):**
- `isFirstRemoteSyncDone()` gates UI in 3 survivors. Read each and take the branch that shows the gallery.
- `home_widget.dart:1429` (`_shouldShowLoadingWidget`) and `:1436` (`hasCompletedFirstImportOrBypassed`): keep the first-import logic, including `backupPreferenceService` at `local_sync_service.dart:347`.
- `LocalSyncService._lock` exists to avoid racing downloads; keep it, since the importer also takes it.
- ML indexing fetches bytes through `ml_util.dart`. Confirm the offline path never falls back to a deleted server fetch for motion photos or live-photo video parts (`file.dart` imports `motionphoto`).
- Removing `VideoPreviewService` from `Configuration.logout` is fine; removing its `init` listeners must not remove the `FilesUpdatedEvent` consumers that the gallery uses.

**Parallel split, 4 workers:** (A) hubs, `services/sync/**`, `module/download/**`; (B) `ui/viewer/file/**`; (C) `ui/viewer/gallery/**`, `ui/home/**`, `utils/delete_file_util.dart`; (D) `services/**` (ML, memories, rewind) and remaining `utils/**`.

### Stage 3 — Collections (~45 deleted, ~70 edited)

**Step 3a (one worker, half a day):** replace `collections_service.dart` with a temporary stub of about 150 LOC that keeps only the signatures survivors call and returns what an empty DB returns today: empty sets and lists, null collections, and a `throw UnsupportedError` in mutators. The local-mode `CollectionsService.init` (`:105-129`) only loads an empty `CollectionsDB` and registers a cache listener. Step 3a also deletes `collections_db.dart`, the collections gateways and `models/api/collection`.

**Step 3b (parallel):** remove call sites and delete `favorites_service.dart`, `hidden_service.dart`, `smart_albums_service.dart`, `ui/collections/{album/**,collection_list_page,collection_action_sheet,flex_grid_view}.dart`, `ui/actions/collection/**`, the collection gallery pages listed in 1.1, `ui/tabs/albums/**` where Ente-only, `models/collection/{action,smart_album_config}.dart`, `utils/collection_util.dart`, and the Albums widget if you decide so. Then delete the stub.

- `albums_tab.dart`: keep only the device-folder slivers. Evidence that local mode is device-only: `:261`, `:318`, `:553`, `:970`, `:987`, `:1017`, `:1036`.
- Favorites: I found no local favourites implementation. `FavoritesService.isFavoriteCache` is called in 4 survivors and `favorite_widget.dart` survives; remove the control.
- `GalleryType` (`models/gallery_type.dart`): keep the enum values at first, or every `switch` breaks. Prune them last.

**Runtime risks:**
- Timeline filters use `getHiddenCollectionIds()` and `archivedOrHiddenCollectionIds()` (17 calls) to build `ignoredCollectionIDs` for `FilesDB`. Check that each query still produces valid SQL with an empty set.
- `file_props.dart:88` (`canReUpload`) and `:55` (`canEditMetaInfo`) reference collections.
- `SearchService._collectionService`, hierarchical search album filters (`hierarchical_search_util.dart`), and `rewind` or `memories` code that excludes hidden collections.

**Tests:** delete `collection_page_cover_test`, `album_cover_app_bar_test`, `album_selection_slideshow_test`, `empty_states_test`. Update `gallery_grid_zoom*`, `gallery_file_widget_test`, `gallery_viewer_return_test`.

**Parallel split, 4 workers** by directory as in stage 1; the stub owner is the integrator.

### Stage 4 — Core collapse (~40 deleted, ~110 edited, mostly mechanical)

Run the sub-steps in order; each ends analyze-clean.

1. **Flags.** Add a local constants class with the same getter names and the values recorded in stage 0. Point `flagService` at it. Remove the `ente_feature_flag` import.
2. **Mode symbols.** Delete `isLocalGalleryMode` (382 uses, 90 files), `kOfflineFork` (102 uses, 45 files), `AppMode`, `LocalSettings.appMode` and `setAppMode`, `AppModeChangedEvent`, `isFromLocalGalleryToEnte`. Keep the tuning constants in `offline_fork.dart`.
   - **Preserve pref keys.** `_mlLocalIndexingKey` (`local_settings.dart:370`), `_defaultMLLocalIndexingEnabled` (:374), `:416` and `localGalleryMLConsent` select mode-specific keys and defaults. Keep the exact local-gallery strings and defaults, or consent and indexing state reset on upgrade.
   - This step parallelises by directory: `services/memories/**` (about 130 branches), `services/machine_learning/**` and `db/ml/**`, `ui/viewer/**`, the rest.
3. **Configuration** slim as in 1.2, including removing `deleteAll` at :143. Delete `hasConfiguredAccount`, `getToken`, `getKey`, `getEmail`, `getKeyAttributes` and fix the errors (37 uses in 22 survivors; 14 in 12 for `getEmail`). Delete `services/account/user_service.dart`, `authenticated_session.dart`, `notification_key_service.dart`, `gateways/users`, and the `AccountDeletionSettings` call (`main.dart:542`).
4. **Network.** Delete `lib/core/network/**`. `ServiceLocator.init(prefs, packageInfo)`. Remove the Dio handling in `utils/dialog_util.dart` (11 references) and `sync_service.dart`. Delete `utils/network_util.dart` and the `Connectivity` listeners (`location_service.dart`, `full_screen_memory.dart`).
5. **Entity.** Slim `EntityService`; move models out of `lib/gateways/entity/models`; delete the rest of `lib/gateways`, `utils/gzip.dart` if unused, and `installSourceService`.
6. **Logging.** In `core/error-reporting/super_logging.dart` remove Sentry and the tunnel (55 `sentry` matches across 6 files). Delete `tunneled_transport.dart`. In `main.dart` remove the DSN parameters (:743-747) and `triggerSendLogs` (:472-482).
   - `utils/email_util.dart` (467 LOC, uses `ente_mail`, `file_saver`, `email_validator`): reduce to "export logs to a file" or delete. Your call.
7. **Webview.** Delete `ui/common/web_page.dart`. `services/review_service.dart` launches the store review; remove it and its callers (`free_space_options.dart:283`, `:334`).

**Runtime risks:**
- `super_logging.dart` wraps `runApp` in a zone. Keep `runZonedGuarded`, `FlutterError.onError` and the file-logging setup exactly; only remove the Sentry branches.
- `isolate_logging.dart` and `utils/isolate/super_isolate.dart:1` have a `kOfflineFork` branch; ML isolates depend on it.
- `main.dart` after this stage should read: Rust init → prefs → `ServiceLocator.init` → `OfflineFilesDB.refreshIntIdCache` → `MLDataDB.initialize` → `Configuration.init` → lock screen → `SearchService.init` → `LocalSyncService.init` → `PersonService.init` → `SyncService.init` → `MLService.init`. This is today's order with deletions only. `_runMinimally` must stay in step with `_init`.
- `LockScreenSettings.init(..., hasOptedForOfflineMode: isLocalGalleryMode)` (`main.dart:538`) → pass `true`.

**Tests:** update `test/settings/**`, `test/services/machine_learning/**`, `test/core/**`, `ml_consent_sheet_test.dart`, `device_picker_page_test.dart`.

### Stage 5 — pubspec, plugins, shared packages, workspace (sequential, one worker, ~1,750 files deleted, ~25 edited)

1. Remove now-unused dependencies from `apps/photos/pubspec.yaml` (list in 4d). Remove the `assets/subscription/` and `assets/rituals/` entries and directories. `flutter pub get`, analyze.
2. Edit shared packages so the transitive closure is clean:
   - `packages/lock_screen`: remove `ente_accounts` and `ente_configuration`. That drops `ente_network`, `cronet_http`, `native_dio_adapter`, `ua_client_hints`, `app_links`, `ente_events`.
   - `packages/ui`: remove `dio` from `utils/dialog_util.dart:3`, `:69-94` and the `ente_utils/email_util.dart` import; replace `ente_logging` in `text_input_widget.dart` and `log_file_viewer.dart` with `package:logging`, or strip Sentry from `packages/logging`.
   - `packages/utils`: used only for `platform_util.dart` (3 imports), which pulls `window_manager` and `url_launcher`. Inline the helpers and drop the dependency.
   - Photos still imports ente_ui components to drop: `app_update_sheet`, `subscription/*`, `settings/about_settings_section`, `app_engagement_section`, `more_from_ente_footer`.
3. Delete `mobile/apps/auth` (1,208 files), `mobile/apps/locker` (418), `plugins/ente_cast` (24), and packages `accounts`, `account_deletion`, `configuration`, `contacts`, `events`, `feature_flag`, `install_source`, `legacy`, `mail`, `network`, `qr`, `sharing`, `ente_crypto_dart_adapter`, `ente_pdf_renderer`, `ente_qr_scanner`, `scoped_dir_access`. Also `logging`, `utils`, `base`, `ente_screen_brightness` if step 2 removed their last users.
   - Keep: `backup_exclusion`, `ente_components`, `ente_crypto_api`, `ente_icons`, `ente_pure_utils`, `ente_qr` (local QR detection in the viewer, 3 survivors), `lock_screen`, `local_auth_linux`, `screen_cover`, `native_video_editor`, `strings`, `ui`. Also `frb` unless the stage 7 dependency check frees it.
   - Update `workspace:` in `mobile/pubspec.yaml` and remove unused `dependency_overrides`. Check `mobile/checks/frozen-pubspecs`.
4. Verify: `flutter pub deps` shows no `dio`, `sentry*`, `cronet_http`, `connectivity_plus`, `flutter_inappwebview*`, `multicast_dns`; `GeneratedPluginRegistrant.java` (294 lines today) regenerates without them.

### Stage 6 — Android leftovers (one worker, after the startup and manifest engineer is done)

`android/app/src/main/AndroidManifest.xml`:
- Remove the `ente://` VIEW filter (:37-42) and the `albums.ente.io` / `albums.ente.com` app-link filters (:53-68).
- Remove the SEND / SEND_MULTIPLE filters (:71-92) if `receive_sharing_intent` goes.
- Remove `CAMERA` (:4) and the `RECORD_AUDIO` remover (:8) once `camera` is gone.
- Remove `ACCESS_NETWORK_STATE` (:280). WorkManager constraints are already `NetworkType.notRequired` (`bg_task_utils.dart:298`, `:338`, `:382`). Also check `plugins/ente_background_manager`, whose manifest declares the same permission.
- Remove the Sentry and Firebase meta-data (:228-229).
- Keep the `INTERNET` and `BILLING` `tools:node="remove"` markers as a safety net.
- Remove the Albums widget receiver if decided.

Gradle and other files:
- `android/app/build.gradle`: remove the `google-services.json` block (:8), collapse flavors if only one is built (:95-115), and check `proguard-rules.pro` for Sentry and Firebase keep rules.
- Delete `android/app/src/{playstore,independent,dev}` if unused, `android/app/src/main/play`, `fdroid/`, `scripts/prepare_fdroid_source.sh`, and for an Android-only fork `mobile/apps/photos/ios` (108 files) and iOS scripts.

Gate: `flutter build apk --release`, then inspect the merged manifest and run `aapt dump permissions`.

### Stage 7 — Rust (one worker, independent of Dart after stage 5)

- **R1, no codegen, low risk.** In `rust/Cargo.toml`, reduce `members` from 48 to 17: `bindings/frb/{lib,log,photos}` and `crates/{accounts,assets,cast,collections,contacts,core,exif,image,legacy,live-photo,location,ml,photos,vecdb,test-support}`.
  - Delete `apps/` (110 files), `bindings/{napi,uniffi,wasm}` (72), `bindings/frb/{auth,locker}`, `crates/{auth,ensu,ensu-crypto,locker,paste,photobook,photos-export,space}`, `tools/`.
  - `crates/test-support` stays: `accounts`, `contacts`, `legacy` and `photos` name it in their manifests.
  - `bindings/frb/lib/Cargo.toml` has an optional `ente-locker` dependency. My understanding is that Cargo needs optional path dependencies to exist, so remove the `locker` feature, the dependency and `src/locker.rs` (`#[cfg(feature = "locker")]` at `lib.rs:7`) before deleting `crates/locker`.
  - Prune `[workspace.dependencies]` and the `tauri-plugin-updater` patch. Regenerate `Cargo.lock`; I found no `--locked` in `mobile/cargokit`. Fix up `rust/checks/*`.
- **R2, needs `flutter_rust_bridge_codegen` 2.13.0 exactly.** Drop `ente-frb-lib` from `rust_input` and `rust_features` in `flutter_rust_bridge.yaml`; delete `api/cast_api.rs` and `api/notification_api.rs`; regenerate `frb_generated.rs` and `lib/src/rust/**`. This drops `ente-accounts`, `-contacts`, `-legacy`, `-cast`. Only do it after stage 4 removed the Dart users (for example `configuration.dart:54` imports `src/rust/third_party/ente_frb_lib/account_deletion.dart`). A generated-code mismatch is a link or runtime failure the analyzer cannot see, so the APK build is the only gate.
- **R3, feature-gate HTTP, optional.** `reqwest` is a non-optional dependency of both `ente-core` and `ente-assets`, so it is compiled into the photos `.so` today.
  - `crates/core`: all reqwest use is in `src/http.rs` (1,015 LOC). Add an `http` feature gating `pub mod http`. In the photos crate, gate `files.rs`, `collections.rs` and `dedup/removal.rs`, which use `ente_core::http` or `ente_collections`.
  - `crates/assets`: only `download.rs` (3,148 LOC) uses reqwest, but `store.rs:10` and `ml`/`photos` import `download::{CancellationToken, Error, Progress}`. Move those types to a non-HTTP module first, then gate `Downloader`. `ml/src/assets.rs`, `ml/src/ocr/assets.rs`, `ml/src/scan/mod.rs` and `photos/src/location.rs` call into it.
  - This is real Rust refactoring with no runtime test. I would stop before R3 unless "no HTTP client linked in native code" is a hard requirement.

### Stage 8 — Final verification

- `flutter analyze` and `flutter test` in `mobile/apps/photos`; `flutter build apk --release`.
- `grep -rE "package:(dio|http|sentry|connectivity_plus|flutter_inappwebview|app_links)" lib` returns nothing.
- `grep -rn "https\?://" lib` reviewed by hand; remaining hits should be comments or strings.
- Merged-manifest permission list checked.
- `strings` on `libapp.so` and the Rust `.so` for `api.ente.io`, `sentry`, `cronet`.

---

## 3. Parallelisation summary

| Stage | Parallel? | Ownership lines |
|---|---|---|
| 0 | No | — |
| 1 | Yes, 5 workers plus integrator | Hubs / `ui/viewer/file*` / `ui/viewer/{gallery,search*,people,actions}` / `ui/home` + memories + rewind / ML + utils + models + db + settings |
| 2 | Yes, 4 workers | Hubs + sync + `module/download` / `ui/viewer/file` / gallery + home + delete util / services + utils |
| 3 | 3a sequential, 3b 4 workers | Same directory split; stub owner integrates |
| 4 | Step 2 parallel (4 directory groups); others sequential, one worker each | Steps 1, 3, 4, 5, 6 all touch `main.dart` and `service_locator.dart` |
| 5, 6 | Sequential | pubspec, lockfile, manifest are single files |
| 7 | Parallel with 5 and 6 | `rust/**` only; R2 after stage 4 |

Stages 1 and 2 could run concurrently only if the hub owner is the same person for both. I recommend against it; the hub files conflict.

---

## 4. Riskiest items and recommendations

### (a) `EnteFile` fields and `FilesDB` schema — confirm: leave both intact

- The schema is a migration list (`files_db.dart:81`, ALTERs through :401); existing installs depend on it replaying identically.
- The same DB holds `device_files`, `device_collections` and `entities`.
- Local rows are ordinary `files` rows with `uploaded_file_id` NULL and owner -1 or NULL; queries filter on those columns (`files_db.dart:1030`).
- `uploadedFileID` (684 uses), `collectionID` (1,124) and `ownerID` (235) are read throughout the gallery core, memories and search. Removing the fields means rewriting row mappers, `EnteFile.from`, `applyMetadata`, `tag` and equality, where a mistake breaks deduplication or hero tags with no analyzer signal.
- The cost of keeping them is a few nullable ints per object.
- Optional last step: prune `FilesDB` methods with no callers, method by method. Never touch the migrations.

### (b) `CollectionsService` and collection UI

- Local mode uses device folders only (`DeviceFolderVerticalGridSliver`, `FilesDB.getFilesInDeviceCollection`, `device_files_db.dart`).
- `CollectionsDB` stays empty because creating a collection needs the gateway, so all 62 survivor importers get empty or null results today.
- The stub-then-remove route in stage 3 fixes current behaviour first and makes later mistakes compile errors.
- The risk is the 17 hidden/archived filter call sites feeding SQL builders.
- Three product consequences to accept: no favourites, no hidden or archive, Albums widget non-functional. All three already hold today.

### (c) `Configuration` and secure storage

- Slim, do not delete; 125 files reference it and the directory getters are load-bearing.
- Remove all secure-storage use from `Configuration`. The lock screen has its own storage and needs only `isLoggedIn()` and `logout()` from the host (`lock_screen_host.dart`).
- Fix the `deleteAll()` at `:143` in the same change.
- `flutter_secure_storage` stays pinned at 9.0.0 (comment in pubspec) because `ente_lock_screen` uses it.
- `Configuration.init` also runs `_cleanUpStaleFiles` on `temp/` using `isUploadTempArtifactPath` from the upload module. Replace it with "delete everything in `temp/` older than N" or keep a small predicate; editor and export code use `getTempDirectory()`.

### (c-flags) `FlagService` replacement values

Today in a release build with no account, `internalUser` is false. Record and preserve:

| Value today (release, local) | Flags |
|---|---|
| false | `rustMlDb`, `rustMemories`, `newMemories`, `rewind`, `videoEditorSpeedEnabled`, `memoryVideoExportEnabled`, `progressiveOriginalVideoPlayback`, `useRustForHeicDecoder`, `syncRecoveryDiagnostics`, `mLHydrationStaleFileRecovery`, `petEnabled` |
| true | `usearchForSearch`, `usearchForSuggestions`, `useNativeVideoEditor`, `facesTimeline`, `enableMLInBackground`, `qrFeatureEnabled`, `ocrOverlayEnabled`, `webGPUEnabled` |
| false, via the remote consent flag | `flagService.hasGrantedMLConsent`, `enableVectorDb`, `manualTagFileToPerson` |

The third row needs your decision. About 25 survivor call sites read the remote consent flag directly, not the mode-aware top-level `hasGrantedMLConsent`:
- `ml_data_db_orchestration.dart:90`, `:151`, `:746-796` (`enableVectorDb`)
- `cluster_feedback.dart:1246`, `:1267` (usearch suggestions return early)
- `semantic_search_service.dart:84`, `:88`, `:427`
- `file_info_faces_item_widget.dart:201`, `:305` and `file_selection_actions_widget.dart:415` (manual tagging hidden)
- `free_space_options.dart:132` (Similar Images hidden)

Unless the ML tuning work already changed this, these features are off in the fork today. The removal must not change them silently. Options: keep them false (pure behaviour preservation), or deliberately rewire them to the local consent, which enables vector-DB migration and manual tagging and needs its own review. Debug builds differ (`kDebugMode` makes `internalUser` true, so `rustMlDb` is true); the constants class should not depend on `kDebugMode` for `rustMlDb`, or debug and release will use different ML databases.

### (d) pubspec dependencies

**Removable with zero survivor imports after stages 1-3:** `bip39`, `camera`, `cupertino_http` (already unused), `defer_pointer`, `dio_http2_adapter`, `encrypt`, `ente_qr_ui`, `fast_base58`, `native_dio_adapter`, `password_strength`, `pinput`, `ua_client_hints`, `xml`, `ente_cast`, `ente_frb` (direct).

**Removable after stage 4:** `dio`, `http`, `sentry`, `sentry_flutter`, `connectivity_plus`, `flutter_cache_manager` (also `app_storage_viewer.dart`), `flutter_inappwebview`, `app_links`, `ente_feature_flag`, `ente_install_source`, `ente_account_deletion`, `ente_contacts`, `ente_base`, `email_validator`, `ente_mail`, `file_saver`, `flutter_map`, `latlong2`, `ente_screen_brightness`, `just_audio` and `audio_session` (if memory music goes), `protobuf` (the only importer is the generated `vector.pb.dart`; check it is unused), `styled_text` if the remaining 2 uses are rewritten.

**Decide:**
- `receive_sharing_intent`: 6 survivors; share-into-app is an upload feature.
- `url_launcher`: only QR link opening would remain after `review_service` and `web_page` go.
- `share_plus`: keep, sharing a local photo to another app is a local feature.
- `flutter_local_notifications`, `timezone`, `flutter_timezone`: keep if local memory notifications are wanted. They bring `POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED` and the boot receiver (manifest :252-260).
- `crypto`: keep, used by `file_hash_pool.dart` for the exact-duplicate finder.

**Native-side permissions and SDKs by plugin:**
- `ente_cast`: `CHANGE_WIFI_MULTICAST_STATE`, `multicast_dns`
- `camera`: `CAMERA`, `RECORD_AUDIO`
- `ente_background_manager`: `ACCESS_NETWORK_STATE` (keep the plugin; consider removing the permission in its manifest)
- `connectivity_plus`: `ACCESS_NETWORK_STATE`
- `sentry_flutter`: native Sentry SDK
- `cronet_http`: transitive via `ente_network`; I did not check whether it resolves to the Play Services build
- `ente_photos_platform`: `SET_WALLPAPER` (keep)

### (e) Rust

`ente-photos-frb` closure: `ente-assets`, `ente-cast`, `ente-core`, `ente-frb-lib[contacts, legacy]` (→ accounts, contacts, legacy), `ente-frb-log`, `ente-image`, `ente-live-photo`, `ente-location`, `ente-ml[usearch]`, `ente-photos` (→ collections, exif, vecdb). The R1/R2/R3 split is in stage 7. R1 is safe now, R2 is safe after stage 4 with exact-version codegen, R3 is optional refactoring.

### (f) l10n and `mobile/packages/strings`

Leave untouched. 56 generated files; unused getters cost nothing at analyze time, and pruning ARB keys means regenerating every locale for no functional gain. Same for unused image assets beyond the two asset directories named in stage 5.

### (g) Tests

`test/`, `integration_test/` and `test_driver/` hold 149 Dart files; 52 reference kill-set code.
- Delete about 40 outright (lists per stage).
- Update about 12: `security_settings_page_test`, `ml_consent_sheet_test`, `ml_file_retrieval_test`, `delete_file_util_test`, `full_screen_memory_test`, `gallery_thumbnail_demand_test`, `gallery_file_widget_test`, `gallery_grid_zoom*`, `gallery_viewer_return_test`, `device_picker_page_test`, `gallery_file_viewer_filmstrip_test`.
- `integration_test/{notification_lifecycle_test,video_editor_test,ml_parity_shared}.dart` reference removed code; fix or delete since analyze covers them.
- Keep and run after every stage: `test/services/sync/*` (local import), `test/db/*`, `test/services/machine_learning/*`, `test/services/memories/*`, `test/services/free_space/*`, `test/utils/*`. These are the only behavioural safety net.
- Delete `mobile/mobile-tests` (6 files) if it targets account flows; I did not open it.

---

## 5. Scope estimate and stopping point

| Area | Deleted | Edited |
|---|---|---|
| `lib/` stages 1-4 | ~370-400 files, ~90-95K LOC (about 30% of the app) | ~200-230 files; ~160 for import cuts, the rest for mode-flag collapse (90 files, heavy overlap) |
| `test/` and `integration_test/` | ~40 | ~12 |
| Workspace apps, packages, plugin | ~1,750 files | ~25 (pubspecs, `lock_screen`, `ui`, `utils`/`logging`) |
| Android, iOS, scripts | ~120 (mostly `ios/`) | ~5 |
| Rust R1 (+R2) | ~300 files, 31 workspace members | ~6 manifests; R2 regenerates bindings |

Effort: stages 1-3 are about three parallel waves of 4-5 workers; stage 4 is one wave plus sequential hub work; stages 5-7 are one worker each.

**Where I would stop** for "no network-capable code path reachable or linked, and dead account code gone":
- Do stages 0-6, R1, and R2 if codegen is available.
- Do not remove `EnteFile` fields, the `FilesDB` schema or migrations, or `GalleryType` and `SyncStatus` enum values.
- Do not chase the remaining `uploadedFileID`/`isUploaded` reads inside the gallery core, memories and search; they are null-safe no-ops locally.
- Do not prune l10n.
- Do R3 only if a linked-but-unreachable `reqwest` in the native library is unacceptable.

Past that line every further deletion is a rewrite of the gallery core, with analyzer-invisible risk and no device to test on.

**Caveats on my evidence.** Counts come from a regex import graph (import, export, part), so cascade lists can be off by a few files. Not verified: the shared Android secure store, Cargo's optional-path-dependency behaviour, whether `cronet_http` resolves to the Play Services build, the body of `LocalFileUpdateService`, whether memory-music tracks are bundled.

### Critical Files for Implementation
- mobile/apps/photos/lib/main.dart
- mobile/apps/photos/lib/service_locator.dart
- mobile/apps/photos/lib/core/configuration.dart
- mobile/apps/photos/lib/services/collections_service.dart
- mobile/apps/photos/lib/module/download/file.dart

Also central: `lib/module/download/thumbnail.dart`, `lib/services/sync/sync_service.dart`, `lib/ui/tabs/home_widget.dart`, `lib/ui/settings/backup/free_space_options.dart`, `mobile/packages/feature_flag/lib/src/flag_service.dart`, `mobile/packages/lock_screen/lib/ui/lock_screen.dart`, `rust/Cargo.toml`.

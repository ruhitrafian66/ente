// Offline fork: shows what the app may read on the device, and lets the
// owner give it more. Not localized.

import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:permission_handler/permission_handler.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/sync/local_sync_service.dart";

/// True when the owner gave the app "All files access". With it, Android
/// lets the app read and write files in every folder of the shared storage.
Future<bool> hasAllFilesAccess() async {
  try {
    return await Permission.manageExternalStorage.isGranted;
  } catch (_) {
    return false;
  }
}

class FileAccessSection extends StatefulWidget {
  const FileAccessSection({super.key});

  @override
  State<FileAccessSection> createState() => _FileAccessSectionState();
}

class _FileAccessSectionState extends State<FileAccessSection>
    with WidgetsBindingObserver {
  final _logger = Logger("FileAccessSection");
  PermissionState? _mediaState;
  bool? _allFiles;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh(resync: false));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The owner changes both permissions on Android settings pages, so read
  // them again each time the app comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh(resync: true));
    }
  }

  Future<void> _refresh({required bool resync}) async {
    try {
      final mediaState = await permissionService.getPermissionState();
      final allFiles = await hasAllFilesAccess();
      final changed = mediaState != _mediaState || allFiles != _allFiles;
      if (!mounted) return;
      setState(() {
        _mediaState = mediaState;
        _allFiles = allFiles;
      });
      if (resync && changed) {
        await permissionService.onUpdatePermission(mediaState);
        // Pick up the files that the app can see now.
        unawaited(LocalSyncService.instance.checkAndSync());
      }
    } catch (e, s) {
      _logger.warning("Could not read the file permissions", e, s);
    }
  }

  Future<void> _requestAllFiles() async {
    // Android shows its "All files access" settings page for this app.
    await Permission.manageExternalStorage.request();
    await _refresh(resync: true);
  }

  String get _mediaText => switch (_mediaState) {
    null => "Checking…",
    PermissionState.authorized => "All photos and videos",
    PermissionState.limited =>
      "Selected items only. The app cannot see the other files. Tap to "
          "change this to \"Allow all\".",
    _ => "No access. Tap to open the Android settings.",
  };

  @override
  Widget build(BuildContext context) {
    return MenuGroupComponent(
      items: [
        SettingsItem(
          title: "Photo and video access",
          subtitle: _mediaText,
          icon: HugeIcons.strokeRoundedImage01,
          showOnlyLoadingState: true,
          subtitleMaxLines: 3,
          onTap: () async => PhotoManager.openSetting(),
        ),
        SettingsItem(
          title: "All files access",
          subtitle: switch (_allFiles) {
            null => "Checking…",
            true => "Granted. The tools can save and delete in every folder.",
            false =>
              "Not granted. Tap to let the app read and write files in "
                  "every folder.",
          },
          icon: HugeIcons.strokeRoundedFolder01,
          showOnlyLoadingState: true,
          subtitleMaxLines: 3,
          onTap: _allFiles == true
              ? () async => openAppSettings()
              : _requestAllFiles,
        ),
      ],
    );
  }
}

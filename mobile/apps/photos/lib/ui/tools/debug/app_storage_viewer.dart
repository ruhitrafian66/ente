import 'dart:io';

import 'package:ente_components/ente_components.dart';
import 'package:ente_pure_utils/ente_pure_utils.dart';
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import "package:logging/logging.dart";
import 'package:path_provider/path_provider.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/ui/tools/debug/path_storage_viewer.dart';

class AppStorageViewer extends StatefulWidget {
  const AppStorageViewer({super.key});

  @override
  State<AppStorageViewer> createState() => _AppStorageViewerState();
}

class _AppStorageViewerState extends State<AppStorageViewer> {
  final List<PathStorageItem> paths = [];
  late String iosTempDirectoryPath;
  int _refreshCounterKey = 0;
  final Logger _logger = Logger("_AppStorageViewerState");

  @override
  void initState() {
    super.initState();
    addPath();
  }

  void addPath() async {
    final appDocumentsDirectory = (await getApplicationDocumentsDirectory());
    final appSupportDirectory = (await getApplicationSupportDirectory());
    final appTemporaryDirectory = (await getTemporaryDirectory());
    iosTempDirectoryPath = "${appDocumentsDirectory.parent.path}/tmp/";
    final iOSPhotoManagerInAppCacheDirectory =
        iosTempDirectoryPath + "flutter-images";
    final androidGlideCacheDirectory =
        "${appTemporaryDirectory.path}/image_manager_disk_cache/";

    final String tempDownload = Configuration.instance.getTempDirectory();
    final String cacheDirectory = Configuration.instance
        .getThumbnailCacheDirectory();
    // Offline fork: "libCachedImageData" is the folder name of the default
    // flutter_cache_manager cache (`DefaultCacheManager.key`).
    final imageCachePath = appTemporaryDirectory.path + "/libCachedImageData";
    if (!mounted) return;
    paths.addAll([
      PathStorageItem.name(
        imageCachePath,
        context.strings.remoteImages,
        allowCacheClear: true,
      ),
      PathStorageItem.name(
        cacheDirectory,
        context.strings.remoteThumbnails,
        allowCacheClear: true,
      ),
      PathStorageItem.name(tempDownload, context.strings.pendingSync),
      PathStorageItem.name(
        Platform.isAndroid
            ? androidGlideCacheDirectory
            : iOSPhotoManagerInAppCacheDirectory,
        context.strings.localGallery,
        allowCacheClear: true,
      ),
    ]);
    final List<String> directoryStatePath = [
      appDocumentsDirectory.path,
      appSupportDirectory.path,
      appTemporaryDirectory.path,
    ];
    if (!Platform.isAndroid) {
      directoryStatePath.add(iosTempDirectoryPath);
    }
    prettyStringDirectoryStats(directoryStatePath).ignore();
    if (mounted) {
      setState(() => {});
    }
  }

  Future<void> prettyStringDirectoryStats(List<String> paths) async {
    try {
      for (var path in paths) {
        final DirectoryStat stat = await getDirectoryStat(Directory(path));
        final content = prettyPrintDirectoryStat(stat, path);
        if (content.isNotEmpty) {
          _logger.info(content);
        }
      }
    } catch (e) {
      _logger.severe("Failed to print directory stats", e);
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("$runtimeType building");

    return SettingsPageScaffold(
      title: context.strings.manageDeviceStorage,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: Spacing.lg,
            top: Spacing.md,
            bottom: Spacing.sm,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.strings.cachedData,
              style: TextStyles.mini.copyWith(
                color: context.componentColors.textLight,
              ),
            ),
          ),
        ),
        MenuGroupComponent(
          items: [
            for (var index = 0; index < paths.length; index++)
              PathStorageViewer(
                paths[index],
                key: ValueKey("$index-$_refreshCounterKey"),
              ),
          ],
        ),
        const SizedBox(height: Spacing.xl),
        ButtonComponent(
          label: context.strings.clearCaches,
          variant: ButtonComponentVariant.neutral,
          onTap: () async {
            for (var pathItem in paths) {
              if (pathItem.allowCacheClear) {
                await deleteDirectoryContents(pathItem.path);
              }
            }
            if (!Platform.isAndroid) {
              await deleteDirectoryContents(iosTempDirectoryPath);
            }
            // Small delay to allow file system to sync
            await Future.delayed(const Duration(milliseconds: 300));
            _refreshCounterKey++;
            if (mounted) {
              setState(() => {});
            }
          },
        ),
        const SizedBox(height: Spacing.xl),
      ],
    );
  }
}

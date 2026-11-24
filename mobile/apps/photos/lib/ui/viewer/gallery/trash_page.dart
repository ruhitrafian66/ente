import "dart:async";

import "package:collection/collection.dart";
import "package:ente_components/ente_components.dart";
import "package:ente_lock_screen/local_authentication_service.dart";
import "package:ente_photos_platform/ente_photos_platform.dart"
    show DeviceTrashClient;
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/extensions.dart";
import 'package:flutter/material.dart';
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/force_reload_trash_page_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/trash_file.dart";
import "package:photos/models/file_load_result.dart";
import "package:photos/models/gallery_type.dart";
import "package:photos/models/selected_files.dart";
import "package:photos/module/metadata/local_file.dart";
import "package:photos/ui/components/empty_state_component.dart";
import "package:photos/ui/viewer/actions/file_selection_overlay_bar.dart";
import "package:photos/ui/viewer/gallery/gallery.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_widget.dart";
import "package:photos/ui/viewer/gallery/state/gallery_boundaries_provider.dart";
import "package:photos/ui/viewer/gallery/state/gallery_files_inherited_widget.dart";
import "package:photos/ui/viewer/gallery/state/selection_state.dart";
import "package:photos/utils/delete_file_util.dart";

Future<void> showTrashPage(
  BuildContext context, {
  Function? beforeRouteToPage,
}) async {
  final l10n = context.strings;
  final hasAuthenticated = await LocalAuthenticationService.instance
      .requestLocalAuthentication(context, l10n.authToViewTrashedFiles);
  if (!hasAuthenticated) return;
  await beforeRouteToPage?.call();
  if (!context.mounted) return;
  await routeToPage(context, const _TrashPage());
}

/// Shows the device trash (Android MediaStore trash). This app has no other
/// trash.
class _TrashPage extends StatefulWidget {
  const _TrashPage();

  @override
  State<_TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<_TrashPage> {
  bool _hasTrashFiles = false;
  final _selectedFiles = SelectedFiles();

  @override
  Widget build(BuildContext context) {
    final l10n = context.strings;
    final gallery = AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: Gallery(
        key: const ValueKey('device_trash_page'),
        header: const SizedBox(height: 6),
        enableFileGrouping: false,
        appBar: GalleryAppBarWidget.sliverConfig(
          GalleryType.trash,
          l10n.trash,
          _selectedFiles,
          subtitle:
              l10n.itemsShowTheNumberOfDaysRemainingBeforePermanentDeletion,
        ),
        asyncLoader: _asyncLoader,
        reloadEvent: Bus.instance.on<FilesUpdatedEvent>().where(
          (event) =>
              event.updatedFiles.firstWhereOrNull(
                (element) => element.uploadedFileID != null,
              ) !=
              null,
        ),
        forceReloadEvents: [Bus.instance.on<ForceReloadTrashPageEvent>()],
        tagPrefix: "trash_page",
        selectedFiles: _selectedFiles,
        initialFiles: null,
        emptyState: EmptyStateComponent(
          assetPath: "assets/ente-trash-ducky.riv",
          animated: true,
          illustrationSize: const Size(204, 161),
          title: l10n.deletedItemsStayHereForThirtyDays,
        ),
      ),
    );
    return GalleryBoundariesProvider(
      child: GalleryFilesState(
        child: Scaffold(
          body: SelectionState(
            selectedFiles: _selectedFiles,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                gallery,
                FileSelectionOverlayBar(GalleryType.trash, _selectedFiles),
              ],
            ),
          ),
          floatingActionButton: ListenableBuilder(
            listenable: _selectedFiles,
            builder: (context, _) {
              if (_selectedFiles.files.isNotEmpty || !_hasTrashFiles) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: FABComponent(
                  label: l10n.emptyTrash,
                  variant: FABComponentVariant.destructive,
                  onTap: () => showConfirmEmptyTrashSheet(context),
                ),
              );
            },
          ),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerFloat,
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
        ),
      ),
    );
  }

  Future<FileLoadResult> _asyncLoader(
    int creationStartTime,
    int creationEndTime, {
    int? limit,
    bool? asc,
  }) async {
    final deviceTrash = await DeviceTrashClient.instance.getFiles();
    final deviceTrashAssets = await Future.wait(
      deviceTrash.map((t) => AssetEntity.fromId(t.localID.toString())),
    );
    final List<EnteFile> files = [];
    for (var i = 0; i < deviceTrash.length; i++) {
      final trash = deviceTrash[i];
      final asset = deviceTrashAssets[i];
      if (asset == null) continue;
      files.add(
        DeviceTrashFile.from(
          fileFromAsset(trash.deviceFolder, asset),
          deleteBy: trash.deleteBy,
        ),
      );
    }
    final result = FileLoadResult(files, false);
    if (mounted) {
      final hasTrashFiles = result.files.isNotEmpty;
      if (_hasTrashFiles != hasTrashFiles) {
        setState(() => _hasTrashFiles = hasTrashFiles);
      }
    }
    return result;
  }
}

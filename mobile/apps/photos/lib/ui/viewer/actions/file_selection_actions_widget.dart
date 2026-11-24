import "dart:async";

import "package:ente_components/hugeicons.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import "package:local_auth/local_auth.dart";
import "package:logging/logging.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/constants.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/force_reload_trash_page_event.dart";
import "package:photos/events/guest_view_event.dart";
import "package:photos/events/people_changed_event.dart";
import 'package:photos/models/device_collection.dart';
import "package:photos/models/file/extensions/file_props.dart";
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/models/gallery_type.dart';
import "package:photos/models/ml/face/person.dart";
import 'package:photos/models/selected_files.dart';
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart";
import 'package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart';
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import 'package:photos/ui/components/action_sheet_widget.dart';
import "package:photos/ui/components/bottom_action_bar/selection_action_sheet.dart";
import 'package:photos/ui/components/buttons/button_widget.dart';
import 'package:photos/ui/components/models/button_type.dart';
import 'package:photos/ui/notification/toast.dart';
import "package:photos/ui/tools/collage/collage_creator_page.dart";
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/ui/viewer/people/add_files_to_person_page.dart";
import 'package:photos/utils/delete_file_util.dart';
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/share_util.dart";

class FileSelectionActionsWidget extends StatefulWidget {
  final GalleryType type;
  final DeviceCollection? deviceCollection;
  final SelectedFiles selectedFiles;
  final PersonEntity? person;
  final String? clusterID;
  final Widget selectionControls;
  final Color? backgroundColor;

  const FileSelectionActionsWidget(
    this.type,
    this.selectedFiles, {
    super.key,
    required this.selectionControls,
    this.backgroundColor,
    this.person,
    this.clusterID,
    this.deviceCollection,
  });

  @override
  State<FileSelectionActionsWidget> createState() =>
      _FileSelectionActionsWidgetState();
}

class _FileSelectionActionsWidgetState
    extends State<FileSelectionActionsWidget> {
  static final _logger = Logger("FileSelectionActionsWidget");
  bool _isUpdatingPersonCover = false;
  final GlobalKey shareButtonKey = GlobalKey();
  final StreamController<double> _progressController =
      StreamController<double>();

  @override
  void initState() {
    super.initState();
    widget.selectedFiles.addListener(_selectFileChangeListener);
  }

  @override
  void dispose() {
    _progressController.close();
    widget.selectedFiles.removeListener(_selectFileChangeListener);
    super.dispose();
  }

  void _selectFileChangeListener() {
    if (mounted) {
      setState(() => {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectedFiles.files.isEmpty) {
      return const SizedBox();
    }
    // Offline fork: people actions need an ML file ID, not an upload.
    final bool hasMlFileIDs = widget.selectedFiles.files.any(
      (file) => file.mlFileID != null,
    );
    final showCollageOption =
        CollageCreatorPage.isValidCount(widget.selectedFiles.files.length) &&
        !widget.selectedFiles.files.any(
          (element) => element.fileType == FileType.video,
        );

    final List<SelectionSheetAction> items = [];
    if (widget.type == GalleryType.trash) {
      items.add(
        SelectionSheetAction(
          hugeIcon: HugeIcons.strokeRoundedRestoreBin,
          labelText: context.strings.restore,
          onTap: _restore,
        ),
      );
      items.add(
        SelectionSheetAction(
          hugeIcon: HugeIcons.strokeRoundedDelete01,
          labelText: context.strings.permanentlyDelete,
          onTap: _permanentlyDeleteFromTrash,
          isCritical: true,
        ),
      );
    } else {
      if (widget.type != GalleryType.sharedPublicCollection) {
        items.add(
          SelectionSheetAction(
            labelText: context.strings.share,
            gridOrder: 0,
            hugeIcon: HugeIcons.strokeRoundedShare08,
            key: shareButtonKey,
            onTap: _shareSelectedFiles,
          ),
        );
      }

      if (widget.type.showDeleteOption()) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedDelete01,
            labelText: context.strings.delete,
            gridOrder: 3,
            // Offline fork: every device file has no owner, so delete is
            // always available.
            onTap: _onDeleteClick,
            isCritical: true,
          ),
        );
      }

      if (widget.type.showRestoreOption()) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedRestoreBin,
            labelText: context.strings.restore,
            onTap: _restore,
          ),
        );
      }

      if (widget.type.showPermanentlyDeleteOption()) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedDelete01,
            labelText: context.strings.permanentlyDelete,
            onTap: _permanentlyDeleteFromTrash,
            isCritical: true,
          ),
        );
      }

      if (kOfflineManualTagFileToPerson &&
          widget.type.showAddToPersonOption()) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedUserAdd01,
            labelText: context.strings.addToPerson,
            onTap: hasMlFileIDs ? _onAddFilesToPerson : null,
            shouldShow: hasMlFileIDs,
          ),
        );
      }

      if (widget.type == GalleryType.peopleTag && widget.person != null) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedUserRemove01,
            labelText: context.strings.notPersonLabel(
              name: widget.person!.data.name,
            ),
            onTap: _onNotpersonClicked,
          ),
        );
        // Offline fork: local files are never "owned uploads", so the cover
        // action depends on the selection count and the ML file ID.
        if (widget.selectedFiles.files.length == 1) {
          items.add(
            SelectionSheetAction(
              hugeIcon: HugeIcons.strokeRoundedImage01,
              labelText: context.strings.useAsCover,
              onTap: hasMlFileIDs ? _setPersonCover : null,
            ),
          );
        }
      }

      if (widget.type == GalleryType.cluster && widget.clusterID != null) {
        items.add(
          SelectionSheetAction(
            labelText: context.strings.notThisPerson,
            hugeIcon: HugeIcons.strokeRoundedUserRemove01,
            onTap: _onRemoveFromClusterClicked,
          ),
        );
      }

      if (widget.type != GalleryType.sharedPublicCollection) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedGridView,
            labelText: context.strings.createCollage,
            onTap: _onCreateCollageClicked,
            shouldShow: showCollageOption,
          ),
        );
      }

      if (widget.type.showRestoreOption()) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedRestoreBin,
            labelText: context.strings.restore,
            onTap: _restore,
          ),
        );
      }

      if (widget.type.showPermanentlyDeleteOption()) {
        items.add(
          SelectionSheetAction(
            hugeIcon: HugeIcons.strokeRoundedDelete01,
            labelText: context.strings.permanentlyDelete,
            onTap: _permanentlyDeleteFromTrash,
            isCritical: true,
          ),
        );
      }

      items.add(
        SelectionSheetAction(
          hugeIcon: HugeIcons.strokeRoundedIncognito,
          labelText: context.strings.guestView,
          onTap: _onGuestViewClick,
        ),
      );
    }

    return SelectionActionSheet(
      actions: items,
      selectionControls: widget.selectionControls,
      backgroundColor: widget.backgroundColor,
    );
  }

  Future<void> _shareSelectedFiles() async {
    shareSelected(context, shareButtonKey, widget.selectedFiles.files.toList());
    widget.selectedFiles.clearAll();
  }

  Future<void> _onDeleteClick() async {
    return showDeleteSheet(context, widget.selectedFiles);
  }

  Future<void> _onAddFilesToPerson() async {
    // Offline fork: manual assignments are keyed by `mlFileID`.
    final filesWithIds = widget.selectedFiles.files
        .where((file) => file.mlFileID != null)
        .toList();
    if (filesWithIds.isEmpty) {
      showShortToast(
        context,
        context.strings.onlyUploadedFilesCanBeAddedToPerson,
      );
      return;
    }
    final namedPersons = await AddFilesToPersonPage.prefetchNamedPersons(
      context,
    );
    if (!mounted) {
      return;
    }
    if (namedPersons != null && namedPersons.isEmpty) {
      return;
    }
    final result = await routeToPage(
      context,
      AddFilesToPersonPage(files: filesWithIds, initialPersons: namedPersons),
      forceCustomPageRoute: true,
    );
    if (result is! ManualPersonAssignmentResult) {
      return;
    }
    final addedCount = result.addedFileIds.length;
    if (addedCount > 0) {
      final addedFiles = filesWithIds
          .where(
            (file) =>
                file.mlFileID != null &&
                result.addedFileIds.contains(file.mlFileID),
          )
          .toList();
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.saveOrEditPerson,
          source: "manual-add-files-to-person",
          person: result.person,
          relevantFiles: addedFiles,
        ),
      );
      if (!mounted) return;
      showToast(
        context,
        context.strings.addedFilesToPerson(
          count: addedCount,
          personName: result.person.data.name,
        ),
      );
      widget.selectedFiles.clearAll();
      if (mounted) {
        setState(() => {});
      }
      return;
    }
    final alreadyCount = result.alreadyAssignedFileIds.length;
    if (alreadyCount > 0) {
      if (!mounted) return;
      showShortToast(
        context,
        context.strings.filesAlreadyLinkedToPerson(
          count: alreadyCount,
          personName: result.person.data.name,
        ),
      );
    }
  }

  Future<void> _onGuestViewClick() async {
    final List<EnteFile> selectedFiles = widget.selectedFiles.files.toList();
    final isDeviceSupported = await LocalAuthentication().isDeviceSupported();
    if (!mounted) return;
    if (isDeviceSupported) {
      final page = DetailPage(
        DetailPageConfiguration(selectedFiles, 0, "guest_view"),
      );
      await localSettings.setOnGuestView(true);
      if (!mounted) {
        await localSettings.setOnGuestView(false);
        return;
      }
      routeToPage(context, page, forceCustomPageRoute: true).ignore();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (localSettings.isOnGuestView()) {
          Bus.instance.fire(GuestViewEvent(true, false));
        }
      });
    } else {
      await showErrorDialog(
        context,
        context.strings.noSystemLockFound,
        context.strings.guestViewEnablePreSteps,
      );
    }
    if (!mounted) return;
    widget.selectedFiles.clearAll();
  }

  Future<void> _onCreateCollageClicked() async {
    final bool? result = await routeToPage(
      context,
      CollageCreatorPage(widget.selectedFiles.files.toList()),
    );
    if (result != null && result) {
      widget.selectedFiles.clearAll();
    }
  }

  Future<void> _setPersonCover() async {
    if (_isUpdatingPersonCover || widget.selectedFiles.files.isEmpty) return;
    _isUpdatingPersonCover = true;
    final EnteFile file = widget.selectedFiles.files.first;
    try {
      final result = await PersonService.instance.updateAvatar(
        widget.person!,
        file,
      );
      final updatedPerson = result.person;
      widget.selectedFiles.clearAll();
      if (mounted) {
        setState(() => {});
        if (result.contactPictureUpdateFailed) {
          showShortToast(context, "Failed to update contact picture");
        }
      }
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.saveOrEditPerson,
          source: "setPersonCover",
          person: updatedPerson,
        ),
      );
    } catch (e, s) {
      _logger.warning(
        "Failed to update cover for person ${widget.person!.remoteID} using file ${file.mlFileID}",
        e,
        s,
      );
      if (mounted) {
        showShortToast(
          context,
          context.strings.somethingWentWrongPleaseTryAgain,
        );
      }
    } finally {
      _isUpdatingPersonCover = false;
    }
  }

  Future<void> _onNotpersonClicked() async {
    try {
      final actionResult = await showActionSheet(
        context: context,
        title: context.strings.removeFromPersonQuestion,
        buttons: [
          ButtonWidget(
            labelText: context.strings.yesRemove,
            buttonType: ButtonType.neutral,
            buttonSize: ButtonSize.large,
            shouldStickToDarkTheme: true,
            buttonAction: ButtonAction.first,
            isInAlert: true,
          ),
          ButtonWidget(
            labelText: context.strings.cancel,
            buttonType: ButtonType.secondary,
            buttonSize: ButtonSize.large,
            buttonAction: ButtonAction.second,
            shouldStickToDarkTheme: true,
            isInAlert: true,
          ),
        ],
        body: context.strings.selectedItemsWillBeRemovedFromThisPerson,
        actionSheetType: ActionSheetType.defaultActionSheet,
      );
      if (actionResult?.action != null) {
        if (actionResult!.action == ButtonAction.first) {
          await ClusterFeedbackService.instance.removeFilesFromPerson(
            widget.selectedFiles.files.toList(),
            widget.person!,
          );
        }
      }
      widget.selectedFiles.clearAll();
      if (mounted) {
        setState(() => {});
      }
    } catch (e, s) {
      _logger.severe("Failed to initiate `notPersonLabel`", e, s);
    }
  }

  Future<void> _onRemoveFromClusterClicked() async {
    if (widget.clusterID == null) {
      showShortToast(context, 'Cluster ID is null. Cannot remove files.');
      return;
    }
    final actionResult = await showActionSheet(
      context: context,
      title: context.strings.removeFromPersonQuestion,
      buttons: [
        ButtonWidget(
          labelText: context.strings.yesRemove,
          buttonType: ButtonType.neutral,
          buttonSize: ButtonSize.large,
          shouldStickToDarkTheme: true,
          buttonAction: ButtonAction.first,
          isInAlert: true,
        ),
        ButtonWidget(
          labelText: context.strings.cancel,
          buttonType: ButtonType.secondary,
          buttonSize: ButtonSize.large,
          buttonAction: ButtonAction.second,
          shouldStickToDarkTheme: true,
          isInAlert: true,
        ),
      ],
      body: context.strings.selectedItemsWillBeRemovedFromThisPerson,
      actionSheetType: ActionSheetType.defaultActionSheet,
    );
    if (actionResult?.action != null) {
      if (actionResult!.action == ButtonAction.first) {
        await ClusterFeedbackService.instance.removeFilesFromCluster(
          widget.selectedFiles.files.toList(),
          widget.clusterID!,
        );
      }
    }
    widget.selectedFiles.clearAll();
    if (mounted) {
      setState(() => {});
    }
  }

  void _restore() {
    final isDeviceOnly = widget.selectedFiles.files.every(
      (f) => f.isDeviceTrash,
    );
    if (isDeviceOnly) {
      _restoreFilesFromDeviceTrash(widget.selectedFiles)
          .then((restoredCount) {
            if (restoredCount == 0 || !mounted) return;
            showToast(
              context,
              context.strings.restoredItems(count: restoredCount),
            );
          })
          .onError((e, s) {
            if (!mounted) return;
            showGenericErrorDialog(context: context, error: e).ignore();
          });
    }
  }

  Future<void> _permanentlyDeleteFromTrash() async {
    final isDeviceOnly = widget.selectedFiles.files.every(
      (f) => f.isDeviceTrash,
    );
    // The trash gallery holds device trash files only.
    if (!isDeviceOnly) return;
    final deletedIDs = await permanentlyDeleteFromDeviceTrash(
      context,
      widget.selectedFiles.files.map((f) => f.localID!).toList(),
    );
    widget.selectedFiles.unSelectAll(
      widget.selectedFiles.files
          .where((f) => deletedIDs.contains(f.localID))
          .toSet(),
    );
  }

  Future<int> _restoreFilesFromDeviceTrash(SelectedFiles selectedFiles) async {
    final files = selectedFiles.files
        .map((f) => f.asDeviceTrashFile!.toAssetEntity())
        .toList();
    final restoredIDs = <String>{};
    try {
      for (final batch in files.chunks(batchSize)) {
        final result = await PhotoManager.editor.android.restoreFromTrash(
          batch,
        );
        restoredIDs.addAll(result);
      }
      return restoredIDs.length;
    } catch (e, s) {
      _logger.warning("_restoreFilesFromDeviceTrash failed:", e, s);
      rethrow;
    } finally {
      if (restoredIDs.isNotEmpty) {
        final restoredFiles = selectedFiles.files.where(
          (f) => restoredIDs.contains(f.localID),
        );
        selectedFiles.unSelectAll(restoredFiles.toSet());
        Bus.instance.fire(ForceReloadTrashPageEvent());
      }
    }
  }
}

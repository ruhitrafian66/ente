import "dart:async";

import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:ente_ui/utils/toast_util.dart";
import "package:flutter/cupertino.dart";
import "package:flutter/material.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/force_reload_trash_page_event.dart";
import "package:photos/events/guest_view_event.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import 'package:photos/module/metadata/panorama.dart';
import "package:photos/ui/actions/file/file_actions.dart";
import "package:photos/ui/viewer/file/file_share_button.dart";
import "package:photos/utils/delete_file_util.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/share_util.dart";

class FileBottomBar extends StatefulWidget {
  final EnteFile file;
  final Function(EnteFile) onFileRemoved;
  final int? userID;
  final ValueNotifier<bool> enableFullScreenNotifier;
  final bool isLocalOnlyContext;

  const FileBottomBar(
    this.file, {
    required this.onFileRemoved,
    required this.enableFullScreenNotifier,
    this.userID,
    this.isLocalOnlyContext = false,
    super.key,
  });

  @override
  FileBottomBarState createState() => FileBottomBarState();
}

class FileBottomBarState extends State<FileBottomBar> {
  final GlobalKey shareButtonKey = GlobalKey();
  bool isGuestView = false;
  late final StreamSubscription<GuestViewEvent> _guestViewEventSubscription;
  int? lastFileGenID;

  @override
  void initState() {
    super.initState();
    _guestViewEventSubscription = Bus.instance.on<GuestViewEvent>().listen((
      event,
    ) {
      setState(() {
        isGuestView = event.isGuestView;
      });
    });
  }

  @override
  void dispose() {
    _guestViewEventSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.file.canEditMetaInfo &&
        widget.file.canBePanorama() &&
        widget.file.isPanorama() == null) {
      if (lastFileGenID != widget.file.generatedID) {
        lastFileGenID = widget.file.generatedID;
        guardedCheckPanorama(widget.file).ignore();
      }
    }

    return _getBottomBar();
  }

  Widget _getBottomBar() {
    final file = widget.file;
    final List<Widget> children = [];
    final bool isOwnedByUser =
        widget.file.ownerID == null || widget.file.ownerID == widget.userID;
    if (widget.file.isTrash) {
      _addTrashOptions(children);
    }

    if (!widget.file.isTrash) {
      if (isOwnedByUser) {
        children.add(
          Tooltip(
            message: context.strings.delete,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: IconButton(
                icon: const HugeIcon(
                  icon: HugeIcons.strokeRoundedDelete02,
                  color: Colors.white,
                ),
                onPressed: () async {
                  await _showSingleFileDeleteSheet(widget.file);
                },
              ),
            ),
          ),
        );
      }

      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: FileShareButton(
            key: shareButtonKey,
            onSendFile: () =>
                share(context, [file], shareButtonKey: shareButtonKey),
          ),
        ),
      );
    }
    return ValueListenableBuilder(
      valueListenable: widget.enableFullScreenNotifier,
      builder: (BuildContext context, bool isFullScreen, _) {
        return IgnorePointer(
          ignoring: isFullScreen || isGuestView,
          child: AnimatedOpacity(
            opacity: isFullScreen || isGuestView ? 0 : 1,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                left: false,
                right: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: children,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSingleFileDeleteSheet(EnteFile file) async {
    await showSingleFileDeleteSheet(
      context,
      file,
      onFileRemoved: widget.onFileRemoved,
      isLocalOnlyContext: widget.isLocalOnlyContext,
    );
  }

  void _addTrashOptions(List<Widget> children) {
    children.add(
      Tooltip(
        message: context.strings.restore,
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: IconButton(
            icon: const Icon(CupertinoIcons.gobackward, color: Colors.white),
            onPressed: () {
              // Offline fork: a trash file is always a device trash file.
              if (!widget.file.isDeviceTrash) return;
              _restoreFromDeviceTrash()
                  .then((didRestore) {
                    if (!didRestore || !mounted) return;
                    showToast(context, context.strings.restoredItems(count: 1));
                  })
                  .onError((e, s) {
                    if (!mounted) return;
                    showGenericErrorDialog(context: context, error: e).ignore();
                  });
            },
          ),
        ),
      ),
    );

    children.add(
      Tooltip(
        message: context.strings.delete,
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: IconButton(
            icon: const HugeIcon(
              icon: HugeIcons.strokeRoundedDelete02,
              color: Colors.white,
            ),
            onPressed: () async {
              // Offline fork: a trash file is always a device trash file.
              if (!widget.file.isDeviceTrash) return;
              final deletedIDs = await permanentlyDeleteFromDeviceTrash(
                context,
                [widget.file.localID!],
              );
              if (deletedIDs.isNotEmpty) {
                await widget.onFileRemoved(widget.file);
              }
            },
          ),
        ),
      ),
    );
  }

  Future<bool> _restoreFromDeviceTrash() async {
    final restoredIDs = await PhotoManager.editor.android.restoreFromTrash([
      widget.file.asDeviceTrashFile!.toAssetEntity(),
    ]);
    if (restoredIDs.isEmpty) return false;
    Bus.instance.fire(ForceReloadTrashPageEvent());
    await widget.onFileRemoved(widget.file);
    return true;
  }
}

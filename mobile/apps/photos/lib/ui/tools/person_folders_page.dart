// Offline fork: "Sort photos into person folders" tool page.
//
// Offline fork: not localized. The new user-facing strings in this file are
// hardcoded English.

import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/services/person_folders/person_folder_service.dart";

class PersonFoldersPage extends StatefulWidget {
  const PersonFoldersPage({super.key});

  @override
  State<PersonFoldersPage> createState() => _PersonFoldersPageState();
}

class _PersonFoldersPageState extends State<PersonFoldersPage>
    with WidgetsBindingObserver {
  final _logger = Logger("PersonFoldersPage");
  final _service = PersonFolderService.instance;

  bool _canManageMedia = true;
  int _recordCount = 0;
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasRunning = _service.progress.value.isRunning;
    _service.progress.addListener(_onProgress);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.progress.removeListener(_onProgress);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user can come back from the Android settings with a new answer.
    if (state == AppLifecycleState.resumed && !_service.isRunning) {
      unawaited(_refresh());
    }
  }

  void _onProgress() {
    final isRunning = _service.progress.value.isRunning;
    if (_wasRunning && !isRunning) unawaited(_refresh());
    _wasRunning = isRunning;
  }

  Future<void> _refresh() async {
    try {
      final canManageMedia = await _service.canMoveWithoutPrompt();
      final recordCount = await _service.getRecordCount();
      if (!mounted) return;
      setState(() {
        _canManageMedia = canManageMedia;
        _recordCount = recordCount;
      });
    } catch (e, s) {
      _logger.warning("Could not read the person folder state", e, s);
    }
  }

  String _photos(int count) => count == 1 ? "1 photo" : "$count photos";

  String _folders(int count) => count == 1 ? "1 folder" : "$count folders";

  Future<void> _onToggle() async {
    if (_service.isEnabled) {
      await _turnOff();
      return;
    }
    if (!_service.isInitialized || !_service.isSupported) {
      await _showMessage(
        "Not available",
        "This device cannot move photos in the media library.",
      );
      return;
    }
    if (!await _ensureMediaManagement()) return;

    final PersonFolderDryRun dryRun;
    try {
      dryRun = await _service.dryRun();
    } catch (e, s) {
      _logger.severe("Dry run failed", e, s);
      await _showMessage("The check failed", "$e");
      return;
    }
    if (!mounted) return;

    final moveCount = dryRun.toSort + dryRun.toResort;
    final skipped = dryRun.skipped.values.fold(0, (sum, count) => sum + count);
    final now = StringBuffer();
    if (dryRun.total == 0) {
      now.write("No photo moves now.");
    } else {
      if (moveCount > 0) {
        now.write(
          "${_photos(moveCount)} will move into "
          "${_folders(dryRun.folderCount)} now.",
        );
      }
      if (dryRun.toRestore > 0) {
        if (now.isNotEmpty) now.write(" ");
        now.write(
          "${_photos(dryRun.toRestore)} will go back to the original folder.",
        );
      }
    }
    if (skipped > 0) {
      now.write(
        " ${_photos(skipped)} will stay (the result shows the reasons).",
      );
    }
    final confirmed = await showBottomSheetComponent<bool>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: moveCount == 0
            ? "Turn on person folders?"
            : "Move ${_photos(moveCount)} into person folders?",
        message:
            "The app moves each photo of a named person out of its current "
            "folder and into $kPersonFoldersRoot/<person name>. A photo "
            "with two or more named persons goes to the person with the "
            "largest face. Videos do not move.\n\n"
            "$now\n\n"
            "Other apps and albums will not find these photos in the old "
            "folders. The app keeps a list of the original folders, and "
            "\"Restore all\" moves the photos back.\n\n"
            "While this is on, the app also moves new photos of named "
            "persons, and it moves photos when you rename, merge or remove "
            "a person.",
        illustration: Image.asset("assets/warning-red.png"),
        isScrollable: true,
        closeTooltip: sheetContext.strings.close,
        actions: [
          ButtonComponent(
            label: moveCount == 0 ? "Turn on" : "Move ${_photos(moveCount)}",
            variant: ButtonComponentVariant.critical,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
          ButtonComponent(
            label: sheetContext.strings.cancel,
            variant: ButtonComponentVariant.secondary,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(false),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.setEnabled(true);
    if (mounted) setState(() {});
    unawaited(_sortNow());
  }

  Future<void> _turnOff() async {
    // Off also stops a sort run in flight.
    await _service.setEnabled(false);
    await _refresh();
    if (!mounted) return;
    setState(() {});
    if (_recordCount > 0) {
      await _showMessage(
        "Person folders are off",
        "The app moves no more photos. ${_photos(_recordCount)} "
            "${_recordCount == 1 ? "stays" : "stay"} in the person folders. "
            "Use \"Restore all files to their original folders\" to move "
            "them back.",
      );
    }
  }

  Future<void> _sortNow() async {
    if (!await _ensureMediaManagement()) return;
    try {
      await _service.sortNow();
    } catch (e, s) {
      _logger.severe("Sort run failed", e, s);
    }
    await _refresh();
  }

  Future<void> _confirmAndRestoreAll() async {
    if (!await _ensureMediaManagement()) return;
    if (!mounted) return;
    final confirmed = await showBottomSheetComponent<bool>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: "Restore ${_photos(_recordCount)} to the original folders?",
        message:
            "The app turns off the sort. Then it moves each photo from its "
            "person folder back to the folder it came from.\n\n"
            "A photo that you moved or deleted with a different app stays "
            "where it is.",
        illustration: Image.asset("assets/warning-red.png"),
        closeTooltip: sheetContext.strings.close,
        actions: [
          ButtonComponent(
            label: "Restore all",
            variant: ButtonComponentVariant.critical,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
          ButtonComponent(
            label: sheetContext.strings.cancel,
            variant: ButtonComponentVariant.secondary,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(false),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (mounted) setState(() {});
    try {
      await _service.restoreAll();
    } catch (e, s) {
      _logger.severe("Restore run failed", e, s);
    }
    await _refresh();
  }

  /// Returns true when Android moves files without a prompt. If not, shows
  /// how to permit it.
  Future<bool> _ensureMediaManagement() async {
    final canManageMedia = await _service.canMoveWithoutPrompt();
    if (mounted) setState(() => _canManageMedia = canManageMedia);
    if (canManageMedia || !mounted) return canManageMedia;
    await showBottomSheetComponent<void>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: "Allow media management",
        message:
            "Android asks for a confirmation each time an app moves photos. "
            "To let the app move photos without these prompts, turn on "
            "\"Allow access to manage media\" for this app in the Android "
            "settings. Then come back to this page.",
        closeTooltip: sheetContext.strings.close,
        actions: [
          ButtonComponent(
            label: sheetContext.strings.openSettings,
            shouldSurfaceExecutionStates: false,
            onTap: () async {
              await PhotoManager.requestManageMedia();
              if (sheetContext.mounted) Navigator.of(sheetContext).pop();
            },
          ),
          ButtonComponent(
            label: sheetContext.strings.cancel,
            variant: ButtonComponentVariant.secondary,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(),
          ),
        ],
      ),
    );
    return false;
  }

  Future<void> _showMessage(String title, String message) async {
    if (!mounted) return;
    await showBottomSheetComponent<void>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: title,
        message: message,
        closeTooltip: sheetContext.strings.close,
        actions: [
          ButtonComponent(
            label: sheetContext.strings.ok,
            variant: ButtonComponentVariant.secondary,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return ValueListenableBuilder<PersonFolderProgress>(
      valueListenable: _service.progress,
      builder: (context, progress, _) {
        final isRunning = progress.isRunning;
        final isEnabled = _service.isEnabled;
        return SettingsPageScaffold(
          title: "Person folders",
          children: [
            Text(
              "Move the photos of each named person into "
              "$kPersonFoldersRoot/<person name> on this device. A photo "
              "with two or more named persons goes to the person with the "
              "largest face. Videos and persons without a name stay where "
              "they are.",
              style: TextStyles.body.copyWith(color: colors.textLight),
            ),
            const SizedBox(height: Spacing.lg),
            MenuComponent(
              title: "Sort photos into person folders",
              subtitle: isEnabled
                  ? "On. The app moves photos when persons or faces change."
                  : "Off. The app moves no photos.",
              trailing: ToggleSwitchComponent.async(
                value: () => _service.isEnabled,
                onChanged: _onToggle,
              ),
            ),
            if (!_canManageMedia) ...[
              const SizedBox(height: Spacing.md),
              Text(
                "The app does not have the Android permission to manage "
                "media. The automatic sort does not run without it.",
                style: TextStyles.mini.copyWith(color: colors.warning),
              ),
              const SizedBox(height: Spacing.sm),
              ButtonComponent(
                label: "Allow media management",
                variant: ButtonComponentVariant.secondary,
                shouldSurfaceExecutionStates: false,
                onTap: _ensureMediaManagement,
              ),
            ],
            const SizedBox(height: Spacing.lg),
            Text(
              _recordCount == 0
                  ? "No photos are in person folders."
                  : "${_photos(_recordCount)} "
                        "${_recordCount == 1 ? "is" : "are"} in person "
                        "folders.",
              style: TextStyles.body.copyWith(color: colors.textBase),
            ),
            if (isRunning) ...[
              const SizedBox(height: Spacing.lg),
              _buildProgress(progress),
            ],
            const SizedBox(height: Spacing.lg),
            ButtonComponent(
              label: "Sort now",
              variant: ButtonComponentVariant.secondary,
              isDisabled: !isEnabled || isRunning,
              shouldSurfaceExecutionStates: false,
              onTap: () => unawaited(_sortNow()),
            ),
            const SizedBox(height: Spacing.sm),
            ButtonComponent(
              label: "Restore all files to their original folders",
              variant: ButtonComponentVariant.tertiaryCritical,
              isDisabled: _recordCount == 0 || isRunning,
              shouldSurfaceExecutionStates: false,
              onTap: _confirmAndRestoreAll,
            ),
            const SizedBox(height: Spacing.xxl),
            ValueListenableBuilder<PersonFolderRunSummary?>(
              valueListenable: _service.lastRun,
              builder: (context, summary, _) => summary == null
                  ? const SizedBox.shrink()
                  : _buildSummary(summary),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProgress(PersonFolderProgress progress) {
    final colors = context.componentColors;
    final String status;
    switch (progress.phase) {
      case PersonFolderPhase.preparing:
        status = "Checking photos and persons…";
      case PersonFolderPhase.moving:
        status = progress.total == 0
            ? "No photos to move"
            : "${progress.isRestore ? "Restored" : "Moved"} "
                  "${progress.done} of ${progress.total}";
      case PersonFolderPhase.finishing:
        status = "Updating the gallery…";
      case PersonFolderPhase.idle:
        status = "";
    }
    final isMoving =
        progress.phase == PersonFolderPhase.moving && progress.total > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.xs),
          child: LinearProgressIndicator(
            value: isMoving ? progress.done / progress.total : null,
            minHeight: 6,
            color: colors.primary,
            backgroundColor: colors.fillLight,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          status,
          style: TextStyles.bodyBold.copyWith(color: colors.textBase),
        ),
        const SizedBox(height: Spacing.sm),
        ButtonComponent(
          label: "Stop",
          variant: ButtonComponentVariant.secondary,
          size: ButtonComponentSize.small,
          shouldSurfaceExecutionStates: false,
          onTap: _service.requestStop,
        ),
      ],
    );
  }

  Widget _buildSummary(PersonFolderRunSummary summary) {
    final colors = context.componentColors;
    final when = DateTime.fromMillisecondsSinceEpoch(summary.finishedAtMs);
    String two(int value) => value.toString().padLeft(2, "0");
    final time =
        "${when.year}-${two(when.month)}-${two(when.day)} "
        "${two(when.hour)}:${two(when.minute)}";
    final String kind;
    if (summary.isRestoreAll) {
      kind = "restore all";
    } else {
      kind = summary.isAutomatic ? "automatic sort" : "sort";
    }

    final lines = <String>[
      "Moved into person folders: ${summary.moved}",
      "Restored to original folders: ${summary.restored}",
      "Skipped: ${summary.skippedTotal}",
      for (final entry in summary.skipped.entries)
        "    ${_skipLabel(entry.key)}: ${entry.value}",
      if (summary.recordsDropped > 0)
        "Not tracked any more (moved or deleted outside the app): "
            "${summary.recordsDropped}",
      if (summary.notTried > 0) "Not done: ${summary.notTried}",
      if (summary.stopped) "The run was stopped.",
    ];
    final error = summary.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Last run",
          style: TextStyles.large.copyWith(color: colors.textBase),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          "$time ($kind)",
          style: TextStyles.mini.copyWith(color: colors.textLight),
        ),
        const SizedBox(height: Spacing.sm),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.xs),
            child: Text(
              line,
              style: TextStyles.body.copyWith(color: colors.textBase),
            ),
          ),
        if (error != null)
          Text(
            "The run did not finish: $error",
            style: TextStyles.body.copyWith(color: colors.warning),
          ),
      ],
    );
  }

  String _skipLabel(String reasonName) {
    final PersonFolderSkipReason reason;
    try {
      reason = PersonFolderSkipReason.values.byName(reasonName);
    } catch (_) {
      return reasonName;
    }
    switch (reason) {
      case PersonFolderSkipReason.notImage:
        return "Videos (only images move)";
      case PersonFolderSkipReason.foreignInPeopleFolder:
        return "Already in $kPersonFoldersRoot, not put there by the app";
      case PersonFolderSkipReason.sourceNotRestorable:
        return "Outside ${kPersonFolderSourceRoots.join(" and ")} "
            "(Android cannot move these back)";
      case PersonFolderSkipReason.nameCollision:
        return "A file with the same name is in the target folder";
      case PersonFolderSkipReason.movedExternally:
        return "Moved by a different app";
      case PersonFolderSkipReason.unavailable:
        return "In the trash or not readable now (still tracked)";
      case PersonFolderSkipReason.failedBefore:
        return "Failed before, not tried again";
      case PersonFolderSkipReason.moveRefused:
        return "Android did not move the file";
      case PersonFolderSkipReason.missing:
        return "File not found";
    }
  }
}

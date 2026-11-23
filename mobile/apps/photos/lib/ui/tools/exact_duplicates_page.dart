import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/core/constants.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/exact_duplicates_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/viewer/actions/select_all_status_icon.dart";
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";
import "package:photos/ui/viewer/gallery/empty_state.dart";
import "package:photos/utils/delete_file_util.dart";
import "package:photos/utils/dialog_util.dart";

enum _PageState { scanning, results, cancelled, failed }

/// Offline fork: lists device files with byte-identical content and lets the
/// user delete the extra copies. See [ExactDuplicatesService].
///
/// All strings on this page are hardcoded English.
/// Offline fork: not localized.
class ExactDuplicatesPage extends StatefulWidget {
  const ExactDuplicatesPage({super.key});

  @override
  State<ExactDuplicatesPage> createState() => _ExactDuplicatesPageState();
}

class _ExactDuplicatesPageState extends State<ExactDuplicatesPage> {
  static const _crossAxisCount = 3;
  static const _crossAxisSpacing = 12.0;
  static const _tagPrefix = "exact_duplicates_";
  static const _deleteBatchSize = 1500;

  static final _logger = Logger("ExactDuplicatesPage");

  final _service = ExactDuplicatesService.instance;

  _PageState _state = _PageState.scanning;
  List<ExactDuplicateGroup<EnteFile>> _groups = [];
  int _skippedCount = 0;

  /// Local IDs of the copies that are marked for deletion.
  final Set<String> _selectedIds = {};

  /// Each scan gets a number. A result of an old scan is ignored.
  int _scanGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_startScan());
  }

  @override
  void dispose() {
    if (_state == _PageState.scanning) {
      _service.cancel();
    }
    super.dispose();
  }

  Future<void> _startScan() async {
    final generation = ++_scanGeneration;
    setState(() {
      _state = _PageState.scanning;
    });
    try {
      final result = await _service.scan();
      if (!mounted || generation != _scanGeneration) return;
      if (result == null) {
        setState(() {
          _state = _PageState.cancelled;
        });
        return;
      }
      setState(() {
        _groups = List.of(result.groups);
        _skippedCount = result.skippedCount;
        _selectDefaults(reset: true);
        _state = _PageState.results;
      });
    } catch (e, s) {
      _logger.severe("Exact duplicates scan failed", e, s);
      if (!mounted || generation != _scanGeneration) return;
      setState(() {
        _state = _PageState.failed;
      });
    }
  }

  /// Marks all copies except one for deletion, in each group.
  ///
  /// With [reset], the copy that stays is the default keeper. Without it, a
  /// copy that the user chose to keep stays the keeper.
  void _selectDefaults({bool reset = false}) {
    if (reset) _selectedIds.clear();
    for (final group in _groups) {
      final keeper = group.copies.firstWhere(
        (copy) => !_selectedIds.contains(copy.id),
        orElse: () => group.keeper,
      );
      for (final copy in group.copies) {
        if (copy.id == keeper.id) {
          _selectedIds.remove(copy.id);
        } else {
          _selectedIds.add(copy.id);
        }
      }
    }
  }

  int _selectedCountIn(ExactDuplicateGroup<EnteFile> group) =>
      group.copies.where((copy) => _selectedIds.contains(copy.id)).length;

  void _toggle(
    ExactDuplicateGroup<EnteFile> group,
    DuplicateCopy<EnteFile> copy,
  ) {
    if (_selectedIds.contains(copy.id)) {
      setState(() {
        _selectedIds.remove(copy.id);
      });
      return;
    }
    // One copy of each file must stay on the device.
    if (_selectedCountIn(group) >= group.copies.length - 1) {
      showShortToast(context, "Keep at least one copy of each file");
      return;
    }
    setState(() {
      _selectedIds.add(copy.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text("Exact duplicates"),
        actions: [
          if (_state == _PageState.results)
            IconButton(
              tooltip: "Scan again",
              icon: const Icon(Icons.refresh),
              onPressed: _startScan,
            ),
        ],
      ),
      body: switch (_state) {
        _PageState.scanning => _buildScanning(),
        _PageState.results => _buildResults(),
        _PageState.cancelled => _buildMessage(
          "The scan was cancelled. The files that were compared are "
          "remembered, so the next scan is faster.",
        ),
        _PageState.failed => _buildMessage(
          "The scan failed. Make sure that the app has access to all photos "
          "and videos, then try again.",
        ),
      },
    );
  }

  Widget _buildScanning() {
    final textTheme = getEnteTextTheme(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: ValueListenableBuilder<ExactDuplicateProgress>(
          valueListenable: _service.progress,
          builder: (context, progress, _) {
            final hasTotal = progress.total > 0;
            final String title;
            final String detail;
            switch (progress.phase) {
              case ExactDuplicateScanPhase.sizing:
                title = "Checking file sizes";
                detail = hasTotal
                    ? "${progress.done} of ${progress.total} files"
                    : "";
              case ExactDuplicateScanPhase.hashing:
              case ExactDuplicateScanPhase.done:
                title = "Comparing file contents";
                detail = hasTotal
                    ? "${progress.done} of ${progress.total} files with "
                          "the same size as another file"
                    : "";
              case ExactDuplicateScanPhase.idle:
              case ExactDuplicateScanPhase.listing:
                title = "Reading the library";
                detail = "";
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: textTheme.largeBold),
                const SizedBox(height: Spacing.sm),
                Text(
                  detail,
                  style: textTheme.smallMuted,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Spacing.lg),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: hasTotal ? progress.done / progress.total : null,
                    color: context.componentColors.primary,
                    backgroundColor: getEnteColorScheme(context).fillFaint,
                  ),
                ),
                const SizedBox(height: Spacing.lg),
                Text(
                  "Only files with identical bytes are reported. Large "
                  "videos take the most time.",
                  style: textTheme.miniMuted,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Spacing.xl),
                ButtonComponent(
                  label: context.strings.cancel,
                  variant: ButtonComponentVariant.secondary,
                  shouldSurfaceExecutionStates: false,
                  onTap: _service.cancel,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMessage(String message) {
    final textTheme = getEnteTextTheme(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: textTheme.bodyMuted,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.xl),
            ButtonComponent(
              label: "Scan again",
              shouldSurfaceExecutionStates: false,
              onTap: _startScan,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: EmptyState(
          text: _skippedCount > 0
              ? "No exact duplicates found.\n"
                    "$_skippedCount files could not be read."
              : "No exact duplicates found.",
        ),
      );
    }
    final textTheme = getEnteTextTheme(context);
    final copyCount = _groups.fold<int>(
      0,
      (sum, group) => sum + group.copies.length - 1,
    );
    final reclaimable = _groups.fold<int>(
      0,
      (sum, group) => sum + group.reclaimableBytes,
    );
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _groups.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _crossAxisSpacing,
                    4,
                    _crossAxisSpacing,
                    16,
                  ),
                  child: Text(
                    "$copyCount extra ${copyCount == 1 ? "copy" : "copies"} "
                    "in ${_groups.length} "
                    "${_groups.length == 1 ? "group" : "groups"}, "
                    "${formatBytes(reclaimable)} in total. "
                    "Tap a copy to change what is deleted. "
                    "Hold a copy to open it.",
                    style: textTheme.smallMuted,
                  ),
                );
              }
              return _buildGroup(_groups[index - 1]);
            },
          ),
        ),
        _buildBottomActions(),
      ],
    );
  }

  Widget _buildGroup(ExactDuplicateGroup<EnteFile> group) {
    final textTheme = getEnteTextTheme(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _crossAxisSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "${group.copies.length} identical copies, "
            "${formatBytes(group.size)} each",
            style: textTheme.smallMuted.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth =
                  (constraints.maxWidth -
                      (_crossAxisSpacing * (_crossAxisCount - 1))) /
                  _crossAxisCount;
              return Wrap(
                spacing: _crossAxisSpacing,
                runSpacing: 0,
                children: [
                  for (final copy in group.copies)
                    SizedBox(
                      width: itemWidth,
                      child: _buildCopy(group, copy, itemWidth),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildCopy(
    ExactDuplicateGroup<EnteFile> group,
    DuplicateCopy<EnteFile> copy,
    double width,
  ) {
    final textTheme = getEnteTextTheme(context);
    final file = copy.item;
    final isSelected = _selectedIds.contains(copy.id);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggle(group, copy),
      onLongPress: () {
        final files = group.copies.map((c) => c.item).toList();
        routeToPage(
          context,
          DetailPage(
            DetailPageConfiguration(
              files,
              files.indexOf(file),
              _tagPrefix,
              mode: DetailPageMode.minimalistic,
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: width,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  tag: _tagPrefix + file.tag,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ThumbnailWidget(
                          file,
                          diskLoadDeferDuration:
                              galleryThumbnailDiskLoadDeferDuration,
                          serverLoadDeferDuration:
                              galleryThumbnailServerLoadDeferDuration,
                          shouldShowLivePhotoOverlay: true,
                          key: Key(_tagPrefix + file.tag),
                        ),
                        if (isSelected)
                          Container(color: Colors.black.withValues(alpha: 0.4)),
                      ],
                    ),
                  ),
                ),
                if (isSelected)
                  const Positioned(
                    top: 5,
                    right: 5,
                    child: SelectAllStatusIcon(
                      isSelected: true,
                      size: 18,
                      selectedFillColor: Colors.white,
                      selectedTickCutsOut: true,
                    ),
                  )
                else
                  Positioned(
                    top: 5,
                    left: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        "Keep",
                        style: textTheme.miniBold.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _folderOf(copy),
            style: textTheme.small,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            file.displayName,
            style: textTheme.miniMuted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// The folder of the copy, relative to the root of the shared storage.
  /// For example `DCIM/Camera` or `Download`.
  String _folderOf(DuplicateCopy<EnteFile> copy) {
    final path = copy.path;
    final lastSlash = path.lastIndexOf("/");
    if (lastSlash <= 0) {
      return copy.item.deviceFolder ?? "";
    }
    var folder = path.substring(0, lastSlash);
    final primary = RegExp(r"^/storage/emulated/\d+/?");
    final removable = RegExp(r"^/storage/([^/]+)/?");
    if (primary.hasMatch(folder)) {
      folder = folder.replaceFirst(primary, "");
    } else {
      final match = removable.firstMatch(folder);
      if (match != null) {
        // Keep the volume name for an SD card, to tell it from the phone.
        folder = "${match.group(1)}: ${folder.substring(match.end)}";
      }
    }
    return folder.isEmpty ? "Internal storage" : folder;
  }

  Widget _buildBottomActions() {
    var count = 0;
    var bytes = 0;
    var allSelected = true;
    for (final group in _groups) {
      final selected = _selectedCountIn(group);
      count += selected;
      bytes += selected * group.size;
      if (selected < group.copies.length - 1) allSelected = false;
    }
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: _crossAxisSpacing,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: getEnteColorScheme(context).backgroundColour,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (count > 0) ...[
              SizedBox(
                width: double.infinity,
                child: ButtonComponent(
                  label:
                      "Delete $count ${count == 1 ? "copy" : "copies"} "
                      "(${formatBytes(bytes)})",
                  variant: ButtonComponentVariant.critical,
                  shouldSurfaceExecutionStates: false,
                  onTap: _onDeleteTapped,
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: ButtonComponent(
                label: allSelected
                    ? context.strings.unselectAll
                    : context.strings.selectAll,
                variant: ButtonComponentVariant.secondary,
                shouldSurfaceExecutionStates: false,
                onTap: () {
                  setState(() {
                    if (allSelected) {
                      _selectedIds.clear();
                    } else {
                      _selectDefaults();
                    }
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onDeleteTapped() async {
    try {
      await _deleteSelected();
    } catch (e, s) {
      _logger.severe("Failed to delete exact duplicates", e, s);
      if (!mounted) return;
      showGenericErrorDialog(context: context, error: e).ignore();
    }
  }

  Future<void> _deleteSelected() async {
    // Check each group again immediately before the deletion. The scan can
    // be old, and a file can change or go away in the meantime.
    final toDelete = <DuplicateCopy<EnteFile>>[];
    var bytes = 0;
    var changedGroups = 0;
    for (final group in _groups) {
      final selected = group.copies
          .where((copy) => _selectedIds.contains(copy.id))
          .toList();
      if (selected.isEmpty) continue;
      // Never delete all copies, whatever the selection state is.
      if (selected.length >= group.copies.length) {
        changedGroups++;
        continue;
      }
      final changed = await _service.findChangedCopies(
        group.size,
        group.copies,
      );
      if (changed.isNotEmpty) {
        changedGroups++;
        continue;
      }
      toDelete.addAll(selected);
      bytes += selected.length * group.size;
    }
    if (!mounted) return;
    if (toDelete.isEmpty) {
      if (changedGroups > 0) {
        showShortToast(context, "Files changed after the scan. Scan again.");
      }
      return;
    }

    final count = toDelete.length;
    final confirmed = await showBottomSheetComponent<bool>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: "Delete $count duplicate ${count == 1 ? "copy" : "copies"}?",
        message:
            "This frees ${formatBytes(bytes)} on the device. "
            "One copy of each file stays on the device."
            "${changedGroups > 0 ? "\n\n$changedGroups ${changedGroups == 1 ? "group" : "groups"} changed after the scan and will be skipped." : ""}",
        closeTooltip: context.strings.close,
        actions: [
          ButtonComponent(
            label: "Delete $count ${count == 1 ? "copy" : "copies"}",
            variant: ButtonComponentVariant.critical,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
          ButtonComponent(
            label: context.strings.cancel,
            variant: ButtonComponentVariant.secondary,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(sheetContext).pop(false),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Moves the files to the device trash on Android 11 and later (permanent
    // deletion on older versions), removes them from the local database and
    // fires `LocalPhotosUpdatedEvent`, which updates the gallery.
    //
    // Android accepts at most 2000 items in one trash request, so a large
    // deletion goes in batches. Without the "manage media" permission, the
    // system asks the user to confirm each batch.
    final files = [for (final copy in toDelete) copy.item];
    final deletedIds = <String>{};
    for (var start = 0; start < files.length; start += _deleteBatchSize) {
      if (!mounted) return;
      final end = start + _deleteBatchSize < files.length
          ? start + _deleteBatchSize
          : files.length;
      final deleted = await deleteFilesOnDeviceOnly(
        context,
        files.sublist(start, end),
      );
      if (deleted.isEmpty) {
        // The user refused the system prompt, or the deletion failed.
        break;
      }
      for (final file in deleted) {
        if (file.localID != null) deletedIds.add(file.localID!);
      }
    }
    if (!mounted) return;
    setState(() {
      _removeDeleted(deletedIds);
    });
    if (deletedIds.isEmpty) {
      showShortToast(context, "No files were deleted");
      return;
    }
    await showMediaManagementHintSheet(context);
  }

  /// Drops the deleted copies from the list. A group with one copy left is
  /// not a duplicate group any more.
  void _removeDeleted(Set<String> deletedIds) {
    if (deletedIds.isEmpty) return;
    final remaining = <ExactDuplicateGroup<EnteFile>>[];
    for (final group in _groups) {
      final copies = group.copies
          .where((copy) => !deletedIds.contains(copy.id))
          .toList();
      if (copies.length == group.copies.length) {
        remaining.add(group);
      } else if (copies.length >= 2) {
        remaining.add(
          ExactDuplicateGroup<EnteFile>(
            size: group.size,
            hash: group.hash,
            copies: copies,
          ),
        );
      }
    }
    _groups = remaining;
    _selectedIds.removeAll(deletedIds);
    final liveIds = {
      for (final group in _groups)
        for (final copy in group.copies) copy.id,
    };
    _selectedIds.retainAll(liveIds);
  }
}

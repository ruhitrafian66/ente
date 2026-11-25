// Offline fork: "Recompress large JPGs" tool page.
//
// Offline fork: not localized. The new user-facing strings in this file are
// hardcoded English.

import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:logging/logging.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/jpeg_recompress_core.dart";
import "package:photos/services/jpeg_recompress_service.dart";
import "package:photos/ui/tools/jpeg_scan_report_page.dart";
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";
import "package:photos/utils/delete_file_util.dart";

enum _Stage { scanning, ready, running, done }

class JpegRecompressPage extends StatefulWidget {
  const JpegRecompressPage({super.key});

  @override
  State<JpegRecompressPage> createState() => _JpegRecompressPageState();
}

class _JpegRecompressPageState extends State<JpegRecompressPage> {
  static const _crossAxisCount = 3;
  static const _gridSpacing = 8.0;
  static const _maxListedProblems = 30;

  final _logger = Logger("JpegRecompressPage");

  _Stage _stage = _Stage.scanning;

  /// The large JPEGs that can be recompressed.
  List<JpegScanItem> _items = [];

  /// Large JPEGs that the tool leaves alone, by reason.
  Map<JpegSkipReason, int> _skipped = {};
  int _checked = 0;
  JpegScanResult? _scanResult;
  final Set<String> _selected = {};
  int _quality = kJpegRecompressDefaultQuality;
  Object? _scanError;

  int _scanDone = 0;
  int _scanTotal = 0;

  int _runDone = 0;
  int _runTotal = 0;
  String? _currentTitle;
  bool _cancelRequested = false;
  bool _isFinishing = false;

  JpegRecompressor? _converter;
  JpegRecompressSummary? _summary;
  bool _isResolvingKept = false;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    setState(() {
      _stage = _Stage.scanning;
      _scanError = null;
      _scanDone = 0;
      _scanTotal = 0;
      _summary = null;
    });
    try {
      final result = await JpegRecompressService.instance.scan(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _scanDone = done;
            _scanTotal = total;
          });
        },
      );
      if (!mounted) return;
      final items = <JpegScanItem>[];
      final skipped = <JpegSkipReason, int>{};
      for (final item in result.items) {
        final reason = item.candidate.skipReason;
        if (reason == null) {
          items.add(item);
        } else {
          skipped[reason] = (skipped[reason] ?? 0) + 1;
        }
      }
      setState(() {
        _items = items;
        _skipped = skipped;
        _checked = result.checked;
        _scanResult = result;
        _selected
          ..clear()
          ..addAll(items.map((item) => item.candidate.id));
        _stage = _Stage.ready;
      });
    } catch (e, s) {
      _logger.severe("JPEG scan failed", e, s);
      if (!mounted) return;
      setState(() {
        _items = [];
        _skipped = {};
        _checked = 0;
        _scanResult = null;
        _selected.clear();
        _scanError = e;
        _stage = _Stage.ready;
      });
    }
  }

  List<JpegScanItem> get _selectedItems =>
      _items.where((item) => _selected.contains(item.candidate.id)).toList();

  int get _totalBytes =>
      _items.fold(0, (sum, item) => sum + item.candidate.sizeBytes);

  int get _selectedBytes =>
      _selectedItems.fold(0, (sum, item) => sum + item.candidate.sizeBytes);

  int get _estimatedSaving => _selectedItems.fold(
    0,
    (sum, item) => sum + item.candidate.estimatedSavingBytes(_quality),
  );

  Future<void> _confirmAndRun() async {
    final selected = _selectedItems;
    if (selected.isEmpty) return;
    final confirmed = await showBottomSheetComponent<bool>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: "Recompress ${_images(selected.length)}?",
        message:
            "The app saves a smaller copy (quality $_quality) in the same "
            "folder. It compares each copy with its original, pixel by "
            "pixel, and keeps a copy only if the difference is not visible. "
            "If quality $_quality fails this check, the app tries quality "
            "$kJpegRecompressFallbackQuality.\n\n"
            "Then the app deletes the originals that have a good copy. "
            "Android moves them to the device trash if the device has a "
            "trash. If not, the delete is permanent. Android can ask you "
            "one time to permit the delete.",
        illustration: Image.asset("assets/warning-red.png"),
        closeTooltip: sheetContext.strings.close,
        actions: [
          ButtonComponent(
            label: "Recompress and delete originals",
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
    if (confirmed != true || !mounted) return;
    await _run(selected);
  }

  Future<List<EnteFile>> _deleteOriginals(List<EnteFile> files) async {
    if (!mounted) return [];
    return deleteFilesOnDeviceOnly(context, files);
  }

  Future<void> _run(List<JpegScanItem> selected) async {
    final converter = JpegRecompressService.instance.recompressor(
      items: selected,
      deleteOriginals: _deleteOriginals,
    );
    setState(() {
      _stage = _Stage.running;
      _converter = converter;
      _runDone = 0;
      _runTotal = selected.length;
      _currentTitle = null;
      _cancelRequested = false;
      _isFinishing = false;
    });

    JpegRecompressSummary summary;
    try {
      summary = await converter.run(
        selected.map((item) => item.candidate).toList(),
        quality: _quality,
        isCancelled: () => _cancelRequested,
        onProgress: (done, total, current) {
          if (!mounted) return;
          setState(() {
            _runDone = done;
            _runTotal = total;
            _currentTitle = current?.title;
            _isFinishing = current == null;
          });
        },
      );
    } catch (e, s) {
      _logger.severe("JPEG recompression run failed", e, s);
      summary = const JpegRecompressSummary(results: [], notProcessed: 0);
    }
    summary.results.forEach(JpegRecompressService.instance.logResult);
    await JpegRecompressService.instance.refreshGallery();
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _stage = _Stage.done;
    });
  }

  Future<void> _resolveKept({required bool rollBack}) async {
    final converter = _converter;
    final summary = _summary;
    if (converter == null || summary == null || _isResolvingKept) return;
    setState(() => _isResolvingKept = true);
    try {
      final updated = rollBack
          ? await converter.rollBack(summary)
          : await converter.retryDelete(summary);
      await JpegRecompressService.instance.refreshGallery();
      if (!mounted) return;
      setState(() => _summary = updated);
    } finally {
      if (mounted) {
        setState(() => _isResolvingKept = false);
      }
    }
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) {
        _selected.add(id);
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _items.length) {
        _selected.clear();
      } else {
        _selected.addAll(_items.map((item) => item.candidate.id));
      }
    });
  }

  String _images(int count) => count == 1 ? "1 image" : "$count images";

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final isRunning = _stage == _Stage.running;
    return PopScope(
      canPop: !isRunning,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && isRunning) {
          setState(() => _cancelRequested = true);
        }
      },
      child: Scaffold(
        backgroundColor: colors.backgroundBase,
        body: AppBarComponent(
          title: "Recompress large JPGs",
          backgroundColor: colors.backgroundBase,
          slivers: switch (_stage) {
            _Stage.scanning => [_centered(_buildScanning())],
            _Stage.ready =>
              _items.isEmpty ? [_centered(_buildEmpty())] : _buildReady(),
            _Stage.running => [_centered(_buildRunning())],
            _Stage.done => [
              SliverToBoxAdapter(child: _buildSummary(_summary!)),
            ],
          },
        ),
        bottomNavigationBar: _buildBottomBar(),
      ),
    );
  }

  Widget _centered(Widget child) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.xxl, 0, Spacing.xxl, 48),
        child: Center(child: child),
      ),
    );
  }

  Widget _buildScanning() {
    final colors = context.componentColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const LoadingComponent(size: LoadingComponentSize.large),
        const SizedBox(height: Spacing.lg),
        Text(
          _scanTotal == 0
              ? "Looking for large JPG images…"
              : "Checked $_scanDone of $_scanTotal JPG files",
          style: TextStyles.body.copyWith(color: colors.textLight),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    final colors = context.componentColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.image_outlined, size: 48, color: colors.textLight),
        const SizedBox(height: Spacing.lg),
        Text(
          _scanError == null
              ? "No JPG image is large for its pixel count"
              : "The scan failed",
          style: TextStyles.large.copyWith(color: colors.textBase),
          textAlign: TextAlign.center,
        ),
        if (_scanError != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            "$_scanError",
            style: TextStyles.mini.copyWith(color: colors.textLight),
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ] else ...[
          const SizedBox(height: Spacing.sm),
          Text(
            "Checked $_checked JPG files.",
            style: TextStyles.mini.copyWith(color: colors.textLight),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Spacing.sm),
          _buildSkippedLines(),
        ],
      ],
    );
  }

  Widget _buildSkippedLines() {
    final colors = context.componentColors;
    final lines = [
      for (final entry in _skipped.entries)
        "${entry.value} × ${entry.key.label}",
    ];
    final result = _scanResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (lines.isNotEmpty)
          Text(
            "Large, but not offered: ${lines.join(", ")}",
            style: TextStyles.mini.copyWith(color: colors.textLight),
          ),
        if (result != null && result.folders.isNotEmpty)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                routeToPage(context, JpegScanReportPage(result: result)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              child: Text(
                "Checked $_checked JPG files in ${result.folders.length} "
                "folders. Show the result for each folder",
                style: TextStyles.mini.copyWith(color: colors.primary),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildReady() {
    final colors = context.componentColors;
    final allSelected = _selected.length == _items.length;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            Spacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Spacing.lg),
                decoration: BoxDecoration(
                  color: colors.fillLight,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "${_images(_items.length)} · ${formatBytes(_totalBytes)}",
                      style: TextStyles.bodyBold.copyWith(
                        color: colors.textBase,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      "Selected: ${_selected.length} · "
                      "${formatBytes(_selectedBytes)}",
                      style: TextStyles.body.copyWith(color: colors.textLight),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      "Estimated saving: about "
                      "${formatBytes(_estimatedSaving)}",
                      style: TextStyles.body.copyWith(color: colors.textBase),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      "These images use at least "
                      "${kJpegRecompressMinBitsPerPixel.toStringAsFixed(0)} "
                      "bits for each pixel; a camera photo uses 2 to 3.5. The "
                      "estimate is rough. The app keeps a copy only if it is "
                      "at least 25% smaller and passes the picture check.",
                      style: TextStyles.mini.copyWith(color: colors.textLight),
                    ),
                    const SizedBox(height: Spacing.xs),
                    _buildSkippedLines(),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              Text(
                "JPG quality",
                style: TextStyles.bodyBold.copyWith(color: colors.textBase),
              ),
              const SizedBox(height: Spacing.sm),
              Wrap(
                spacing: Spacing.sm,
                children: [
                  for (final quality in kJpegRecompressQualityOptions)
                    FilterChipComponent(
                      label: quality == kJpegRecompressDefaultQuality
                          ? "$quality (default)"
                          : "$quality",
                      state: quality == _quality
                          ? FilterChipComponentState.selected
                          : FilterChipComponentState.unselected,
                      showSelectedTrailing: false,
                      onChanged: (_) => setState(() => _quality = quality),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Last modified first",
                    style: TextStyles.mini.copyWith(color: colors.textLight),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleAll,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                      child: Text(
                        allSelected
                            ? context.strings.deselectAll
                            : context.strings.selectAll,
                        style: TextStyles.bodyBold.copyWith(
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.xxl,
        ),
        sliver: SliverGrid.builder(
          itemCount: _items.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _crossAxisCount,
            crossAxisSpacing: _gridSpacing,
            mainAxisSpacing: _gridSpacing,
          ),
          itemBuilder: (context, index) => _buildTile(_items[index]),
        ),
      ),
    ];
  }

  Widget _buildTile(JpegScanItem item) {
    final colors = context.componentColors;
    final isSelected = _selected.contains(item.candidate.id);
    return GestureDetector(
      onTap: () => _toggle(item.candidate.id),
      onLongPress: () {
        HapticFeedback.lightImpact();
        final files = _items.map((item) => item.file).toList();
        routeToPage(
          context,
          DetailPage(
            DetailPageConfiguration(
              files,
              files.indexOf(item.file),
              "jpeg_recompress_",
              mode: DetailPageMode.minimalistic,
            ),
          ),
          forceCustomPageRoute: true,
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: "jpeg_recompress_" + item.file.tag,
              child: ThumbnailWidget(
                item.file,
                shouldShowSyncStatus: false,
                key: Key("jpeg_recompress_" + item.file.tag),
              ),
            ),
            if (!isSelected)
              ColoredBox(color: colors.backgroundBase.withValues(alpha: 0.45)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 12, 6, 4),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                  ),
                ),
                child: Text(
                  "${formatBytes(item.candidate.sizeBytes)} · "
                  "${(item.candidate.width * item.candidate.height / 1000000).toStringAsFixed(1)} MP",
                  style: TextStyles.mini.copyWith(color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                size: 22,
                color: isSelected ? colors.primary : Colors.white,
                shadows: const [Shadow(blurRadius: 4, color: Colors.black45)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunning() {
    final colors = context.componentColors;
    final String status;
    if (_isFinishing) {
      status = "Deleting the originals…";
    } else if (_cancelRequested) {
      status = "Stopping after the current image…";
    } else {
      status = "Recompressing ${_runDone + 1} of $_runTotal";
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.xs),
          child: LinearProgressIndicator(
            value: _runTotal == 0 ? null : _runDone / _runTotal,
            minHeight: 6,
            color: colors.primary,
            backgroundColor: colors.fillLight,
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          status,
          style: TextStyles.bodyBold.copyWith(color: colors.textBase),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          _isFinishing ? "" : (_currentTitle ?? ""),
          style: TextStyles.mini.copyWith(color: colors.textLight),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          "Keep the app open. The app deletes an original only after its "
          "copy is compared, saved and checked.",
          style: TextStyles.mini.copyWith(color: colors.textLight),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildSummary(JpegRecompressSummary summary) {
    final colors = context.componentColors;
    final converted = summary.count(JpegRecompressStatus.recompressed);
    final kept = summary.originalsKept.length;
    final rolledBack = summary.count(JpegRecompressStatus.rolledBack);
    final qualityLoss = summary.count(JpegRecompressStatus.skippedQualityLoss);
    final noSaving = summary.count(JpegRecompressStatus.skippedNoSaving);
    final notEligible = summary.count(JpegRecompressStatus.skippedNotEligible);
    final failed = summary.results
        .where((r) => r.status == JpegRecompressStatus.failed)
        .toList();

    Widget line(String label, String value, {Color? color}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyles.body.copyWith(
                  color: color ?? colors.textBase,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyles.bodyBold.copyWith(
                color: color ?? colors.textBase,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.sm,
        Spacing.lg,
        Spacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            converted == 0
                ? "No images recompressed"
                : "Saved ${formatBytes(summary.savedBytes)}",
            style: TextStyles.h2.copyWith(color: colors.textBase),
          ),
          const SizedBox(height: Spacing.md),
          line("Recompressed", "$converted"),
          if (qualityLoss > 0)
            line("Kept as is: a copy would lose detail", "$qualityLoss"),
          if (noSaving > 0) line("Kept as is: saving below 25%", "$noSaving"),
          if (notEligible > 0) line("Kept as is: not eligible", "$notEligible"),
          if (failed.isNotEmpty)
            line(
              "Failed (original kept)",
              "${failed.length}",
              color: colors.warning,
            ),
          if (rolledBack > 0)
            line("Copy removed, original kept", "$rolledBack"),
          if (summary.notProcessed > 0)
            line("Not started (cancelled)", "${summary.notProcessed}"),
          if (converted > 0) ...[
            const SizedBox(height: Spacing.md),
            Text(
              "If the device has a trash, the originals are in the device "
              "trash. They use storage until you empty the trash. Look at "
              "some of the new images before you empty the trash.",
              style: TextStyles.mini.copyWith(color: colors.textLight),
            ),
          ],
          if (summary.droppedIccProfiles > 0) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              "${summary.droppedIccProfiles} originals had a colour profile. "
              "The app converted their colours to sRGB. The new files do "
              "not contain the profile.",
              style: TextStyles.mini.copyWith(color: colors.textLight),
            ),
          ],
          if (kept > 0) ...[
            const SizedBox(height: Spacing.lg),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Spacing.lg),
              decoration: BoxDecoration(
                color: colors.fillLight,
                borderRadius: BorderRadius.circular(Radii.lg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "$kept originals are not deleted",
                    style: TextStyles.bodyBold.copyWith(color: colors.warning),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    "The copies are saved, but the device did not delete the "
                    "originals. The original and the copy are now both on "
                    "the device. Delete the originals again, or remove the "
                    "new copies.",
                    style: TextStyles.body.copyWith(color: colors.textBase),
                  ),
                  const SizedBox(height: Spacing.md),
                  ButtonComponent(
                    label: "Delete the originals",
                    variant: ButtonComponentVariant.critical,
                    isDisabled: _isResolvingKept,
                    shouldSurfaceExecutionStates: false,
                    onTap: () => _resolveKept(rollBack: false),
                  ),
                  const SizedBox(height: Spacing.sm),
                  ButtonComponent(
                    label: "Remove the new copies",
                    variant: ButtonComponentVariant.secondary,
                    isDisabled: _isResolvingKept,
                    shouldSurfaceExecutionStates: false,
                    onTap: () => _resolveKept(rollBack: true),
                  ),
                ],
              ),
            ),
          ],
          if (failed.isNotEmpty) ...[
            const SizedBox(height: Spacing.lg),
            Text(
              "Failed files",
              style: TextStyles.bodyBold.copyWith(color: colors.textBase),
            ),
            const SizedBox(height: Spacing.xs),
            for (final result in failed.take(_maxListedProblems))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  "${result.candidate.title}: ${result.message ?? "unknown"}",
                  style: TextStyles.mini.copyWith(color: colors.textLight),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (failed.length > _maxListedProblems)
              Text(
                "and ${failed.length - _maxListedProblems} more",
                style: TextStyles.mini.copyWith(color: colors.textLight),
              ),
          ],
        ],
      ),
    );
  }

  Widget? _buildBottomBar() {
    final colors = context.componentColors;
    final List<Widget> buttons;
    switch (_stage) {
      case _Stage.scanning:
        return null;
      case _Stage.ready:
        if (_items.isEmpty) {
          buttons = [
            ButtonComponent(
              label: "Scan again",
              variant: ButtonComponentVariant.secondary,
              shouldSurfaceExecutionStates: false,
              onTap: _scan,
            ),
          ];
        } else {
          buttons = [
            ButtonComponent(
              label: _selected.isEmpty
                  ? "Select images to recompress"
                  : "Recompress ${_images(_selected.length)}",
              isDisabled: _selected.isEmpty,
              shouldSurfaceExecutionStates: false,
              onTap: _confirmAndRun,
            ),
          ];
        }
      case _Stage.running:
        buttons = [
          ButtonComponent(
            label: context.strings.cancel,
            variant: ButtonComponentVariant.secondary,
            isDisabled: _cancelRequested || _isFinishing,
            shouldSurfaceExecutionStates: false,
            onTap: () => setState(() => _cancelRequested = true),
          ),
        ];
      case _Stage.done:
        buttons = [
          ButtonComponent(
            label: context.strings.done,
            shouldSurfaceExecutionStates: false,
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(height: Spacing.sm),
          ButtonComponent(
            label: "Scan again",
            variant: ButtonComponentVariant.secondary,
            isDisabled: _isResolvingKept,
            shouldSurfaceExecutionStates: false,
            onTap: _scan,
          ),
        ];
    }
    return SafeArea(
      child: Container(
        color: colors.backgroundBase,
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.sm,
          Spacing.lg,
          Spacing.sm,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: buttons),
      ),
    );
  }
}

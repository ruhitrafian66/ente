// Offline fork: "Convert PNG to JPG" tool page.
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
import "package:photos/services/png_to_jpg_core.dart";
import "package:photos/services/png_to_jpg_service.dart";
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";
import "package:photos/utils/delete_file_util.dart";

enum _Stage { scanning, ready, running, done }

class PngToJpgPage extends StatefulWidget {
  const PngToJpgPage({super.key});

  @override
  State<PngToJpgPage> createState() => _PngToJpgPageState();
}

class _PngToJpgPageState extends State<PngToJpgPage> {
  static const _crossAxisCount = 3;
  static const _gridSpacing = 8.0;
  static const _maxListedProblems = 30;

  final _logger = Logger("PngToJpgPage");

  _Stage _stage = _Stage.scanning;
  List<PngScanItem> _items = [];
  final Set<String> _selected = {};
  int _quality = kPngToJpgDefaultQuality;
  Object? _scanError;

  int _scanDone = 0;
  int _scanTotal = 0;

  int _runDone = 0;
  int _runTotal = 0;
  String? _currentTitle;
  bool _cancelRequested = false;
  bool _isFinishing = false;

  PngToJpgConverter? _converter;
  PngRunSummary? _summary;
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
      final items = await PngToJpgService.instance.scan(
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _scanDone = done;
            _scanTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _selected
          ..clear()
          ..addAll(items.map((item) => item.candidate.id));
        _stage = _Stage.ready;
      });
    } catch (e, s) {
      _logger.severe("PNG scan failed", e, s);
      if (!mounted) return;
      setState(() {
        _items = [];
        _selected.clear();
        _scanError = e;
        _stage = _Stage.ready;
      });
    }
  }

  List<PngScanItem> get _selectedItems =>
      _items.where((item) => _selected.contains(item.candidate.id)).toList();

  int get _totalBytes =>
      _items.fold(0, (sum, item) => sum + item.candidate.sizeBytes);

  int get _selectedBytes =>
      _selectedItems.fold(0, (sum, item) => sum + item.candidate.sizeBytes);

  int get _estimatedSaving => _selectedItems.fold(
    0,
    (sum, item) =>
        sum +
        estimateSavingBytes(
          pngBytes: item.candidate.sizeBytes,
          width: item.candidate.width,
          height: item.candidate.height,
          quality: _quality,
        ),
  );

  Future<void> _confirmAndRun() async {
    final selected = _selectedItems;
    if (selected.isEmpty) return;
    final confirmed = await showBottomSheetComponent<bool>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: "Convert ${_images(selected.length)} to JPG?",
        message:
            "The app saves a JPG copy (quality $_quality) in the same folder "
            "and checks each copy. Then the app deletes the original PNG "
            "files. Android moves the PNG files to the device trash if the "
            "device has a trash. If not, the delete is permanent.\n\n"
            "Android can ask you one time to permit the delete. The app does "
            "not convert images that have transparency.",
        illustration: Image.asset("assets/warning-red.png"),
        closeTooltip: sheetContext.strings.close,
        actions: [
          ButtonComponent(
            label: "Convert and delete originals",
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

  Future<void> _run(List<PngScanItem> selected) async {
    final converter = PngToJpgService.instance.converter(
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

    PngRunSummary summary;
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
      _logger.severe("PNG conversion run failed", e, s);
      summary = const PngRunSummary(results: [], notProcessed: 0);
    }
    for (final result in summary.results) {
      if (result.status == PngConversionStatus.failed) {
        _logger.warning("PNG conversion failed: ${result.message}");
      }
    }
    await PngToJpgService.instance.refreshGallery();
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
      await PngToJpgService.instance.refreshGallery();
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

  String _images(int count) => count == 1 ? "1 PNG image" : "$count PNG images";

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
          title: "Convert PNG to JPG",
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
              ? "Looking for PNG images…"
              : "Checked $_scanDone of $_scanTotal images",
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
              ? "No PNG images on this device"
              : "The scan failed",
          style: TextStyles.large.copyWith(color: colors.textBase),
          textAlign: TextAlign.center,
        ),
        _buildLeftOut(),
        if (_scanError != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            "$_scanError",
            style: TextStyles.mini.copyWith(color: colors.textLight),
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  /// Offline fork: why files with a .png name are not in the list.
  Widget _buildLeftOut() {
    final leftOut = PngToJpgService.instance.lastScanLeftOut;
    if (leftOut.isEmpty) return const SizedBox.shrink();
    final colors = context.componentColors;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Text(
        "Not listed: ${[for (final e in leftOut.entries) "${e.value} × ${e.key}"].join(", ")}. "
        "The list has only the PNG files that Android shows to the app "
        "(Settings > Free up space > File access).",
        style: TextStyles.mini.copyWith(color: colors.textLight),
      ),
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
                      "This is a rough estimate from the image dimensions. "
                      "The real saving can be different. The app keeps a JPG "
                      "only if it is at least 10% smaller than the PNG.",
                      style: TextStyles.mini.copyWith(color: colors.textLight),
                    ),
                    _buildLeftOut(),
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
                  for (final quality in kPngToJpgQualityOptions)
                    FilterChipComponent(
                      label: quality == kPngToJpgDefaultQuality
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

  Widget _buildTile(PngScanItem item) {
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
              "png_to_jpg_",
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
              tag: "png_to_jpg_" + item.file.tag,
              child: ThumbnailWidget(
                item.file,
                shouldShowSyncStatus: false,
                key: Key("png_to_jpg_" + item.file.tag),
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
                  formatBytes(item.candidate.sizeBytes),
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
      status = "Deleting the original PNG files…";
    } else if (_cancelRequested) {
      status = "Stopping after the current image…";
    } else {
      status = "Converting ${_runDone + 1} of $_runTotal";
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
          "Keep the app open. The app deletes a PNG only after its JPG copy "
          "is saved and checked.",
          style: TextStyles.mini.copyWith(color: colors.textLight),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildSummary(PngRunSummary summary) {
    final colors = context.componentColors;
    final converted = summary.count(PngConversionStatus.converted);
    final kept = summary.originalsKept.length;
    final rolledBack = summary.count(PngConversionStatus.rolledBack);
    final transparency = summary.count(PngConversionStatus.skippedTransparency);
    final noSaving = summary.count(PngConversionStatus.skippedNoSaving);
    final animated = summary.count(PngConversionStatus.skippedAnimated);
    final notPng = summary.count(PngConversionStatus.skippedNotPng);
    final failed = summary.results
        .where((r) => r.status == PngConversionStatus.failed)
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
                ? "No images converted"
                : "Saved ${formatBytes(summary.savedBytes)}",
            style: TextStyles.h2.copyWith(color: colors.textBase),
          ),
          const SizedBox(height: Spacing.md),
          line("Converted", "$converted"),
          if (transparency > 0)
            line("Skipped: has transparency", "$transparency"),
          if (noSaving > 0) line("Skipped: no saving", "$noSaving"),
          if (animated > 0) line("Skipped: animated PNG", "$animated"),
          if (notPng > 0) line("Skipped: not a PNG file", "$notPng"),
          if (failed.isNotEmpty)
            line(
              "Failed (PNG kept)",
              "${failed.length}",
              color: colors.warning,
            ),
          if (rolledBack > 0) line("JPG copy removed, PNG kept", "$rolledBack"),
          if (summary.notProcessed > 0)
            line("Not started (cancelled)", "${summary.notProcessed}"),
          if (converted > 0) ...[
            const SizedBox(height: Spacing.md),
            Text(
              "If the device has a trash, the original PNG files are in the "
              "device trash. They use storage until you empty the trash.",
              style: TextStyles.mini.copyWith(color: colors.textLight),
            ),
          ],
          if (summary.droppedIccProfiles > 0) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              "${summary.droppedIccProfiles} PNG files had a colour profile. "
              "The app converted their colours to sRGB. The JPG files do not "
              "contain the profile.",
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
                    "$kept original PNG files are not deleted",
                    style: TextStyles.bodyBold.copyWith(color: colors.warning),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    "The JPG copies are saved, but the device did not delete "
                    "the PNG files. The PNG and the JPG are now both on the "
                    "device. Delete the PNG files again, or remove the new "
                    "JPG copies.",
                    style: TextStyles.body.copyWith(color: colors.textBase),
                  ),
                  const SizedBox(height: Spacing.md),
                  ButtonComponent(
                    label: "Delete the PNG files",
                    variant: ButtonComponentVariant.critical,
                    isDisabled: _isResolvingKept,
                    shouldSurfaceExecutionStates: false,
                    onTap: () => _resolveKept(rollBack: false),
                  ),
                  const SizedBox(height: Spacing.sm),
                  ButtonComponent(
                    label: "Remove the new JPG copies",
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
                  ? "Select images to convert"
                  : "Convert ${_images(_selected.length)}",
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

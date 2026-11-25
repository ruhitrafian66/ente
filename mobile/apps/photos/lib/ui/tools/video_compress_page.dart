// Offline fork: "Compress videos" tool page.
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
import "package:photos/services/video_compress_core.dart";
import "package:photos/services/video_compress_service.dart";
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";
import "package:photos/utils/delete_file_util.dart";
import "package:wakelock_plus/wakelock_plus.dart";

enum _Stage { scanning, ready, running, done }

class VideoCompressPage extends StatefulWidget {
  const VideoCompressPage({super.key});

  @override
  State<VideoCompressPage> createState() => _VideoCompressPageState();
}

class _VideoCompressPageState extends State<VideoCompressPage> {
  static const _crossAxisCount = 3;
  static const _gridSpacing = 8.0;
  static const _maxListedProblems = 30;

  final _logger = Logger("VideoCompressPage");

  _Stage _stage = _Stage.scanning;

  /// Every readable video on the device.
  List<VideoScanItem> _allItems = [];
  int _unreadable = 0;

  /// The videos that are worth a re-encode with [_preset].
  List<VideoScanItem> _items = [];
  Map<String, VideoCompressPlan> _plans = {};
  Map<VideoSkipReason, int> _skipped = {};
  final Set<String> _selected = {};
  VideoCompressPreset _preset = VideoCompressPreset.balanced;
  Object? _scanError;

  int _scanDone = 0;
  int _scanTotal = 0;

  int _runDone = 0;
  int _runTotal = 0;
  double _fileFraction = 0;
  String? _currentTitle;
  bool _cancelRequested = false;
  bool _isFinishing = false;

  VideoCompressor? _compressor;
  VideoCompressSummary? _summary;
  bool _isResolvingKept = false;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  @override
  void dispose() {
    if (_stage == _Stage.running) {
      unawaited(VideoCompressService.instance.cancelEncode());
      unawaited(WakelockPlus.disable());
    }
    super.dispose();
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
      final result = await VideoCompressService.instance.scan(
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
        _allItems = result.items;
        _unreadable = result.unreadable;
        _applyPreset(_preset);
        _stage = _Stage.ready;
      });
    } catch (e, s) {
      _logger.severe("Video scan failed", e, s);
      if (!mounted) return;
      setState(() {
        _allItems = [];
        _unreadable = 0;
        _applyPreset(_preset);
        _scanError = e;
        _stage = _Stage.ready;
      });
    }
  }

  /// Call inside setState. Selects every eligible video.
  void _applyPreset(VideoCompressPreset preset) {
    _preset = preset;
    final items = <VideoScanItem>[];
    final plans = <String, VideoCompressPlan>{};
    final skipped = <VideoSkipReason, int>{};
    for (final item in _allItems) {
      final plan = item.candidate.plan(preset);
      final reason = plan.skipReason;
      if (reason != null) {
        skipped[reason] = (skipped[reason] ?? 0) + 1;
        continue;
      }
      items.add(item);
      plans[item.candidate.id] = plan;
    }
    _items = items;
    _plans = plans;
    _skipped = skipped;
    _selected
      ..clear()
      ..addAll(items.map((item) => item.candidate.id));
  }

  List<VideoScanItem> get _selectedItems =>
      _items.where((item) => _selected.contains(item.candidate.id)).toList();

  int get _totalBytes =>
      _items.fold(0, (sum, item) => sum + item.candidate.sizeBytes);

  int get _selectedBytes =>
      _selectedItems.fold(0, (sum, item) => sum + item.candidate.sizeBytes);

  int get _estimatedSaving => _selectedItems.fold(
    0,
    (sum, item) => sum + (_plans[item.candidate.id]?.estimatedSavingBytes ?? 0),
  );

  Duration get _selectedDuration => Duration(
    milliseconds: _selectedItems.fold(
      0,
      (sum, item) => sum + item.candidate.facts.durationMs,
    ),
  );

  Future<void> _confirmAndRun() async {
    final selected = _selectedItems;
    if (selected.isEmpty) return;
    final confirmed = await showBottomSheetComponent<bool>(
      context: context,
      builder: (sheetContext) => BottomSheetComponent(
        title: "Compress ${_videos(selected.length)}?",
        message:
            "The app saves an HEVC copy of each video in the same folder and "
            "checks each copy. Then the app deletes the original videos. "
            "Android moves the originals to the device trash if the device "
            "has a trash. If not, the delete is permanent.\n\n"
            "The copy has the same dimensions, frame rate and audio. The "
            "picture is encoded again, so a very small loss of detail is "
            "possible. Android can ask you one time to permit the delete. "
            "The originals and the copies are on the device together until "
            "the run ends, so the device needs free storage for the copies.",
        illustration: Image.asset("assets/warning-red.png"),
        closeTooltip: sheetContext.strings.close,
        actions: [
          ButtonComponent(
            label: "Compress and delete originals",
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

  Future<void> _run(List<VideoScanItem> selected) async {
    final compressor = VideoCompressService.instance.compressor(
      items: selected,
      deleteOriginals: _deleteOriginals,
    );
    setState(() {
      _stage = _Stage.running;
      _compressor = compressor;
      _runDone = 0;
      _runTotal = selected.length;
      _fileFraction = 0;
      _currentTitle = null;
      _cancelRequested = false;
      _isFinishing = false;
    });

    VideoCompressSummary summary;
    unawaited(WakelockPlus.enable());
    try {
      summary = await compressor.run(
        selected.map((item) => item.candidate).toList(),
        preset: _preset,
        isCancelled: () => _cancelRequested,
        onProgress: (done, total, current, fileFraction) {
          if (!mounted) return;
          setState(() {
            _runDone = done;
            _runTotal = total;
            _fileFraction = fileFraction;
            _currentTitle = current?.title;
            _isFinishing = current == null;
          });
        },
      );
    } catch (e, s) {
      _logger.severe("Video compression run failed", e, s);
      summary = const VideoCompressSummary(results: [], notProcessed: 0);
    } finally {
      unawaited(WakelockPlus.disable());
    }
    for (final result in summary.results) {
      if (result.status == VideoCompressStatus.failed) {
        _logger.warning(
          "Video compression failed for ${result.candidate.title}: "
          "${result.message}",
        );
      }
    }
    await VideoCompressService.instance.refreshGallery();
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _stage = _Stage.done;
    });
  }

  void _requestCancel() {
    if (_cancelRequested) return;
    setState(() => _cancelRequested = true);
    unawaited(VideoCompressService.instance.cancelEncode());
  }

  Future<void> _resolveKept({required bool rollBack}) async {
    final compressor = _compressor;
    final summary = _summary;
    if (compressor == null || summary == null || _isResolvingKept) return;
    setState(() => _isResolvingKept = true);
    try {
      final updated = rollBack
          ? await compressor.rollBack(summary)
          : await compressor.retryDelete(summary);
      await VideoCompressService.instance.refreshGallery();
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

  String _videos(int count) => count == 1 ? "1 video" : "$count videos";

  String _durationText(Duration duration) {
    if (duration.inHours > 0) {
      return "${duration.inHours} h ${duration.inMinutes % 60} min";
    }
    if (duration.inMinutes > 0) {
      return "${duration.inMinutes} min ${duration.inSeconds % 60} s";
    }
    return "${duration.inSeconds} s";
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final isRunning = _stage == _Stage.running;
    return PopScope(
      canPop: !isRunning,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && isRunning) {
          _requestCancel();
        }
      },
      child: Scaffold(
        backgroundColor: colors.backgroundBase,
        body: AppBarComponent(
          title: "Compress videos",
          backgroundColor: colors.backgroundBase,
          slivers: switch (_stage) {
            _Stage.scanning => [_centered(_buildScanning())],
            _Stage.ready => _buildReady(),
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
              ? "Looking for videos…"
              : "Checked $_scanDone of $_scanTotal videos",
          style: TextStyles.body.copyWith(color: colors.textLight),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildPresetChips() {
    return Wrap(
      spacing: Spacing.sm,
      children: [
        for (final preset in VideoCompressPreset.values)
          FilterChipComponent(
            label: preset == VideoCompressPreset.balanced
                ? "${preset.label} (default)"
                : preset.label,
            state: preset == _preset
                ? FilterChipComponentState.selected
                : FilterChipComponentState.unselected,
            showSelectedTrailing: false,
            onChanged: (_) => setState(() => _applyPreset(preset)),
          ),
      ],
    );
  }

  Widget _buildSkippedLines() {
    final colors = context.componentColors;
    final lines = <String>[
      for (final entry in _skipped.entries)
        "${entry.value} × ${entry.key.label}",
      if (_unreadable > 0) "$_unreadable × Could not read the file",
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Text(
      "Not offered: ${lines.join(", ")}",
      style: TextStyles.mini.copyWith(color: colors.textLight),
    );
  }

  List<Widget> _buildReady() {
    final colors = context.componentColors;
    if (_items.isEmpty) {
      return [
        _centered(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_outlined, size: 48, color: colors.textLight),
              const SizedBox(height: Spacing.lg),
              Text(
                _scanError != null
                    ? "The scan failed"
                    : _allItems.isEmpty && _unreadable == 0
                    ? "No videos on this device"
                    : "No video is worth a re-encode",
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
              ],
              const SizedBox(height: Spacing.md),
              _buildSkippedLines(),
              if (_allItems.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                _buildPresetChips(),
              ],
            ],
          ),
        ),
      ];
    }
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
                      "${_videos(_items.length)} · ${formatBytes(_totalBytes)}",
                      style: TextStyles.bodyBold.copyWith(
                        color: colors.textBase,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      "Selected: ${_selected.length} · "
                      "${formatBytes(_selectedBytes)} · "
                      "${_durationText(_selectedDuration)}",
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
                      "The app encodes the picture again as HEVC. The "
                      "dimensions, the frame rate and the audio do not "
                      "change. The app keeps a copy only if it is at least "
                      "20% smaller than the original.",
                      style: TextStyles.mini.copyWith(color: colors.textLight),
                    ),
                    const SizedBox(height: Spacing.xs),
                    _buildSkippedLines(),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              Text(
                "Quality",
                style: TextStyles.bodyBold.copyWith(color: colors.textBase),
              ),
              const SizedBox(height: Spacing.sm),
              _buildPresetChips(),
              const SizedBox(height: Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Largest first",
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

  Widget _buildTile(VideoScanItem item) {
    final colors = context.componentColors;
    final isSelected = _selected.contains(item.candidate.id);
    final saving = _plans[item.candidate.id]?.estimatedSavingBytes ?? 0;
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
              "video_compress_",
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
              tag: "video_compress_" + item.file.tag,
              child: ThumbnailWidget(
                item.file,
                shouldShowSyncStatus: false,
                key: Key("video_compress_" + item.file.tag),
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
                  "${formatBytes(item.candidate.sizeBytes)} "
                  "(-${formatBytes(saving)})",
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
      status = "Deleting the original videos…";
    } else if (_cancelRequested) {
      status = "Stopping…";
    } else {
      status =
          "Compressing ${_runDone + 1} of $_runTotal "
          "(${(_fileFraction * 100).round()}%)";
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.xs),
          child: LinearProgressIndicator(
            value: _runTotal == 0
                ? null
                : ((_runDone + (_isFinishing ? 0 : _fileFraction)) / _runTotal)
                      .clamp(0.0, 1.0),
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
          "copy is saved and checked. A cancel stops the current video and "
          "keeps its original.",
          style: TextStyles.mini.copyWith(color: colors.textLight),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildSummary(VideoCompressSummary summary) {
    final colors = context.componentColors;
    final compressed = summary.count(VideoCompressStatus.compressed);
    final kept = summary.originalsKept.length;
    final rolledBack = summary.count(VideoCompressStatus.rolledBack);
    final noSaving = summary.count(VideoCompressStatus.skippedNoSaving);
    final notEligible = summary.count(VideoCompressStatus.skippedNotEligible);
    final failed = summary.results
        .where((r) => r.status == VideoCompressStatus.failed)
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
            compressed == 0
                ? "No videos compressed"
                : "Saved ${formatBytes(summary.savedBytes)}",
            style: TextStyles.h2.copyWith(color: colors.textBase),
          ),
          const SizedBox(height: Spacing.md),
          line("Compressed", "$compressed"),
          if (noSaving > 0) line("Skipped: saving below 20%", "$noSaving"),
          if (notEligible > 0) line("Skipped: not eligible", "$notEligible"),
          if (failed.isNotEmpty)
            line(
              "Failed (original kept)",
              "${failed.length}",
              color: colors.warning,
            ),
          if (rolledBack > 0)
            line("Copy removed, original kept", "$rolledBack"),
          if (summary.notProcessed > 0)
            line("Not done (cancelled)", "${summary.notProcessed}"),
          if (compressed > 0) ...[
            const SizedBox(height: Spacing.md),
            Text(
              "If the device has a trash, the original videos are in the "
              "device trash. They use storage until you empty the trash. "
              "Play some of the new videos before you empty the trash.",
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
                    "$kept original videos are not deleted",
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
                  ? "Select videos to compress"
                  : "Compress ${_videos(_selected.length)}",
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
            onTap: _requestCancel,
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

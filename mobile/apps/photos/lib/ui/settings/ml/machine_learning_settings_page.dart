import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:ente_ui/components/loading_widget.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/files_db.dart";
import "package:photos/db/ml/db.dart";
import "package:photos/events/notification_event.dart";
import "package:photos/events/tab_changed_event.dart";
import "package:photos/models/home_tab.dart";
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/ml_indexing_isolate.dart";
import "package:photos/services/machine_learning/ml_model_download_service.dart";
import "package:photos/services/machine_learning/ml_run_control.dart";
import "package:photos/services/machine_learning/ml_service.dart";
import "package:photos/services/wake_lock_service.dart";
import "package:photos/ui/settings/ml/ml_consent_sheet.dart";
import "package:photos/ui/settings/ml/ml_user_dev_screen.dart";
import "package:photos/utils/log_export_util.dart";
import "package:photos/utils/ml_util.dart";

class MachineLearningSettingsPage extends StatefulWidget {
  const MachineLearningSettingsPage({super.key});

  @override
  State<MachineLearningSettingsPage> createState() =>
      _MachineLearningSettingsPageState();
}

class _MachineLearningSettingsPageState
    extends State<MachineLearningSettingsPage> {
  static final _logger = Logger("MachineLearningSettingsPage");
  Timer? _timer;
  int _titleTapCount = 0;
  Timer? _advancedOptionsTimer;
  bool _hasAcknowledgedMLConsent = false;
  bool _isEnabling = false;
  bool _mlDecryptionRecordsReady = false;

  @override
  void initState() {
    super.initState();
    unawaited(_pruneMlDecryptionRecords());
    wakeLockService.updateWakeLock(
      enable: true,
      wakeLockFor: WakeLockFor.machineLearningSettingsScreen,
    );
    computeController.forceOverrideML(turnOn: true);
    if (!MLModelDownloadService.instance.areModelsDownloaded(
      onlyIndexingModels: false,
    )) {
      _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
        if (mounted) {
          setState(() {});
        }
      });
    }
    _advancedOptionsTimer = Timer.periodic(const Duration(seconds: 7), (timer) {
      _titleTapCount = 0;
    });
  }

  Future<void> _pruneMlDecryptionRecords() async {
    final recordedFileIDs = mlDecryptionRecordStore.fileIDs;
    try {
      final staleFileIDs = <int>{};
      if (recordedFileIDs.isNotEmpty) {
        await MLDataDB.instance.pruneResolvedFaceErrorResults(recordedFileIDs);
        final existingFiles = await FilesDB.instance.getFileIDToFileFromIDs(
          recordedFileIDs,
        );
        final errorResultFileIDs = await MLDataDB.instance
            .getFileIDsWithErrorResults(recordedFileIDs);
        staleFileIDs.addAll(
          recordedFileIDs.where(
            (fileID) =>
                !existingFiles.containsKey(fileID) ||
                !errorResultFileIDs.contains(fileID),
          ),
        );
      }
      await mlDecryptionRecordStore.removeAll(staleFileIDs);
    } catch (error, stackTrace) {
      _logger.warning(
        "Failed to prune ML decryption records",
        error,
        stackTrace,
      );
    } finally {
      mlDecryptionRecordStore.logFileIDs();
      if (mounted) {
        setState(() => _mlDecryptionRecordsReady = true);
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    wakeLockService.updateWakeLock(
      enable: false,
      wakeLockFor: WakeLockFor.machineLearningSettingsScreen,
    );
    computeController.forceOverrideML(turnOn: false);
    _timer?.cancel();
    _advancedOptionsTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final hasEnabled = hasGrantedMLConsent;

    if (!hasEnabled || _isEnabling) {
      return _buildDisabledMLScreen(context);
    }

    return _buildEnabledMLScreen(context);
  }

  Widget _buildEnabledMLScreen(BuildContext context) {
    final colors = context.componentColors;

    return SettingsPageScaffold(
      title: context.strings.machineLearning,
      onTitleTap: _handleEnabledTitleTap,
      children: [
        Text(
          context.strings.mlIndexingDescription,
          textAlign: TextAlign.left,
          style: TextStyles.mini.copyWith(color: colors.textLight),
        ),
        const SizedBox(height: 20),
        _getMlSettings(context),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildDisabledMLScreen(BuildContext context) {
    return PopScope(
      canPop: !_isEnabling,
      child: SettingsPageScaffold(
        title: context.strings.machineLearning,
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ButtonComponent(
                  label: context.strings.mlConsent,
                  isDisabled: !_hasAcknowledgedMLConsent,
                  onTap: _enableAndOpenSearch,
                ),
                const SizedBox(height: Spacing.md),
                MLConsentCancelLink(
                  onTap: _isEnabling ? null : _declineAndClose,
                ),
              ],
            ),
          ),
        ),
        children: [
          const MLConsentDescription(),
          const SizedBox(height: 20),
          Center(
            child: Image.asset(
              "assets/ducky_ml.png",
              height: 150,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 20),
          MLConsentAcknowledgement(
            selected: _hasAcknowledgedMLConsent,
            onChanged: () {
              if (_isEnabling) return;
              setState(() {
                _hasAcknowledgedMLConsent = !_hasAcknowledgedMLConsent;
              });
            },
          ),
        ],
      ),
    );
  }

  void _handleEnabledTitleTap() {
    var shouldOpenDeveloperOptions = false;
    setState(() {
      _titleTapCount++;
      if (_titleTapCount >= 7) {
        _titleTapCount = 0;
        shouldOpenDeveloperOptions = true;
      }
    });

    if (!shouldOpenDeveloperOptions) {
      return;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const MLUserDeveloperOptions(mlIsEnabled: true);
            },
          ),
        )
        .ignore();
  }

  Future<void> _enableAndOpenSearch() async {
    setState(() => _isEnabling = true);
    try {
      await enableMLConsent();
    } catch (_) {
      if (mounted) {
        setState(() => _isEnabling = false);
      }
      rethrow;
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).popUntil((route) => route.isFirst && !route.willHandlePopInternally);
    Bus.instance.fire(
      TabChangedEvent(searchTabIndex, TabChangedEventSource.mlConsent),
    );
  }

  void _declineAndClose() {
    unawaited(markMLConsentPromptSeen());
    Navigator.of(context).pop();
  }

  Future<void> _disableMl() async {
    final wasMlEnabled = localSettings.isMLLocalIndexingEnabled;
    await setMLConsent(false);
    // Queue a memories cache refresh so People/Clip memories disappear on the
    // next scheduled recompute. We intentionally only queue here — the actual
    // recompute will be picked up by the next updateCache invocation.
    memoriesCacheService.queueUpdateCache();
    Bus.instance.fire(NotificationEvent());
    MLService.instance.stopActiveRun(MlStopReason.manual);
    unawaited(MLIndexingIsolate.instance.cleanupLocalIndexingModels());
    if (wasMlEnabled) {
      await memoriesCacheService.purgeMlOnlyMemoriesFromCache();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Widget _getMlSettings(BuildContext context) {
    final hasEnabled = hasGrantedMLConsent;
    if (!hasEnabled) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        MenuComponent(
          title: context.strings.enabled,
          leading: const HugeIcon(
            icon: HugeIcons.strokeRoundedToggleOn,
            size: IconSizes.small,
          ),
          trailing: ToggleSwitchComponent.async(
            value: () => hasEnabled,
            onChanged: _disableMl,
          ),
        ),
        const SizedBox(height: 8),
        MenuComponent(
          title: context.strings.localIndexing,
          leading: const HugeIcon(
            icon: HugeIcons.strokeRoundedCpu,
            size: IconSizes.small,
          ),
          trailing: ToggleSwitchComponent.async(
            value: () => localSettings.isMLLocalIndexingEnabled,
            onChanged: () async {
              final oldMlEnabled =
                  hasGrantedMLConsent && localSettings.isMLLocalIndexingEnabled;
              final localIndexing = await localSettings.toggleLocalMLIndexing();
              final newMlEnabled = hasGrantedMLConsent && localIndexing;
              memoriesCacheService.queueUpdateCache();
              Bus.instance.fire(NotificationEvent());
              if (localIndexing) {
                unawaited(MLService.instance.runAllML(force: true));
              } else {
                MLService.instance.stopActiveRun(MlStopReason.manual);
                unawaited(
                  MLIndexingIsolate.instance.cleanupLocalIndexingModels(),
                );
                if (oldMlEnabled && !newMlEnabled) {
                  await memoriesCacheService.purgeMlOnlyMemoriesFromCache();
                }
              }

              if (mounted) {
                setState(() {});
              }
            },
          ),
        ),
        const SizedBox(height: 12),
        MLModelDownloadService.instance.areModelsDownloaded(
                  onlyIndexingModels: true,
                ) ||
                !localSettings.isMLLocalIndexingEnabled
            ? MLStatusWidget(showDecryptionWarning: _mlDecryptionRecordsReady)
            : const ModelLoadingState(),
      ],
    );
  }
}

class ModelLoadingState extends StatefulWidget {
  const ModelLoadingState({super.key});

  @override
  State<ModelLoadingState> createState() => _ModelLoadingStateState();
}

class _ModelLoadingStateState extends State<ModelLoadingState> {
  Timer? _timer;

  @override
  void initState() {
    _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
      setState(() {});
    });
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    _timer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    // Offline fork: the models are in the APK, so there is no wait for Wi-Fi.
    MLModelDownloadService.instance.triggerModelsDownload(
      onlyIndexingModels: false,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: Spacing.sm, top: 6, bottom: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.strings.status.toUpperCase(),
              style: TextStyles.mini.copyWith(color: colors.textLight),
            ),
          ),
        ),
        const SizedBox(height: 8),
        MenuComponent(
          title: context.strings.checkingModels,
          leading: const HugeIcon(
            icon: HugeIcons.strokeRoundedCloudDownload,
            size: IconSizes.small,
          ),
          trailing: EnteLoadingWidget(size: 12, color: colors.fillDark),
        ),
      ],
    );
  }
}

class MLStatusWidget extends StatefulWidget {
  final bool showDecryptionWarning;

  const MLStatusWidget({required this.showDecryptionWarning, super.key});

  @override
  State<MLStatusWidget> createState() => MLStatusWidgetState();
}

class MLStatusWidgetState extends State<MLStatusWidget> {
  Timer? _timer;
  bool _isDeviceHealthy = computeController.isDeviceHealthy;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
      MLService.instance.triggerML();
      _isDeviceHealthy = computeController.isDeviceHealthy;
      setState(() {});
    });
  }

  Future<IndexStatus> _getIndexStatus() async {
    final status = await getIndexStatus();
    return status;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final decryptionIssueCount = widget.showDecryptionWarning
        ? mlDecryptionRecordStore.count
        : 0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: Spacing.sm, top: 6, bottom: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.strings.status.toUpperCase(),
              style: TextStyles.mini.copyWith(color: colors.textLight),
            ),
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder(
          future: _getIndexStatus(),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              final int indexedFiles = snapshot.data!.indexedItems;
              final int pendingFiles = snapshot.data!.pendingItems;
              final int total = indexedFiles + pendingFiles;

              if (!_isDeviceHealthy && pendingFiles > 0) {
                return Text(
                  context.strings.indexingPausedStatusDescription,
                  style: TextStyles.mini.copyWith(color: colors.textLight),
                );
              }

              return Column(
                children: [
                  MenuComponent(
                    key: ValueKey("pending_items_$pendingFiles"),
                    title: context.strings.processed,
                    leading: const HugeIcon(
                      icon: HugeIcons.strokeRoundedClock01,
                      size: IconSizes.small,
                    ),
                    trailing: Text(
                      total < 1
                          ? 'NA'
                          : pendingFiles == 0
                          ? '100%'
                          : '${(indexedFiles * 100.0 / total * 1.0).toStringAsFixed(2)}%',
                      style: TextStyles.mini.copyWith(color: colors.textLight),
                    ),
                  ),
                  if (MLService.instance.showClusteringIsHappening)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: MenuComponent(
                        title: context.strings.clusteringProgress,
                        leading: const HugeIcon(
                          icon: HugeIcons.strokeRoundedSparkles,
                          size: IconSizes.small,
                        ),
                        trailing: Text(
                          context.strings.currentlyRunning,
                          style: TextStyles.mini.copyWith(
                            color: colors.textLight,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            }
            return const EnteLoadingWidget();
          },
        ),
        const SizedBox(height: 8),
        const _ClipModelRow(),
        if (decryptionIssueCount > 0) ...[
          const SizedBox(height: 8),
          _MLProcessingIssuesBlurb(itemCount: decryptionIssueCount),
        ],
      ],
    );
  }
}

/// Offline fork: state of the CLIP (magic search) models, and the only place
/// that starts their download. Not localized.
class _ClipModelRow extends StatefulWidget {
  const _ClipModelRow();

  @override
  State<_ClipModelRow> createState() => _ClipModelRowState();
}

class _ClipModelRowState extends State<_ClipModelRow> {
  @override
  void initState() {
    super.initState();
    unawaited(MLModelDownloadService.instance.activateClipFromDisk());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return ValueListenableBuilder<ClipModelStatus>(
      valueListenable: MLModelDownloadService.instance.clipStatus,
      builder: (context, status, _) {
        if (status.phase == ClipModelPhase.off) {
          return const SizedBox.shrink();
        }
        final megabytes = (kOfflineClipDownloadBytes / (1024 * 1024)).round();
        final (String subtitle, String trailing) = switch (status.phase) {
          ClipModelPhase.notDownloaded => (
            "Search by image content. Tap to download the model "
                "($megabytes MB) from models.ente.com.",
            "Download",
          ),
          ClipModelPhase.downloading => (
            "The download continues while the app is open.",
            "${(status.fraction * 100).round()}%",
          ),
          ClipModelPhase.ready => ("The model is on this device.", "Ready"),
          ClipModelPhase.failed => (
            "The download failed. Tap to try again.",
            "Retry",
          ),
          ClipModelPhase.off => ("", ""),
        };
        final canStart =
            status.phase == ClipModelPhase.notDownloaded ||
            status.phase == ClipModelPhase.failed;
        return MenuComponent(
          title: "Magic search model",
          subtitle: subtitle,
          subtitleMaxLines: 3,
          leading: const HugeIcon(
            icon: HugeIcons.strokeRoundedCloudDownload,
            size: IconSizes.small,
          ),
          trailing: Text(
            trailing,
            style: TextStyles.mini.copyWith(
              color: canStart ? colors.primary : colors.textLight,
            ),
          ),
          onTap: canStart
              ? () => MLModelDownloadService.instance.requestClipDownload()
              : null,
        );
      },
    );
  }
}

class _MLProcessingIssuesBlurb extends StatelessWidget {
  final int itemCount;

  const _MLProcessingIssuesBlurb({required this.itemCount});

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.fillLight,
        borderRadius: BorderRadius.circular(Radii.button),
      ),
      child: Padding(
        padding: const EdgeInsets.only(
          left: Spacing.lg,
          top: Spacing.lg,
          right: Spacing.lg,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.cautionLight,
                shape: BoxShape.circle,
              ),
              child: SizedBox.square(
                dimension: 32,
                child: Center(
                  child: HugeIcon(
                    icon: HugeIcons.strokeRoundedAlert02,
                    size: IconSizes.small,
                    color: colors.caution,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.strings.mlCouldNotProcessItems(count: itemCount),
                    style: TextStyles.bodyBold.copyWith(color: colors.textBase),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    context.strings.mlProcessingIssueReachOut,
                    style: TextStyles.mini.copyWith(color: colors.textLight),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      mlDecryptionRecordStore.logFileIDs();
                      // Offline fork: was an e-mail to support with the logs.
                      showLogsDialog(context);
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: Spacing.sm,
                        bottom: Spacing.lg,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.strings.exportLogs,
                            style: TextStyles.bodyBold.copyWith(
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(width: Spacing.xs),
                          HugeIcon(
                            icon: HugeIcons.strokeRoundedArrowRight01,
                            color: colors.primary,
                            size: 16,
                            strokeWidth: 1.6,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

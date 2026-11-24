import "dart:async";
import "dart:io";

import "package:ente_ui/components/loading_widget.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:media_kit/media_kit.dart";
import "package:media_kit_video/media_kit_video.dart";
import "package:photos/core/constants.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/guest_view_event.dart";
import "package:photos/events/pause_video_event.dart";
import "package:photos/events/resume_video_event.dart";
import "package:photos/events/video_mute_changed_event.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/module/download/file.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/wake_lock_service.dart";
import "package:photos/states/detail_page_state.dart";
import "package:photos/theme/colors.dart";
import "package:photos/ui/actions/file/file_actions.dart";
import "package:photos/ui/viewer/file/video_widget_media_kit_common.dart"
    as common;

class VideoWidgetMediaKit extends StatefulWidget {
  final EnteFile file;
  final String? tagPrefix;
  final FullScreenRequestCallback? playbackCallback;
  final Function(bool)? shouldDisableScroll;
  final bool isFromMemories;
  final bool isActive;
  final bool? isAudioMutedOverride;
  final ValueNotifier<double> playbackSpeed;
  final Function({required int memoryDuration})? onFinalFileLoad;

  const VideoWidgetMediaKit(
    this.file, {
    this.tagPrefix,
    this.playbackCallback,
    this.shouldDisableScroll,
    this.isFromMemories = false,
    required this.isActive,
    this.isAudioMutedOverride,
    required this.playbackSpeed,
    this.onFinalFileLoad,
    super.key,
  });

  @override
  State<VideoWidgetMediaKit> createState() => _VideoWidgetMediaKitState();
}

class _VideoWidgetMediaKitState extends State<VideoWidgetMediaKit>
    with WidgetsBindingObserver {
  final Logger _logger = Logger("VideoWidgetMediaKitNew");
  late final player = Player();
  VideoController? controller;
  bool _isAppInFG = true;
  late StreamSubscription<PauseVideoEvent> pauseVideoSubscription;
  late StreamSubscription<ResumeVideoEvent> resumeVideoSubscription;
  StreamSubscription<VideoMuteChangedEvent>? _muteSubscription;
  bool isGuestView = false;
  late final StreamSubscription<GuestViewEvent> _guestViewEventSubscription;
  bool _isGuestView = false;
  int _videoLoad = 0;
  String? _loadedSource;
  // Offline fork: set when the device file cannot be found. The widget then
  // shows an error icon, not an endless spinner.
  bool _isFileMissing = false;
  final _transformationController = TransformationController();
  bool _isZooming = false;

  @override
  void initState() {
    _logger.info(
      'initState for ${widget.file.generatedID} with tag ${widget.file.tag} and name ${widget.file.displayName}',
    );
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadOriginal();

    pauseVideoSubscription = Bus.instance.on<PauseVideoEvent>().listen((event) {
      if (event.fileTag != null && event.fileTag != widget.file.tag) return;
      player.pause();
    });
    resumeVideoSubscription = Bus.instance.on<ResumeVideoEvent>().listen((
      event,
    ) {
      if (widget.isActive) player.play();
    });
    if (!widget.isFromMemories) {
      _muteSubscription = Bus.instance.on<VideoMuteChangedEvent>().listen((
        event,
      ) {
        player.setVolume(event.isMuted ? 0.0 : 100.0);
      });
    }
    _guestViewEventSubscription = Bus.instance.on<GuestViewEvent>().listen((
      event,
    ) {
      setState(() {
        _isGuestView = event.isGuestView;
      });
    });
    wakeLockService.updateWakeLock(
      enable: true,
      wakeLockFor: WakeLockFor.videoPlayback,
    );
  }

  @override
  void didUpdateWidget(covariant VideoWidgetMediaKit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      widget.isActive ? player.play() : player.pause();
    }
    if (oldWidget.isAudioMutedOverride != widget.isAudioMutedOverride) {
      _applyVolume();
    }
  }

  void loadOriginal() async {
    final generation = ++_videoLoad;
    if (widget.file.isSharedMediaToAppSandbox) {
      final localFile = File(getSharedMediaFilePath(widget.file));
      if (localFile.existsSync()) {
        _setVideoController(localFile.path);
      } else {
        _logger.warning("Shared media video file is missing");
        _onFileMissing();
      }
    } else {
      await widget.file.getAsset.then((asset) async {
        // Android trash assets may report that they do not exist.
        final exists = await asset?.exists ?? false;
        if (!mounted || generation != _videoLoad) {
          return;
        }
        if (asset == null || !(exists || widget.file.isDeviceTrash)) {
          _logger.warning("Device asset for the video is missing");
          _onFileMissing();
        } else {
          // ignore: unawaited_futures
          asset.getMediaUrl().then((url) {
            if (!mounted || generation != _videoLoad) {
              return;
            }
            // Offline fork: upstream played a sample video from the web
            // when the device gave no media URL.
            if (url == null) {
              _logger.warning("Device asset for the video has no media URL");
              _onFileMissing();
              return;
            }
            _setVideoController(url);
          });
        }
      });
    }
  }

  void _onFileMissing() {
    if (!mounted) return;
    setState(() => _isFileMissing = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isAppInFG = true;
    } else {
      _isAppInFG = false;
    }
  }

  @override
  void dispose() {
    _videoLoad++;
    _guestViewEventSubscription.cancel();
    pauseVideoSubscription.cancel();
    resumeVideoSubscription.cancel();
    _muteSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    player.dispose();
    _transformationController.dispose();
    wakeLockService.updateWakeLock(
      enable: false,
      wakeLockFor: WakeLockFor.videoPlayback,
    );
    super.dispose();
  }

  void _onInteractionLockChanged(bool shouldLock) {
    if (_isZooming != shouldLock) {
      setState(() {
        _isZooming = shouldLock;
      });
    }
    widget.shouldDisableScroll?.call(shouldLock);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // During zoom, keep this recognizer out of multi-touch gesture arenas.
      onVerticalDragUpdate: _isGuestView || _isZooming
          ? null
          : (d) {
              if (d.delta.dy > dragSensitivity) {
                Navigator.of(context).pop();
              } else if (d.delta.dy < (dragSensitivity * -1)) {
                showDetailsSheet(context, widget.file);
              }
            },
      child: Center(
        child: controller != null && _loadedSource != null
            ? common.VideoWidget(
                widget.file,
                controller!,
                widget.playbackCallback,
                transformationController: _transformationController,
                onInteractionLockChanged: _onInteractionLockChanged,
                isFromMemories: widget.isFromMemories,
                playbackSpeed: widget.playbackSpeed,
              )
            : Center(
                child: _isFileMissing
                    ? const Icon(Icons.error_outline, color: Colors.white)
                    : const EnteLoadingWidget(
                        size: 32,
                        color: fillBaseDark,
                        padding: 0,
                      ),
              ),
      ),
    );
  }

  void _setVideoController(String url) {
    if (mounted) {
      setState(() {
        if (controller == null) {
          player.setPlaylistMode(
            localSettings.shouldLoopVideo()
                ? PlaylistMode.single
                : PlaylistMode.none,
          );
          controller = VideoController(player);
        }
        _applyVolume();
        _loadedSource = url;
        player.open(Media(url), play: _isAppInFG && widget.isActive);
      });
      int duration = controller!.player.state.duration.inSeconds;
      if (duration == 0) {
        duration = 10;
      }
      widget.onFinalFileLoad?.call(memoryDuration: duration);
    }
  }

  void _applyVolume() {
    final mutedOverride = widget.isAudioMutedOverride;
    if (mutedOverride != null) {
      player.setVolume(mutedOverride ? 0.0 : 100.0);
    } else if (!widget.isFromMemories) {
      player.setVolume(localSettings.isMuted() ? 0.0 : 100.0);
    }
  }
}

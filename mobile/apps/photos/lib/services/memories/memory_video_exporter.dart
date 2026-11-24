import "dart:convert";
import "dart:io";
import "dart:math";
import "dart:typed_data";
import "dart:ui";

import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:logging/logging.dart";
import "package:native_video_editor/native_video_editor.dart";
import "package:photos/core/configuration.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/models/memories/memory_music_track.dart";
import "package:photos/module/download/file.dart";
import "package:photos/module/download/thumbnail.dart";
import "package:photos/utils/device_info.dart";
import "package:photos/utils/image_util.dart";
import "package:uuid/uuid.dart";

typedef SlideshowExport =
    Future<String> Function(
      SlideshowExportRequest request, {
      void Function(double progress)? onProgress,
    });

class MemoryVideoExportException implements Exception {
  final String message;

  const MemoryVideoExportException(this.message);

  @override
  String toString() => "MemoryVideoExportException: $message";
}

class MemoryVideoExportCancelled implements Exception {
  const MemoryVideoExportCancelled();

  @override
  String toString() => "MemoryVideoExportCancelled";
}

class MemoryVideoExporter {
  static const frameWidth = 1080;
  static const frameHeight = 1920;
  static const frameRate = 30;
  static const photoDuration = Duration(seconds: 5);
  static const videoClipDuration = Duration(seconds: 8);
  static const videoBitrate = 4500000;
  static const crossfade = Duration(milliseconds: 600);
  static const musicFadeIn = Duration(milliseconds: 900);
  static const musicFadeOut = Duration(milliseconds: 1500);
  static const musicDuckedVolume = 0.25;
  static const musicDuckFade = Duration(milliseconds: 500);
  static const _nearScale = 1.15;
  static const _farScale = 1.05;
  static const _maxPanFraction = 0.0125;
  static const _downloadProgressShare = 0.2;
  static const _resolveConcurrency = 3;
  static const _maxFileNameBytes = 120;
  static final _unsafeFileNameCharacters = RegExp(r'[\\/:*?"<>|\x00-\x1F]');

  static final _logger = Logger("MemoryVideoExporter");

  final Future<File?> Function(EnteFile file) _resolveFile;
  final Future<Uint8List?> Function(EnteFile file) _resolveThumbnail;
  final Future<File> Function(MemoryMusicTrack track)? _resolveMusic;
  final SlideshowExport _export;
  final Future<void> Function() _cancelExport;
  final String Function() _outputDirectory;
  final Random _random;
  Future<void>? _cancellation;

  MemoryVideoExporter({
    Future<File?> Function(EnteFile file)? resolveFile,
    Future<Uint8List?> Function(EnteFile file)? resolveThumbnail,
    Future<File> Function(MemoryMusicTrack track)? resolveMusic,
    SlideshowExport? export,
    Future<void> Function()? cancelExport,
    String Function()? outputDirectory,
    Random? random,
  }) : _resolveFile = resolveFile ?? getFile,
       _resolveThumbnail = resolveThumbnail ?? getThumbnail,
       _resolveMusic = resolveMusic,
       _export = export ?? NativeVideoEditor.exportSlideshow,
       _cancelExport = cancelExport ?? NativeVideoEditor.cancelProcessing,
       _outputDirectory =
           outputDirectory ?? Configuration.instance.getTempDirectory,
       _random = random ?? Random();

  Future<File> export({
    required List<EnteFile> files,
    required MemoryMusicTrack? musicTrack,
    required bool muteVideos,
    String? title,
    void Function(double progress)? onProgress,
  }) async {
    if (files.isEmpty) {
      throw const MemoryVideoExportException("No memory items to export");
    }
    final scratchFiles = <File>[];
    final outputDirectory = Directory(
      "${_outputDirectory()}memory-${const Uuid().v4()}",
    );
    var isExported = false;
    try {
      await outputDirectory.create(recursive: true);
      final video = await _render(
        files: files,
        musicTrack: musicTrack,
        muteVideos: muteVideos,
        outputPath: "${outputDirectory.path}/${_videoFileName(title)}",
        scratchFiles: scratchFiles,
        onProgress: onProgress,
      );
      isExported = true;
      return video;
    } on MemoryVideoExportCancelled {
      _logger.info("Memory video export cancelled");
      rethrow;
    } catch (e, s) {
      _logger.severe("Failed to export memory video", e, s);
      rethrow;
    } finally {
      for (final file in scratchFiles) {
        await deleteFileSystemEntityIfPresent(file);
      }
      if (!isExported) {
        await deleteFileSystemEntityIfPresent(outputDirectory, recursive: true);
      }
    }
  }

  Future<void> cancel() => _cancellation ??= _cancelExport();

  void _throwIfCancelled() {
    if (_cancellation != null) throw const MemoryVideoExportCancelled();
  }

  static String _videoFileName(String? title) {
    final cleaned = (title ?? "")
        .replaceAll(_unsafeFileNameCharacters, " ")
        .replaceAll(RegExp(r"\s+"), " ")
        .replaceFirst(RegExp(r"^[.\s]+"), "");
    final name = StringBuffer();
    var byteCount = 0;
    for (final rune in cleaned.runes) {
      byteCount += utf8.encode(String.fromCharCode(rune)).length;
      if (byteCount > _maxFileNameBytes) break;
      name.writeCharCode(rune);
    }
    final stem = name.toString().trim();
    return "${stem.isEmpty ? "memory" : stem}.mp4";
  }

  Future<File> _render({
    required List<EnteFile> files,
    required MemoryMusicTrack? musicTrack,
    required bool muteVideos,
    required String outputPath,
    required List<File> scratchFiles,
    void Function(double progress)? onProgress,
  }) async {
    final resolvedFiles = <File>[];
    var resolvedCount = 0;
    for (var start = 0; start < files.length; start += _resolveConcurrency) {
      _throwIfCancelled();
      final end = min(start + _resolveConcurrency, files.length);
      resolvedFiles.addAll(
        await Future.wait([
          for (var index = start; index < end; index++)
            _resolveItem(files[index], scratchFiles).then((resolved) {
              if (resolved == null) {
                throw MemoryVideoExportException(
                  "Could not load ${files[index].tag}",
                );
              }
              resolvedCount++;
              onProgress?.call(
                _downloadProgressShare * resolvedCount / files.length,
              );
              return resolved;
            }),
        ]),
      );
    }
    final items = <SlideshowItem>[];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final resolved = resolvedFiles[index];
      items.add(
        file.fileType == FileType.video
            ? SlideshowItem.video(
                path: resolved.path,
                isMuted: muteVideos,
                maxDuration: videoClipDuration,
              )
            : SlideshowItem.photo(
                path: resolved.path,
                duration: photoDuration,
                motion: _motionFor(index),
              ),
      );
    }
    SlideshowMusic? music;
    // Offline fork: there is no music source unless a resolver is injected.
    final resolveMusic = _resolveMusic;
    if (musicTrack != null && resolveMusic != null) {
      final musicFile = await resolveMusic(musicTrack);
      music = SlideshowMusic(
        path: musicFile.path,
        fadeIn: musicFadeIn,
        fadeOut: musicFadeOut,
        duckedVolume: musicDuckedVolume,
        duckFade: musicDuckFade,
      );
    }
    final request = SlideshowExportRequest(
      outputPath: outputPath,
      width: frameWidth,
      height: frameHeight,
      frameRate: frameRate,
      crossfade: crossfade,
      videoBitrate: videoBitrate,
      items: items,
      music: music,
    );
    _throwIfCancelled();
    _logger.info(
      "Exporting memory video with ${items.length} items"
      "${music == null ? "" : " and music"}",
    );
    final String exportedPath;
    try {
      exportedPath = await _export(
        request,
        onProgress: (progress) => onProgress?.call(
          _downloadProgressShare + (1 - _downloadProgressShare) * progress,
        ),
      );
    } catch (_) {
      _throwIfCancelled();
      rethrow;
    }
    _throwIfCancelled();
    return File(exportedPath);
  }

  Future<File?> _resolveItem(EnteFile file, List<File> scratchFiles) async {
    final extension = file.displayName.split(".").last.toLowerCase();
    final useThumbnail =
        isRawImageExtension(extension) ||
        (Platform.isAndroid &&
            const {"tif", "tiff", "jp2", "psd"}.contains(extension)) ||
        (const {"heic", "heif"}.contains(extension) &&
            await isAndroidSDKVersionLowerThan(28));
    if (file.fileType == FileType.video || !useThumbnail) {
      return _resolveFile(file);
    }
    final thumbnail = await _resolveThumbnail(file);
    if (thumbnail == null) return null;
    _logger.info("Using the thumbnail of file ${file.tag}");
    final raster = File("${_outputDirectory()}memory-${const Uuid().v4()}.jpg");
    scratchFiles.add(raster);
    await raster.writeAsBytes(thumbnail, flush: true);
    return raster;
  }

  SlideshowMotion _motionFor(int index) {
    final zoomIn = index.isEven;
    return SlideshowMotion(
      startScale: zoomIn ? _farScale : _nearScale,
      endScale: zoomIn ? _nearScale : _farScale,
      startOffset: _randomPan(),
      endOffset: _randomPan(),
    );
  }

  Offset _randomPan() {
    double component() => (_random.nextDouble() - 0.5) * 2 * _maxPanFraction;
    return Offset(component(), component());
  }
}

// Offline fork: "Compress" for one image, started from the viewer menu.
// It uses the same rules as the "Recompress large JPGs" tool: the copy is
// compared with the original, and the original is removed only when the copy
// is good and clearly smaller.
//
// Offline fork: not localized.

import "package:ente_components/ente_components.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/jpeg_recompress_core.dart";
import "package:photos/services/jpeg_recompress_service.dart";
import "package:photos/utils/delete_file_util.dart";
import "package:photos/utils/dialog_util.dart";

final _logger = Logger("JpegRecompressSingle");

/// Returns true when the original was removed from the device (a smaller
/// copy has taken its place).
Future<bool> recompressSingleImage(BuildContext context, EnteFile file) async {
  final service = JpegRecompressService.instance;

  final checking = createProgressDialog(context, "Checking the image…");
  await checking.show();
  JpegScanItem? item;
  try {
    item = await service.inspectSingle(file);
  } finally {
    await checking.hide();
  }
  if (!context.mounted) return false;
  if (item == null) {
    await showErrorDialog(
      context,
      "Cannot compress this image",
      "The file is not a JPG image that the app can read on this device.",
    );
    return false;
  }
  final candidate = item.candidate;
  final megapixels = (candidate.width * candidate.height / 1000000)
      .toStringAsFixed(1);
  final reason = candidate.skipReasonFor(ignoreSourceQuality: true);
  if (reason != null) {
    await showErrorDialog(
      context,
      "Cannot compress this image",
      "${reason.label}. The app does not change this file.",
    );
    return false;
  }

  const quality = kJpegRecompressDefaultQuality;
  final confirmed = await showBottomSheetComponent<bool>(
    context: context,
    builder: (sheetContext) => BottomSheetComponent(
      title: "Compress this image?",
      message:
          "${formatBytes(candidate.sizeBytes)}, $megapixels MP, "
          "${candidate.bitsPerPixel.toStringAsFixed(1)} bits for each pixel "
          "(a camera photo has 2 to 3.5).\n\n"
          "The app saves a smaller copy (quality $quality, or "
          "$kJpegRecompressFallbackQuality if necessary) and compares it "
          "with the original. If the copy is good and at least 25% smaller, "
          "the app deletes the original. Android moves it to the device "
          "trash if the device has a trash. If not, the delete is permanent.",
      closeTooltip: sheetContext.strings.close,
      actions: [
        ButtonComponent(
          label: "Compress and delete original",
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
  if (confirmed != true || !context.mounted) return false;

  final recompressor = service.recompressor(
    items: [item],
    deleteOriginals: (files) async {
      if (!context.mounted) return [];
      return deleteFilesOnDeviceOnly(context, files);
    },
  );
  final working = createProgressDialog(context, "Compressing…");
  await working.show();
  JpegRecompressSummary summary;
  try {
    // The progress dialog must not cover the system delete prompt, so the
    // encode and the delete are two steps.
    final result = await recompressor.recompressOne(
      candidate,
      quality: quality,
      ignoreSourceQuality: true,
    );
    summary = JpegRecompressSummary(results: [result], notProcessed: 0);
  } catch (e, s) {
    _logger.severe("Single image compression failed", e, s);
    summary = const JpegRecompressSummary(results: [], notProcessed: 0);
  } finally {
    await working.hide();
  }
  if (summary.originalsKept.isNotEmpty) {
    summary = await recompressor.retryDelete(summary);
    if (summary.originalsKept.isNotEmpty) {
      // The delete was refused: remove the copy, so that no duplicate stays.
      summary = await recompressor.rollBack(summary);
    }
  }
  summary.results.forEach(service.logResult);
  await service.refreshGallery();
  if (!context.mounted) return false;

  final result = summary.results.isEmpty ? null : summary.results.single;
  final String title;
  final String message;
  switch (result?.status) {
    case JpegRecompressStatus.recompressed:
      title = "Saved ${formatBytes(result!.savedBytes)}";
      message =
          "${formatBytes(candidate.sizeBytes)} became "
          "${formatBytes(result.outputBytes)} (quality ${result.quality}). "
          "The new image is \"${result.saved?.name}\" in the same folder.";
    case JpegRecompressStatus.skippedQualityLoss:
      title = "Image not changed";
      message =
          "A smaller copy would lose visible detail, so the app kept the "
          "original.";
    case JpegRecompressStatus.skippedNoSaving:
      title = "Image not changed";
      message =
          "A copy of good quality is less than 25% smaller, so the app kept "
          "the original.";
    case JpegRecompressStatus.rolledBack:
      title = "Image not changed";
      message =
          "The device did not delete the original, so the app removed the "
          "new copy.";
    case JpegRecompressStatus.originalKept:
      title = "Two files";
      message =
          "The copy is saved, but the device did not delete the original "
          "and the app could not remove the copy. Both files are on the "
          "device.";
    case JpegRecompressStatus.skippedNotEligible:
    case JpegRecompressStatus.failed:
    case null:
      title = "Image not changed";
      message =
          "The compression failed: ${result?.message ?? "unknown error"}. "
          "The original is not changed.";
  }
  await showErrorDialog(context, title, message);
  return result?.status == JpegRecompressStatus.recompressed;
}

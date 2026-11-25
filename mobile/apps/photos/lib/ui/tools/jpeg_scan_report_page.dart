// Offline fork: what the "Recompress large JPGs" scan did with each device
// folder. It answers "why is this file not in the list". Not localized.

import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:photos/services/jpeg_recompress_core.dart";
import "package:photos/services/jpeg_recompress_service.dart";

class JpegScanReportPage extends StatelessWidget {
  final JpegScanResult result;

  const JpegScanReportPage({required this.result, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final otherTypes = result.otherImageTypes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return SettingsPageScaffold(
      title: "JPG scan result",
      children: [
        Text(
          "The list of the tool has only JPG files of "
          "${kJpegRecompressMinBytes ~/ 1024} kB or more that use "
          "${kJpegRecompressMinBitsPerPixel.toStringAsFixed(0)} bits or more "
          "for each pixel. A file with a normal size for its pixels is not "
          "in the list. To compress such a file, open it and use "
          "\"Compress\" in the menu.",
          style: TextStyles.body.copyWith(color: colors.textLight),
        ),
        const SizedBox(height: Spacing.lg),
        if (otherTypes.isNotEmpty) ...[
          Text(
            "Images with another file type (not examined): "
            "${[for (final e in otherTypes) "${e.value} × ${e.key}"].join(", ")}",
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
          const SizedBox(height: Spacing.lg),
        ],
        if (result.folders.isEmpty)
          Text(
            "The app has no file with a JPG name.",
            style: TextStyles.body.copyWith(color: colors.textBase),
          ),
        for (final folder in result.folders)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  folder.folder,
                  style: TextStyles.bodyBold.copyWith(
                    color: folder.listed > 0
                        ? colors.textBase
                        : colors.textLight,
                  ),
                ),
                Text(
                  "${folder.total} JPG: "
                  "${[for (final e in folder.counts.entries) "${e.value} × ${e.key}"].join(", ")}",
                  style: TextStyles.mini.copyWith(color: colors.textLight),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

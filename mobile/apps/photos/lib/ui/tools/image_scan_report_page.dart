// Offline fork: what the "Compress images" scan did with each device
// folder. It answers "why is this file not in the list". Not localized.

import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:photos/services/image_compress_core.dart";
import "package:photos/services/image_compress_service.dart";

class ImageScanReportPage extends StatelessWidget {
  final ImageScanResult result;

  const ImageScanReportPage({required this.result, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return SettingsPageScaffold(
      title: "Scan result",
      children: [
        Text(
          "The list of the tool has only images of "
          "${kImageCompressMinBytes ~/ 1024} kB or more that use "
          "${kImageCompressMinBitsPerPixel.toStringAsFixed(0)} bits or more "
          "for each pixel. A file with a normal size for its pixels is not "
          "in the list. To compress such a file, open it and use "
          "\"Compress\" in the menu.",
          style: TextStyles.body.copyWith(color: colors.textLight),
        ),
        const SizedBox(height: Spacing.lg),
        if (result.folders.isEmpty)
          Text(
            "The app has no image.",
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
                  "${folder.total} images: "
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

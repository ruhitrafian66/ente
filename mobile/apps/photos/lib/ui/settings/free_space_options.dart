import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:photos/ui/tools/debug/app_storage_viewer.dart";
import "package:photos/ui/tools/exact_duplicates_page.dart";
import "package:photos/ui/tools/person_folders_page.dart";
import "package:photos/ui/tools/png_to_jpg_page.dart";
import "package:photos/ui/tools/video_compress_page.dart";
import "package:photos/ui/viewer/gallery/trash_page.dart";

class FreeUpSpaceOptionsScreen extends StatefulWidget {
  const FreeUpSpaceOptionsScreen({super.key});

  @override
  State<FreeUpSpaceOptionsScreen> createState() =>
      _FreeUpSpaceOptionsScreenState();
}

class _FreeUpSpaceOptionsScreenState extends State<FreeUpSpaceOptionsScreen> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.strings;

    return SettingsPageScaffold(
      title: l10n.freeUpSpace,
      children: [
        _buildFreeSpaceOption(
          title: l10n.trash,
          subtitle: l10n.restoreOrPermanentlyDeleteItems,
          icon: HugeIcons.strokeRoundedDelete01,
          onTap: () => showTrashPage(context),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          l10n.review,
          style: TextStyles.display3.copyWith(
            color: context.componentColors.textBase,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        _buildReviewOptions(context, l10n),
        const SizedBox(height: Spacing.lg),
        _buildFreeSpaceOption(
          title: l10n.manageDeviceStorage,
          subtitle: l10n.manageDeviceStorageDesc,
          icon: HugeIcons.strokeRoundedDatabase,
          onTap: () async {
            await routeToPage(context, const AppStorageViewer());
          },
        ),
      ],
    );
  }

  Widget _buildReviewOptions(BuildContext context, StringsLocalizations l10n) {
    // Offline fork: only tools that work on device files, without an account,
    // a server or CLIP embeddings.
    return MenuGroupComponent(
      items: [
        _buildFreeSpaceOption(
          title: "Exact duplicates", // Offline fork: not localized
          subtitle:
              "Find files with identical content and delete the extra copies", // Offline fork: not localized
          icon: HugeIcons.strokeRoundedCopy01,
          onTap: () async {
            await routeToPage(context, const ExactDuplicatesPage());
          },
        ),
        _buildFreeSpaceOption(
          title: "Convert PNG to JPG", // Offline fork: not localized
          subtitle:
              "Compress PNG images to save space", // Offline fork: not localized
          icon: HugeIcons.strokeRoundedImageCrop,
          onTap: () async {
            await routeToPage(context, const PngToJpgPage());
          },
        ),
        _buildFreeSpaceOption(
          title: "Compress videos", // Offline fork: not localized
          subtitle:
              "Re-encode large videos as HEVC to save space", // Offline fork: not localized
          icon: HugeIcons.strokeRoundedVideo01,
          onTap: () async {
            await routeToPage(context, const VideoCompressPage());
          },
        ),
        _buildFreeSpaceOption(
          title: "Person folders", // Offline fork: not localized
          subtitle:
              "Move photos of named persons into Pictures/People", // Offline fork: not localized
          icon: HugeIcons.strokeRoundedFolder01,
          onTap: () async {
            await routeToPage(context, const PersonFoldersPage());
          },
        ),
      ],
    );
  }

  SettingsItem _buildFreeSpaceOption({
    required String title,
    required String subtitle,
    required List<List<dynamic>> icon,
    required Future<void> Function() onTap,
  }) {
    return SettingsItem(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showOnlyLoadingState: true,
      onTap: onTap,
      subtitleMaxLines: 2,
    );
  }
}

import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/foundation.dart" show kDebugMode;
import "package:flutter/material.dart";
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/ui/tools/debug/app_storage_viewer.dart";
import "package:photos/ui/tools/exact_duplicates_page.dart";
import "package:photos/ui/tools/photo_review/review_old_photos_page.dart";
import "package:photos/ui/tools/png_to_jpg_page.dart";
import "package:photos/ui/tools/similar_images_page.dart";
import "package:photos/ui/viewer/gallery/delete_suggestions_page.dart";
import "package:photos/ui/viewer/gallery/large_files_page.dart";
import "package:photos/ui/viewer/gallery/trash_page.dart";
import "package:photos/utils/dialog_util.dart";

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
    if (kOfflineFork) {
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
        ],
      );
    }

    final options = <Widget>[
      if (flagService.internalUser)
        _buildFreeSpaceOption(
          title: l10n.oldPhotos,
          subtitle: l10n.oldPhotosDesc,
          icon: HugeIcons.strokeRoundedClock02,
          onTap: () async {
            await routeToPage(context, const ReviewOldPhotosPage());
          },
        ),
      if (flagService.enableVectorDb)
        _buildFreeSpaceOption(
          title: l10n.similarImages,
          subtitle: l10n.useMLToFindSimilarImages,
          icon: HugeIcons.strokeRoundedImageCrop,
          onTap: () async {
            await routeToPage(
              context,
              const SimilarImagesPage(debugScreen: kDebugMode),
            );
          },
        ),
      _buildFreeSpaceOption(
        title: l10n.viewLargeFiles,
        subtitle: l10n.viewLargeFilesDesc,
        icon: HugeIcons.strokeRoundedFile02,
        onTap: () async {
          await routeToPage(context, LargeFilesPagePage());
        },
      ),
      _buildFreeSpaceOption(
        title: l10n.deleteSuggestions,
        subtitle: l10n.deleteSuggestionsDesc,
        icon: HugeIcons.strokeRoundedDelete01,
        onTap: () async => _onDeleteSuggestionsTapped(),
      ),
    ];

    return MenuGroupComponent(items: options);
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

  Future<void> _onDeleteSuggestionsTapped() async {
    List<int> suggestionFileIDs;
    try {
      suggestionFileIDs = await CollectionsService.instance
          .fetchDeleteSuggestionFileIDs();
    } catch (e) {
      if (!mounted) return;
      await showGenericErrorDialog(context: context, error: e);
      return;
    }

    if (suggestionFileIDs.isEmpty) {
      if (!mounted) return;
      unawaited(
        showErrorDialog(
          context,
          context.strings.noDeleteSuggestion,
          context.strings.youHaveNoFileSuggestedForDeletion,
        ),
      );
    } else {
      if (!mounted) return;
      await routeToPage(context, DeleteSuggestionsPage());
    }
  }
}

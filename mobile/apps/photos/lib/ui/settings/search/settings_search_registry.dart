import "dart:io";

import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:ente_ui/models/settings_search_item.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:photos/core/configuration.dart";
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart";
import "package:photos/ui/settings/about/about_us_page.dart";
import "package:photos/ui/settings/appearance/appearance_settings_page.dart";
import "package:photos/ui/settings/free_space_options.dart";
import "package:photos/ui/settings/gallery_settings_screen.dart";
import "package:photos/ui/settings/memories_settings_screen.dart";
import "package:photos/ui/settings/ml/machine_learning_settings_page.dart";
import "package:photos/ui/settings/security/security_settings_page.dart";

class SettingsSearchRegistry {
  static List<SettingsSearchItem> getSearchableItems(BuildContext context) {
    final l10n = context.strings;
    final hasLoggedIn = Configuration.instance.isLoggedIn();
    final isLocalGallery = isLocalGalleryMode;
    final showThemeControls = Platform.isAndroid || kDebugMode;
    final items = <SettingsSearchItem>[];

    items.add(
      SettingsSearchItem(
        title: l10n.security,
        sectionPath: l10n.security,
        icon: HugeIcons.strokeRoundedSecurityCheck,
        routeBuilder: (_) => const SecuritySettingsPage(),
        keywords: [
          "lock",
          "pin",
          "biometric",
          "fingerprint",
          "face id",
          "app lock",
          "authentication",
        ],
      ),
    );

    items.addAll([
      SettingsSearchItem(
        title: l10n.crashReporting,
        subtitle: l10n.security,
        sectionPath: l10n.security,
        icon: HugeIcons.strokeRoundedBug02,
        routeBuilder: (_) => const SecuritySettingsPage(),
        isSubPage: true,
        keywords: ["crash", "reporting", "diagnostics"],
      ),
      SettingsSearchItem(
        title: l10n.appLock,
        subtitle: l10n.security,
        sectionPath: l10n.security,
        icon: HugeIcons.strokeRoundedSquareLock02,
        routeBuilder: (_) => const SecuritySettingsPage(),
        isSubPage: true,
        keywords: ["lock", "pin", "biometric", "face id", "fingerprint"],
      ),
    ]);

    items.add(
      SettingsSearchItem(
        title: l10n.appearance,
        sectionPath: l10n.appearance,
        icon: HugeIcons.strokeRoundedPaintBoard,
        routeBuilder: (_) => const AppearanceSettingsPage(),
        keywords: showThemeControls
            ? ["theme", "dark mode", "light mode", "app icon"]
            : ["app icon"],
      ),
    );

    if (showThemeControls) {
      items.add(
        SettingsSearchItem(
          title: l10n.theme,
          subtitle: l10n.appearance,
          sectionPath: l10n.appearance,
          icon: HugeIcons.strokeRoundedMoon02,
          routeBuilder: (_) => const AppearanceSettingsPage(),
          isSubPage: true,
          keywords: ["theme", "dark mode", "light mode", "system"],
        ),
      );
    }

    items.addAll([
      SettingsSearchItem(
        title: l10n.appIcon,
        subtitle: l10n.appearance,
        sectionPath: l10n.appearance,
        icon: HugeIcons.strokeRoundedImage02,
        routeBuilder: (_) => const AppearanceSettingsPage(),
        isSubPage: true,
        keywords: ["icon", "app icon"],
      ),
      SettingsSearchItem(
        title: l10n.language,
        subtitle: l10n.appearance,
        sectionPath: l10n.appearance,
        icon: HugeIcons.strokeRoundedTranslation,
        routeBuilder: (_) => const AppearanceSettingsPage(),
        isSubPage: true,
        keywords: ["language", "locale", "translation"],
      ),
    ]);

    items.add(
      SettingsSearchItem(
        title: l10n.gallery,
        subtitle: l10n.appearance,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["grid size", "group by", "layout", "justified"],
      ),
    );

    items.add(
      SettingsSearchItem(
        title: l10n.layout,
        subtitle: l10n.gallery,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["layout", "grid", "justified"],
      ),
    );

    items.add(
      SettingsSearchItem(
        title: l10n.photosPerRow,
        subtitle: l10n.gallery,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["grid", "size", "columns", "thumbnail"],
      ),
    );

    items.add(
      SettingsSearchItem(
        title: l10n.groupBy,
        subtitle: l10n.gallery,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["group", "day", "month", "year"],
      ),
    );

    if (hasLoggedIn || isLocalGallery) {
      items.add(
        SettingsSearchItem(
          title: l10n.machineLearning,
          sectionPath: l10n.machineLearning,
          icon: HugeIcons.strokeRoundedMagicWand01,
          routeBuilder: (_) => const MachineLearningSettingsPage(),
          keywords: [
            "ml",
            "ai",
            "faces",
            "people",
            "magic search",
            "similar images",
            "duplicates",
          ],
        ),
      );

      items.add(
        SettingsSearchItem(
          title: l10n.localIndexing,
          subtitle: l10n.machineLearning,
          sectionPath: l10n.machineLearning,
          icon: HugeIcons.strokeRoundedDatabase01,
          routeBuilder: (_) => const MachineLearningSettingsPage(),
          isSubPage: true,
          keywords: ["indexing", "local", "on-device"],
        ),
      );
    }

    if (hasLoggedIn || isLocalGallery) {
      items.addAll([
        SettingsSearchItem(
          title: l10n.memories,
          sectionPath: l10n.memories,
          icon: HugeIcons.strokeRoundedSparkles,
          routeBuilder: (_) => const MemoriesSettingsScreen(),
          keywords: ["flashback", "reminder", "highlights"],
        ),
        SettingsSearchItem(
          title: l10n.showMemories,
          subtitle: l10n.memories,
          sectionPath: l10n.memories,
          icon: HugeIcons.strokeRoundedSparkles,
          routeBuilder: (_) => const MemoriesSettingsScreen(),
          isSubPage: true,
          keywords: ["show", "memories", "highlights"],
        ),
        if (memoriesCacheService.curatedMemoriesOption)
          SettingsSearchItem(
            title: l10n.curatedMemories,
            subtitle: l10n.memories,
            sectionPath: l10n.memories,
            icon: HugeIcons.strokeRoundedSparkles,
            routeBuilder: (_) => const MemoriesSettingsScreen(),
            isSubPage: true,
            keywords: ["curated", "smart", "memories"],
          ),
      ]);
    }

    // Offline fork: the "Free up space" screen holds the device-only tools.
    if (kOfflineFork) {
      items.addAll([
        SettingsSearchItem(
          title: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedRocket01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          keywords: ["storage", "space", "clean", "delete", "local", "device"],
        ),
        SettingsSearchItem(
          title: "Exact duplicates", // Offline fork: not localized
          subtitle: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedCopy01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          isSubPage: true,
          keywords: [
            "duplicate",
            "duplicates",
            "same",
            "identical",
            "copy",
            "copies",
          ],
        ),
        SettingsSearchItem(
          title: "Convert PNG to JPG", // Offline fork: not localized
          subtitle: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedImageCrop,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          isSubPage: true,
          keywords: ["png", "jpg", "jpeg", "convert", "compress"],
        ),
      ]);
    }

    items.add(
      SettingsSearchItem(
        title: l10n.about,
        sectionPath: l10n.about,
        icon: HugeIcons.strokeRoundedInformationCircle,
        routeBuilder: (_) => const AboutUsPage(),
        keywords: ["version", "privacy", "terms", "license"],
      ),
    );

    items.addAll([
      SettingsSearchItem(
        title: l10n.weAreOpenSource,
        subtitle: l10n.about,
        sectionPath: l10n.about,
        icon: HugeIcons.strokeRoundedGithub,
        routeBuilder: (_) => const AboutUsPage(),
        isSubPage: true,
        keywords: ["open source", "github", "code"],
      ),
      SettingsSearchItem(
        title: l10n.blog,
        subtitle: l10n.about,
        sectionPath: l10n.about,
        icon: HugeIcons.strokeRoundedPencilEdit01,
        routeBuilder: (_) => const AboutUsPage(),
        isSubPage: true,
        keywords: ["blog", "news", "updates"],
      ),
      SettingsSearchItem(
        title: l10n.privacy,
        subtitle: l10n.about,
        sectionPath: l10n.about,
        icon: HugeIcons.strokeRoundedShield01,
        routeBuilder: (_) => const AboutUsPage(),
        isSubPage: true,
        keywords: ["privacy", "policy"],
      ),
      SettingsSearchItem(
        title: l10n.termsOfServicesTitle,
        subtitle: l10n.about,
        sectionPath: l10n.about,
        icon: HugeIcons.strokeRoundedFile01,
        routeBuilder: (_) => const AboutUsPage(),
        isSubPage: true,
        keywords: ["terms", "tos", "service"],
      ),
    ]);

    return items;
  }

  static List<SettingsSearchSuggestion> getSuggestions(BuildContext context) {
    final l10n = context.strings;

    return [
      SettingsSearchSuggestion(
        title: l10n.gallery,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
      ),
      SettingsSearchSuggestion(
        title: l10n.appLock,
        routeBuilder: (_) => const SecuritySettingsPage(),
      ),
    ];
  }
}

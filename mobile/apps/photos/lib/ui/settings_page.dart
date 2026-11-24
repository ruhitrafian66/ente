import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:ente_ui/components/settings/app_engagement_section.dart";
import "package:ente_ui/pages/settings_search_page.dart";
import "package:flutter/material.dart";
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/review_service.dart";
import "package:photos/ui/settings/about/about_us_page.dart";
import "package:photos/ui/settings/appearance/appearance_settings_page.dart";
import "package:photos/ui/settings/free_space_options.dart";
import "package:photos/ui/settings/inherited_settings_state.dart";
import "package:photos/ui/settings/memories_settings_screen.dart";
import "package:photos/ui/settings/ml/machine_learning_settings_page.dart";
import "package:photos/ui/settings/notification_settings_screen.dart";
import "package:photos/ui/settings/search/settings_search_registry.dart";
import "package:photos/ui/settings/security/security_settings_page.dart";
import "package:photos/ui/settings/widget_settings_screen.dart";

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsStateContainer(child: _SettingsBody());
  }
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody();

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.strings.settings,
      actions: _buildHeaderActions(context),
      children: [
        _buildMenuItem(
          title: context.strings.security,
          icon: HugeIcons.strokeRoundedSecurityCheck,
          onTap: () async {
            await routeToPage(context, const SecuritySettingsPage());
          },
        ),
        const SizedBox(height: 8),
        _buildMenuItem(
          title: context.strings.appearance,
          icon: HugeIcons.strokeRoundedPaintBoard,
          onTap: () async {
            await routeToPage(context, const AppearanceSettingsPage());
          },
        ),
        const SizedBox(height: 8),
        if (isLocalGalleryMode) ...[
          _buildOfflineFeaturesCard(context),
          const SizedBox(height: 8),
        ],
        // Offline fork: no "rate us" / share links, they need the network.
        if (!kOfflineFork) ...[
          AppEngagementSection(reviewUrl: ReviewService.url),
          const SizedBox(height: 8),
        ],
        _buildMenuItem(
          title: context.strings.about,
          icon: HugeIcons.strokeRoundedInformationCircle,
          onTap: () async {
            await routeToPage(context, const AboutUsPage());
          },
        ),
        const SizedBox(height: 60),
      ],
    );
  }

  List<Widget> _buildHeaderActions(BuildContext context) {
    return [
      IconButtonComponent(
        tooltip: context.strings.search,
        variant: IconButtonComponentVariant.primary,
        shouldSurfaceExecutionStates: false,
        icon: const HugeIcon(icon: HugeIcons.strokeRoundedSearch01),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => SettingsSearchPage(
                items: SettingsSearchRegistry.getSearchableItems(context),
                suggestions: SettingsSearchRegistry.getSuggestions(context),
                onNavigate: (context, routeBuilder) {
                  Navigator.of(context).pop();
                  routeToPage(context, routeBuilder(context));
                },
              ),
            ),
          );
        },
      ),
    ];
  }

  SettingsItem _buildMenuItem({
    required String title,
    required List<List<dynamic>> icon,
    required Future<void> Function() onTap,
  }) {
    return SettingsItem(title: title, icon: icon, onTap: onTap);
  }

  Widget _buildOfflineFeaturesCard(BuildContext context) {
    return MenuGroupComponent(
      items: [
        // Offline fork: the tools (exact duplicates, PNG to JPG, device
        // trash) live on this screen. Upstream only links it for accounts.
        _buildMenuItem(
          title: context.strings.freeUpSpace,
          icon: HugeIcons.strokeRoundedRocket01,
          onTap: () async {
            await routeToPage(context, const FreeUpSpaceOptionsScreen());
          },
        ),
        _buildMenuItem(
          title: context.strings.machineLearning,
          icon: HugeIcons.strokeRoundedMagicWand01,
          onTap: () async {
            await routeToPage(context, const MachineLearningSettingsPage());
          },
        ),
        _buildMenuItem(
          title: context.strings.memories,
          icon: HugeIcons.strokeRoundedSparkles,
          onTap: () async {
            await routeToPage(context, const MemoriesSettingsScreen());
          },
        ),
        _buildMenuItem(
          title: context.strings.notifications,
          icon: HugeIcons.strokeRoundedNotification01,
          onTap: () async {
            await routeToPage(context, const NotificationSettingsScreen());
          },
        ),
        _buildMenuItem(
          title: context.strings.widgets,
          icon: HugeIcons.strokeRoundedAlignBoxBottomRight,
          onTap: () async {
            await routeToPage(context, const WidgetSettingsScreen());
          },
        ),
      ],
    );
  }
}

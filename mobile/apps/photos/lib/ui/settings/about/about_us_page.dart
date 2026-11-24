import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:photos/service_locator.dart";
import "package:photos/utils/log_export_util.dart";

// Offline fork: upstream shows web links here (source code, blog, privacy
// policy, terms) and an update check. The fork has no network, so the page
// shows the app version and the log export.
class AboutUsPage extends StatelessWidget {
  const AboutUsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final packageInfo = ServiceLocator.instance.packageInfo;
    return SettingsPageScaffold(
      title: context.strings.about,
      children: [
        SettingsItem(
          title: context.strings.appVersion(
            versionValue: "${packageInfo.version} (${packageInfo.buildNumber})",
          ),
          icon: HugeIcons.strokeRoundedInformationCircle,
          showChevron: false,
        ),
        const SizedBox(height: 8),
        SettingsItem(
          title: context.strings.exportLogs,
          icon: HugeIcons.strokeRoundedBug02,
          onTap: () => showLogsDialog(context),
        ),
      ],
    );
  }
}

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_lock_screen/auth_util.dart";
import "package:ente_lock_screen/ui/lock_screen_options.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:local_auth/local_auth.dart";
import "package:photos/core/error-reporting/super_logging.dart";
import "package:photos/utils/dialog_util.dart";

class SecuritySettingsPage extends StatefulWidget {
  const SecuritySettingsPage({super.key});

  @override
  State<SecuritySettingsPage> createState() => _SecuritySettingsPageState();
}

class _SecuritySettingsPageState extends State<SecuritySettingsPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.strings;

    return SettingsPageScaffold(
      title: l10n.security,
      children: [
        SettingsItem(
          title: l10n.appLock,
          icon: HugeIcons.strokeRoundedSquareLock02,
          onTap: () async => _onAppLockTap(context),
        ),
        const SizedBox(height: 8),
        SettingsItem(
          title: l10n.crashReporting,
          icon: HugeIcons.strokeRoundedBug02,
          trailing: ToggleSwitchComponent.async(
            value: () => SuperLogging.shouldReportCrashes(),
            onChanged: () async {
              await SuperLogging.setShouldReportCrashes(
                !SuperLogging.shouldReportCrashes(),
              );
              if (mounted) {
                setState(() {});
              }
            },
          ),
        ),
      ],
    );
  }

  Future<void> _onAppLockTap(BuildContext context) async {
    if (await LocalAuthentication().isDeviceSupported()) {
      if (!context.mounted) return;
      final bool result = await requestAuthentication(
        context,
        context.strings.authToChangeLockscreenSetting,
      );
      if (result) {
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LockScreenOptions();
            },
          ),
        );
      }
    } else {
      if (!context.mounted) return;
      await showErrorDialog(
        context,
        context.strings.noSystemLockFound,
        context.strings.toEnableAppLockPleaseSetupDevicePasscodeOrScreen,
      );
    }
  }
}

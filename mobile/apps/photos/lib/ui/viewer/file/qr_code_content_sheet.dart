import "package:ente_qr/ente_qr.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/base_bottom_sheet.dart";
import "package:photos/ui/components/buttons/button_widget_v2.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/utils/share_util.dart";

Future<void> showQrCodeContentSheet(
  BuildContext context, {
  required List<QrDetection> detections,
}) {
  return showBaseBottomSheet(
    context,
    title: context.strings.qrCode,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < detections.length; i++) ...[
          if (i > 0) const SizedBox(height: 16),
          _QrContentEntry(content: detections[i].content),
        ],
      ],
    ),
  );
}

class _QrContentEntry extends StatelessWidget {
  final String content;

  const _QrContentEntry({required this.content});

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    final l10n = context.strings;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(
                left: 16,
                top: 16,
                bottom: 16,
                right: 48,
              ),
              decoration: BoxDecoration(
                color: colorScheme.fillFaint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                content,
                style: textTheme.body.copyWith(color: colorScheme.textBase),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: GestureDetector(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: content));
                  if (context.mounted) {
                    showShortToast(context, l10n.copied);
                  }
                },
                child: Icon(
                  Icons.copy_rounded,
                  size: 20,
                  color: colorScheme.textMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Offline fork: the "Open link" and "Pay" buttons opened other apps
        // through url_launcher. They are removed; copy and share stay.
        ButtonWidgetV2(
          buttonType: ButtonTypeV2.primary,
          labelText: l10n.shareLink,
          shouldSurfaceExecutionStates: false,
          onTap: () async {
            await shareText(content, context: context);
          },
        ),
      ],
    );
  }
}

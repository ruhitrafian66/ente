import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import "package:ente_strings/ente_strings.dart";
import 'package:ente_ui/pages/log_file_viewer.dart';
import "package:file_saver/file_saver.dart";
import 'package:flutter/material.dart';
import "package:intl/intl.dart";
import 'package:path_provider/path_provider.dart';
import 'package:photos/core/error-reporting/super_logging.dart';
import "package:photos/ui/common/progress_dialog.dart";
import 'package:photos/ui/components/buttons/button_widget.dart';
import 'package:photos/ui/components/dialog_widget.dart';
import 'package:photos/ui/components/models/button_type.dart';
import 'package:photos/utils/dialog_util.dart';
import 'package:share_plus/share_plus.dart';

// Offline fork: this file replaces `email_util.dart`. The app cannot send
// logs. The user can read the current log, or export all logs as a zip file.

/// Shows the log actions: export the logs as a zip file, or read the current
/// log file.
void showLogsDialog(BuildContext context) {
  unawaited(
    showDialogWidget(
      context: context,
      title: context.strings.exportLogs,
      icon: Icons.bug_report_outlined,
      buttons: [
        ButtonWidget(
          isInAlert: true,
          buttonType: ButtonType.neutral,
          labelText: context.strings.exportLogs,
          buttonAction: ButtonAction.first,
          shouldSurfaceExecutionStates: false,
          onTap: () async {
            await zipAndExportLogs(context);
          },
        ),
        if (SuperLogging.logFile != null)
          ButtonWidget(
            buttonType: ButtonType.secondary,
            labelText: context.strings.viewLogs,
            buttonAction: ButtonAction.second,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LogFileViewer(SuperLogging.logFile!),
                ),
              );
            },
          ),
        ButtonWidget(
          isInAlert: true,
          buttonType: ButtonType.secondary,
          labelText: context.strings.cancel,
          buttonAction: ButtonAction.cancel,
        ),
      ],
    ),
  );
}

/// Puts all log files in one zip file, then lets the user save that file
/// (Android) or share it (other platforms).
Future<void> zipAndExportLogs(BuildContext context) async {
  final zipFilePath = await getZippedLogsFile(context);
  if (!context.mounted) return;
  await exportLogs(context, zipFilePath);
}

Future<String> getZippedLogsFile(BuildContext? context) async {
  late final ProgressDialog dialog;
  if (context != null) {
    dialog = createProgressDialog(context, context.strings.preparingLogs);
    await dialog.show();
  }
  final logsPath = (await getApplicationSupportDirectory()).path;
  final logsDirectory = Directory(logsPath + "/logs");
  final tempPath = (await getTemporaryDirectory()).path;
  final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    ':',
    '-',
  );
  final zipFilePath = tempPath + "/logs-$timestamp.zip";
  final encoder = ZipFileEncoder();
  encoder.create(zipFilePath);
  await encoder.addDirectory(logsDirectory);
  await encoder.close();
  if (context != null) {
    await dialog.hide();
  }
  return zipFilePath;
}

Future<void> exportLogs(BuildContext context, String zipFilePath) async {
  final Size size = MediaQuery.of(context).size;
  if (Platform.isAndroid) {
    final DateTime now = DateTime.now().toUtc();
    final String shortMonthName = DateFormat('MMM').format(now);
    final String logFileName =
        'ente-logs-${now.year}-$shortMonthName-${now.day}-${now.hour}-${now.minute}';
    await FileSaver.instance.saveAs(
      name: logFileName,
      filePath: zipFilePath,
      mimeType: MimeType.zip,
      fileExtension: 'zip',
    );
  } else {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(zipFilePath, mimeType: 'application/zip')],
        sharePositionOrigin: Rect.fromLTWH(0, 0, size.width, size.height / 2),
      ),
    );
  }
}

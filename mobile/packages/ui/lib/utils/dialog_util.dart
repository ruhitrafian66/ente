import 'package:ente_ui/components/loading_widget.dart';
import 'package:ente_ui/components/progress_dialog.dart';
import 'package:flutter/material.dart';

// Offline fork: only the progress dialog helper is left. The error dialogs
// (dio errors, "contact support" e-mail) went away with the network code.
ProgressDialog createProgressDialog(
  BuildContext context,
  String message, {
  isDismissible = false,
}) {
  final dialog = ProgressDialog(
    context,
    type: ProgressDialogType.normal,
    isDismissible: isDismissible,
    barrierColor: Colors.black12,
  );
  dialog.style(
    message: message,
    messageTextStyle: Theme.of(context).textTheme.labelMedium,
    backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
    progressWidget: const EnteLoadingWidget(),
    borderRadius: 10,
    elevation: 10.0,
    insetAnimCurve: Curves.easeInOut,
  );
  return dialog;
}

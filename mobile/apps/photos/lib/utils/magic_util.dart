import "dart:async";

import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/ui/notification/toast.dart';
import 'package:photos/utils/dialog_util.dart';

final _logger = Logger('MagicUtil');

// Offline fork (removal stage 2): the file-level edits below (time, name,
// caption) were server operations in the removed FileMagicService. They
// always failed without an account. The functions stay as failing stubs until
// their callers are removed.
//
// Offline fork (removal stage 3): the collection functions (visibility, sort
// order, pin order, cover photo, description) are gone with the collections
// service.
Future<bool> editTime(
  BuildContext context,
  Map<EnteFile, int> filesToEditedTimes,
) async {
  showShortToast(context, context.strings.somethingWentWrong);
  return false;
}

Future<void> editFilename(BuildContext context, EnteFile file) async {
  _logger.severe("Failed to rename file");
  await showGenericErrorDialog(
    context: context,
    error: UnsupportedError("File rename needs an account"),
  );
}

Future<bool> editFileCaption(
  BuildContext? context,
  EnteFile file,
  String caption,
) async {
  return false;
}

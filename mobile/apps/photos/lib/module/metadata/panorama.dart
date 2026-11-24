import "dart:io";

import "package:exif_reader/exif_reader.dart";
import "package:photos/models/file/file.dart";
import "package:photos/src/rust/api/motion_photo_api.dart";

Future<Map<String, dynamic>> readXmp(File file) =>
    extractXmp(filePath: file.path);

bool? isPanoramaFromExif(Map<String, IfdTag>? exifData) {
  final customRendered = exifData?["EXIF CustomRendered"]?.printable;
  if (customRendered == null) {
    return null;
  }
  return customRendered == "6";
}

bool isPanoramaFromXmp(Map<String, dynamic> xmpData) {
  final projectionType = xmpData["GPano:ProjectionType"];
  return projectionType == "cylindrical" || projectionType == "equirectangular";
}

// Offline fork: the result of this check was only written to the public magic
// metadata of an uploaded file, through the server. No file is uploaded, so
// the upstream guard (`!file.canEditMetaInfo`) always returned here.
Future<void> guardedCheckPanorama(EnteFile file) async {}

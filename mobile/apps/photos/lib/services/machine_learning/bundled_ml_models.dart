import "dart:io";

import "package:flutter/services.dart" show rootBundle;
import "package:logging/logging.dart";
import "package:path/path.dart" as p;

final _logger = Logger("BundledMLModels");

/// Models shipped inside the APK under `assets/ml_models/`.
///
/// Key: the model directory name the Rust asset store expects
/// (`<assetsDir>/models/<key>/<file>`, see rust/crates/ml/src/assets.rs).
/// Value: (file name, exact size in bytes).
const _bundledModels = <String, (String, int)>{
  "yolov5s_face_640_640_static_b1": (
    "yolov5s_face_640_640_static_b1.onnx",
    32355091,
  ),
  "mobilefacenet_portable_static_b1": (
    "mobilefacenet_portable_static_b1.onnx",
    5278803,
  ),
};

/// Copies the bundled face models to where the Rust ML runtime looks for
/// downloaded models. Rust treats a model as present when the file exists, so
/// after this call it never creates an HTTP client.
///
/// Safe to call repeatedly; it only copies files that are missing or have the
/// wrong size. The copy is written to a temporary name and renamed, because
/// Rust does not verify the content of an existing file.
Future<void> installBundledMlModels(String assetsDir) async {
  for (final entry in _bundledModels.entries) {
    final (fileName, size) = entry.value;
    final dest = File(p.join(assetsDir, "models", entry.key, fileName));
    if (dest.existsSync() && dest.lengthSync() == size) continue;

    await dest.parent.create(recursive: true);
    final data = await rootBundle.load("assets/ml_models/$fileName");
    if (data.lengthInBytes != size) {
      throw StateError(
        "Bundled model $fileName has ${data.lengthInBytes} bytes, "
        "expected $size. Run tool/fetch_bundled_ml_models.sh and rebuild.",
      );
    }
    final tmp = File("${dest.path}.bundled-tmp");
    await tmp.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await tmp.rename(dest.path);
    _logger.info("Installed bundled ML model $fileName");
  }
}

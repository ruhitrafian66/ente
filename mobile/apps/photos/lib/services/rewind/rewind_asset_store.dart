import "dart:io";

import "package:flutter/services.dart";
import "package:logging/logging.dart";
import "package:path/path.dart" as path;
import "package:path_provider/path_provider.dart";
import "package:synchronized/synchronized.dart";

class RewindAssetStore {
  static const lilitaOne = "Lilita One";
  static const nunito = "Nunito";
  static const bagelFatOne = "Bagel Fat One";
  static const courierPrime = "Courier Prime";

  static const _version = "rewind-2026-v8";
  static const _fonts = {
    lilitaOne: "fonts/LilitaOne-Regular.ttf",
    nunito: "fonts/Nunito-Black.ttf",
    bagelFatOne: "fonts/BagelFatOne-Regular.ttf",
    courierPrime: "fonts/CourierPrime-Regular.ttf",
  };

  final _logger = Logger("RewindAssetStore");
  final _lock = Lock();
  String? _directory;
  var _fontsLoaded = false;

  File file(String name) => File(path.join(_directory!, name));

  Future<bool> prepare() => _lock.synchronized(() async {
    try {
      final directory = await _unpacked();
      await _loadFonts(directory);
      _directory = directory;
      return true;
    } catch (e, s) {
      _logger.warning("Rewind assets are not available", e, s);
      return false;
    }
  });

  static Future<String> _unpacked() async {
    final root = path.join(
      (await getApplicationSupportDirectory()).path,
      "rewind-assets",
    );
    final target = Directory(path.join(root, _version));
    if (await target.exists()) return target.path;
    // Offline fork: the asset pack was a network download. Without a pack
    // that is already on the device, Rewind stays unavailable.
    throw StateError("Rewind assets are not on this device");
  }

  Future<void> _loadFonts(String directory) async {
    if (_fontsLoaded) return;
    for (final MapEntry(key: family, value: name) in _fonts.entries) {
      final bytes = await File(path.join(directory, name)).readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
    _fontsLoaded = true;
  }
}

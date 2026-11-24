import 'dart:io';

import 'package:url_launcher/url_launcher_string.dart';

abstract final class ReviewService {
  static String get url {
    if (Platform.isIOS) {
      return 'https://apps.apple.com/app/ente-photos/id1542026904';
    }
    return 'https://alternativeto.net/software/ente/about/';
  }

  static Future<void> launch() {
    return launchUrlString(url, mode: LaunchMode.externalApplication);
  }
}

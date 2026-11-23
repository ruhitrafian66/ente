// Offline fork: this is the F-Droid stub (fdroid/overlay), applied
// permanently. There is no Firebase and no push registration in this fork.
typedef BackgroundPushHandler = Future<void> Function(Object message);

class PushService {
  static final PushService instance = PushService._privateConstructor();

  PushService._privateConstructor();

  Future<void> init({BackgroundPushHandler? onBackgroundPush}) async {}

  static bool shouldSync(Object message) => false;

  // Offline fork: the debug settings page reads these two members. The
  // upstream F-Droid stub does not have them.
  static bool get canRefreshPushRegistration => false;

  Future<bool> refreshPushRegistration() async => false;
}

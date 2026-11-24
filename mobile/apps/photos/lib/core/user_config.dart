import "package:photos/core/configuration.dart";

extension UserConfig on Configuration {
  // Offline fork: there is no account, so there is no user ID. Keep -1: the
  // FilesDB owner filters (`owner_id IS NULL OR owner_id = ?`) depend on it.
  int getUserIDV2() => -1;
}

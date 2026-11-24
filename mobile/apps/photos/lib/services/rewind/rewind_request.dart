import "package:flutter_rust_bridge/flutter_rust_bridge.dart" show Int64List;
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file/file_type.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/memories/memory_sources.dart";
import "package:photos/services/rewind/rewind_edition.dart";
import "package:photos/src/rust/api/rewind_api.dart" as rust;

bool get rewindUsesMl =>
    hasGrantedMLConsent && localSettings.isMLLocalIndexingEnabled;

const _screenshotName = "screenshot";

Future<rust.RewindRequest> buildRewindRequest(DateTime now) async {
  final packageInfo = await PackageInfo.fromPlatform();
  return rust.RewindRequest(
    year: RewindEdition.year,
    now: now.microsecondsSinceEpoch,
    utcOffsetSeconds: now.timeZoneOffset.inSeconds,
    seasonStart: RewindEdition.availableFrom.microsecondsSinceEpoch,
    installedAt: packageInfo.installTime?.microsecondsSinceEpoch ?? 0,
    localGalleryMode: true,
    // Offline fork: only device files exist. The account path (albums,
    // likes from the social database) is removed.
    files: await _localFiles(),
    // Offline fork: local gallery mode sends no persons.
    people: const [],
    // Offline fork: there is no account email, so no person is "me".
    mePersonId: null,
  );
}

Future<List<rust.RewindFile>> _localFiles() async {
  final files = await getFilesAndMapForMemories(
    useLocalIntIds: true,
    requireLocalId: true,
  );
  return [
    for (final MapEntry(key: id, value: file) in files.entries)
      _rewindFile(
        id,
        file,
        visibility: rust.RewindVisibility.visible,
        isFavourite: false,
        isJunk: _isScreenshotName(file.deviceFolder),
        isScreenshot: _isScreenshotName(file.deviceFolder),
        sharedAlbumIds: const [],
        likeCount: 0,
      ),
  ];
}

rust.RewindFile _rewindFile(
  int id,
  EnteFile file, {
  required rust.RewindVisibility visibility,
  required bool isFavourite,
  required bool isJunk,
  required bool isScreenshot,
  required List<int> sharedAlbumIds,
  required int likeCount,
}) {
  final creationTime = file.creationTime!;
  return rust.RewindFile(
    id: id,
    creationTime: creationTime,
    localDateTime: file.pubMagicMetadata?.dateTime,
    utcOffsetSeconds: DateTime.fromMicrosecondsSinceEpoch(
      creationTime,
    ).timeZoneOffset.inSeconds,
    fileType: switch (file.fileType) {
      FileType.image => rust.RewindFileType.image,
      FileType.video => rust.RewindFileType.video,
      FileType.livePhoto => rust.RewindFileType.livePhoto,
      FileType.other => rust.RewindFileType.other,
    },
    location: _location(file),
    visibility: visibility,
    isFavourite: isFavourite,
    isJunk: isJunk,
    isScreenshot: isScreenshot,
    sharedAlbumIds: Int64List.fromList(sharedAlbumIds),
    likeCount: likeCount,
  );
}

rust.RewindLocation? _location(EnteFile file) {
  final latitude = file.location?.latitude;
  final longitude = file.location?.longitude;
  if (!file.hasLocation || latitude == null || longitude == null) return null;
  return rust.RewindLocation(latitude: latitude, longitude: longitude);
}

bool _isScreenshotName(String? name) =>
    name?.toLowerCase().contains(_screenshotName) ?? false;

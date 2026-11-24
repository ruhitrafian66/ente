import "dart:convert";
import "dart:math";

import "package:computer/computer.dart";
import "package:logging/logging.dart";
import "package:photos/core/constants.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/location_tag_updated_event.dart";
import "package:photos/models/base_location.dart";
import "package:photos/models/entity_type.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/local_entity_data.dart";
import "package:photos/models/location/location.dart";
import 'package:photos/models/location_tag/location_tag.dart';
import "package:photos/service_locator.dart";
import "package:photos/src/rust/api/location_api.dart" as rust;
import "package:photos/utils/rust_isolate_util.dart";

class CitySearchIndex {
  final Map<EnteFile, City> assignments;

  const CitySearchIndex(this.assignments);

  Map<City, List<EnteFile>> match(List<EnteFile> files) {
    final results = <City, List<EnteFile>>{};
    for (final file in files) {
      final city = assignments[file];
      if (city != null) results.putIfAbsent(city, () => []).add(file);
    }
    return results;
  }
}

class LocationService {
  final Logger _logger = Logger((LocationService).toString());
  final Computer _computer = Computer.shared();

  // TODO: lau: consider actually using this in location section
  List<BaseLocation> baseLocations = [];

  Future<Iterable<LocalEntity<LocationTag>>> _getStoredLocationTags() async {
    final data = await entityService.getEntities(EntityType.location);
    return data.map(
      (e) => LocalEntity(LocationTag.fromJson(json.decode(e.data)), e.id),
    );
  }

  Future<Map<LocationTag, int>> getLocationTagsToOccurrence(
    List<EnteFile> files,
  ) async {
    final locationTagEntities = await locationService.getLocationTags();

    final locationTagToOccurrence = await _computer.compute(
      _getLocationTagsToOccurrenceForIsolate,
      param: {"files": files, "locationTagEntities": locationTagEntities},
    );

    return locationTagToOccurrence;
  }

  // Offline fork: upstream downloads the city data set (cities.bin) at run
  // time. The fork has no network, so there is no city index. City and
  // country search are removed; the callers below get an empty result, as
  // they did each time the download failed.
  Future<rust.LocationIndex?> getLocationIndex() async => null;

  Future<CitySearchIndex> getCitySearchIndex(
    Iterable<EnteFile> allFiles,
  ) async {
    return const CitySearchIndex({});
  }

  Future<Iterable<LocalEntity<LocationTag>>> getLocationTags() {
    return _getStoredLocationTags();
  }

  Future<void> addLocation(
    String location,
    Location centerPoint,
    double radius,
  ) async {
    // A circular radius on the globe maps to an ellipse in Mercator
    // coordinates. Store its axes in degrees for latitude/longitude checks.

    try {
      final a =
          (radius * scaleFactor(centerPoint.latitude!)) / kilometersPerDegree;
      final b = radius / kilometersPerDegree;
      final locationTag = LocationTag(
        name: location,
        radius: radius,
        aSquare: a * a,
        bSquare: b * b,
        centerPoint: centerPoint,
      );
      await entityService.addOrUpdate(
        EntityType.location,
        locationTag.toJson(),
      );
      Bus.instance.fire(LocationTagUpdatedEvent(LocTagEventType.add));
    } catch (e, s) {
      _logger.severe("Failed to add location tag", e, s);
    }
  }

  Future<List<LocalEntity<LocationTag>>> enclosingLocationTags(
    Location fileCoordinates,
  ) async {
    try {
      final result = List<LocalEntity<LocationTag>>.of([]);
      final locationTagEntities = await getLocationTags();
      for (LocalEntity<LocationTag> locationTagEntity in locationTagEntities) {
        final locationTag = locationTagEntity.item;
        if (isFileInsideLocationTag(
          locationTag.centerPoint,
          fileCoordinates,
          locationTag.radius,
        )) {
          result.add(locationTagEntity);
        }
      }
      return result;
    } catch (e, s) {
      _logger.severe("Failed to get enclosing location tags", e, s);
      rethrow;
    }
  }

  List<String>? convertLocationToDMS(Location centerPoint) {
    if (centerPoint.latitude == null || centerPoint.longitude == null) {
      return null;
    }
    final lat = centerPoint.latitude!;
    final long = centerPoint.longitude!;
    final latRef = lat >= 0 ? "N" : "S";
    final longRef = long >= 0 ? "E" : "W";
    final latDMS = _convertCoordinateToDMS(lat.abs());
    final longDMS = _convertCoordinateToDMS(long.abs());

    return [
      "${latDMS[0]}°${latDMS[1]}'${latDMS[2]}\" $latRef",
      "${longDMS[0]}°${longDMS[1]}'${longDMS[2]}\" $longRef",
    ];
  }

  List<int> _convertCoordinateToDMS(double coordinate) {
    final degrees = coordinate.floor();
    final minutes = ((coordinate - degrees) * 60).floor();
    final seconds = ((coordinate - degrees - minutes / 60) * 3600).floor();
    return [degrees, minutes, seconds];
  }

  Future<void> updateLocationTag({
    required LocalEntity<LocationTag> locationTagEntity,
    double? newRadius,
    Location? newCenterPoint,
    String? newName,
  }) async {
    try {
      final radius = newRadius ?? locationTagEntity.item.radius;
      final centerPoint = newCenterPoint ?? locationTagEntity.item.centerPoint;
      final name = newName ?? locationTagEntity.item.name;

      final locationTag = locationTagEntity.item;
      if (radius == locationTag.radius &&
          centerPoint == locationTag.centerPoint &&
          name == locationTag.name) {
        return;
      }
      final a =
          (radius * scaleFactor(centerPoint.latitude!)) / kilometersPerDegree;
      final b = radius / kilometersPerDegree;
      final updatedLoationTag = locationTagEntity.item.copyWith(
        centerPoint: centerPoint,
        aSquare: a * a,
        bSquare: b * b,
        radius: radius,
        name: name,
      );

      await entityService.addOrUpdate(
        EntityType.location,
        updatedLoationTag.toJson(),
        id: locationTagEntity.id,
      );
      Bus.instance.fire(
        LocationTagUpdatedEvent(
          LocTagEventType.update,
          updatedLocTagEntities: [
            LocalEntity(updatedLoationTag, locationTagEntity.id),
          ],
        ),
      );
    } catch (e, s) {
      _logger.severe("Failed to update location tag", e, s);
      rethrow;
    }
  }

  Future<void> deleteLocationTag(String locTagEntityId) async {
    try {
      await entityService.deleteEntry(locTagEntityId);
      Bus.instance.fire(LocationTagUpdatedEvent(LocTagEventType.delete));
    } catch (e, s) {
      _logger.severe("Failed to delete location tag", e, s);
      rethrow;
    }
  }
}

Future<Map<LocationTag, int>> _getLocationTagsToOccurrenceForIsolate(
  Map args,
) async {
  await ensureRustInitialized();
  final List<EnteFile> files = args["files"];
  final locationTagEntities =
      args["locationTagEntities"] as Iterable<LocalEntity<LocationTag>>;
  final uploadedFilesWithLocation = files
      .where(
        (file) =>
            file.uploadedFileID != null &&
            file.uploadedFileID != -1 &&
            file.hasLocation,
      )
      .toList();

  final locationTagToOccurrence = <LocationTag, int>{};
  for (LocalEntity<LocationTag> locationTagEntity in locationTagEntities) {
    final locationTag = locationTagEntity.item;
    final occurrence = filesInsideLocationTag(
      uploadedFilesWithLocation,
      locationTag.centerPoint,
      locationTag.radius,
    ).length;
    if (occurrence > 0) {
      locationTagToOccurrence.update(
        locationTag,
        (value) => value + occurrence,
        ifAbsent: () => occurrence,
      );
    }
  }

  return locationTagToOccurrence;
}

bool isFileInsideLocationTag(
  Location centerPoint,
  Location fileCoordinates,
  double radius,
) {
  return rust.isWithinRadiusKm(
    point: _coordinate(fileCoordinates),
    center: _coordinate(centerPoint),
    radiusKm: radius,
  );
}

// Returns kilometers.
double calculateDistance(Location point1, Location point2) {
  return rust.distanceKm(from: _coordinate(point1), to: _coordinate(point2));
}

List<EnteFile> filesInsideLocationTag(
  List<EnteFile> files,
  Location centerPoint,
  double radius,
) {
  final indices = rust.indicesWithinRadiusKm(
    points: _coordinates(files),
    center: _coordinate(centerPoint),
    radiusKm: radius,
  );
  return [for (final index in indices) files[index]];
}

List<rust.LocationCoordinate> _coordinates(List<EnteFile> files) => [
  for (final file in files) _coordinate(file.location!),
];

rust.LocationCoordinate _coordinate(Location location) =>
    rust.LocationCoordinate(
      latitude: location.latitude!,
      longitude: location.longitude!,
    );

// Mercator stretches longitude by sec(latitude), so a circle's horizontal
// radius must scale with latitude.
double scaleFactor(double lat) {
  return 1 / cos(lat * (pi / 180));
}

class City {
  final String city;
  final String country;
  final double lat;
  final double lng;

  const City({
    required this.city,
    required this.country,
    required this.lat,
    required this.lng,
  });
}

class GPSData {
  final String? latRef;
  final List<double>? lat;
  final String? longRef;
  final List<double>? long;

  GPSData(this.latRef, this.lat, this.longRef, this.long);

  Location? toLocationObj() {
    final lat = this.lat;
    final long = this.long;
    if (lat == null || long == null || lat.length < 3 || long.length < 3) {
      return null;
    }

    final latRef = this.latRef?.toLowerCase();
    final longRef = this.longRef?.toLowerCase();
    int? latSign;
    int? longSign;
    if (latRef == null && longRef == null) {
      latSign = lat.any((element) => element < 0) ? -1 : 1;
      longSign = long.any((element) => element < 0) ? -1 : 1;
    } else if (latRef == null || longRef == null) {
      return null;
    } else {
      if (latRef.startsWith('n')) {
        latSign = 1;
      } else if (latRef.startsWith('s')) {
        latSign = -1;
      }
      if (longRef.startsWith('e')) {
        longSign = 1;
      } else if (longRef.startsWith('w')) {
        longSign = -1;
      }
    }

    if (latSign == null || longSign == null) {
      return null;
    }

    final latParts = latRef == null
        ? lat.map((part) => part.abs()).toList()
        : lat;
    final longParts = longRef == null
        ? long.map((part) => part.abs()).toList()
        : long;
    final result = Location(
      latitude: latSign * (latParts[0] + latParts[1] / 60 + latParts[2] / 3600),
      longitude:
          longSign * (longParts[0] + longParts[1] / 60 + longParts[2] / 3600),
    );
    if (Location.isValidLocation(result)) {
      return result;
    } else {
      return null;
    }
  }
}

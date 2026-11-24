import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/device_files_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/events/local_photos_updated_event.dart";
import "package:photos/models/device_collection.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file_load_result.dart";
import "package:photos/models/gallery_type.dart";
import "package:photos/models/selected_files.dart";
import "package:photos/ui/viewer/actions/file_selection_overlay_bar.dart";
import "package:photos/ui/viewer/gallery/gallery.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_widget.dart";
import "package:photos/ui/viewer/gallery/state/gallery_boundaries_provider.dart";
import "package:photos/ui/viewer/gallery/state/gallery_files_inherited_widget.dart";
import "package:photos/ui/viewer/gallery/state/selection_state.dart";

class DeviceFolderPage extends StatefulWidget {
  final DeviceCollection deviceCollection;
  final String? coverHeroTag;

  const DeviceFolderPage(this.deviceCollection, {this.coverHeroTag, super.key});

  @override
  State<DeviceFolderPage> createState() => _DeviceFolderPageState();
}

class _DeviceFolderPageState extends State<DeviceFolderPage> {
  final _selectedFiles = SelectedFiles();
  final _coverAppBarKey = GlobalKey();
  EnteFile? _cover;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _cover = widget.deviceCollection.thumbnail;
  }

  Future<FileLoadResult> _loadFiles(
    int creationStartTime,
    int creationEndTime, {
    int? limit,
    bool? asc,
  }) async {
    final generation = ++_loadGeneration;
    final result = await FilesDB.instance.getFilesInDeviceCollection(
      widget.deviceCollection,
      creationStartTime,
      creationEndTime,
      limit: limit,
      asc: asc,
    );
    if (mounted && generation == _loadGeneration) {
      final thumbnail = widget.deviceCollection.thumbnail;
      final cover =
          result.files.firstWhereOrNull(
            (file) => file.localID == thumbnail?.localID,
          ) ??
          (result.hasMore ? thumbnail : null) ??
          result.files.firstOrNull;
      setState(() => _cover = cover);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final appBar = GalleryAppBarWidget.sliverConfig(
      GalleryType.localFolder,
      widget.deviceCollection.name,
      _selectedFiles,
      coverAppBarKey: _coverAppBarKey,
      deviceCollection: widget.deviceCollection,
      cover: _cover,
      coverHeroTag:
          widget.coverHeroTag ?? "device_folder:${widget.deviceCollection.id}",
    );
    final gallery = Gallery(
      key: ValueKey("device_folder:${widget.deviceCollection.id}"),
      appBar: appBar,
      asyncLoader: _loadFiles,
      reloadEvent: Bus.instance.on<LocalPhotosUpdatedEvent>(),
      removalEventTypes: const {
        EventType.deletedFromDevice,
        EventType.deletedFromEverywhere,
        EventType.hide,
      },
      tagPrefix: "device_folder_files:${widget.deviceCollection.id}",
      galleryType: GalleryType.localFolder,
      selectedFiles: _selectedFiles,
      header: const SizedBox.shrink(),
      initialFiles: _initialFiles,
    );
    return GalleryBoundariesProvider(
      child: GalleryFilesState(
        child: Scaffold(
          body: SelectionState(
            selectedFiles: _selectedFiles,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                gallery,
                FileSelectionOverlayBar(
                  GalleryType.localFolder,
                  _selectedFiles,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<EnteFile>? get _initialFiles {
    final thumbnail = widget.deviceCollection.thumbnail;
    return thumbnail != null ? [thumbnail] : null;
  }
}

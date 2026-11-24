import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import "package:photos/core/constants.dart";
import 'package:photos/core/event_bus.dart';
import "package:photos/db/device_files_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/magic_sort_change_event.dart";
import 'package:photos/models/device_collection.dart';
import "package:photos/models/file/file.dart";
import 'package:photos/models/gallery_type.dart';
import 'package:photos/models/selected_files.dart';
import 'package:photos/service_locator.dart';
import "package:photos/states/location_screen_state.dart";
import "package:photos/theme/ente_theme.dart";
import 'package:photos/ui/notification/toast.dart';
import "package:photos/ui/viewer/album_slideshow/album_slideshow.dart";
import "package:photos/ui/viewer/gallery/component/album_cover_app_bar.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_actions.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_config.dart";
import "package:photos/ui/viewer/gallery/hooks/album_sort_sheet.dart";
import "package:photos/ui/viewer/location/edit_location_sheet.dart";
import 'package:photos/utils/dialog_util.dart';

class GalleryAppBarWidget extends StatefulWidget {
  static const double toolbarHeight = kToolbarHeight;
  static const double _sliverExpandedHeight = 92.0;

  static Color backgroundColor(BuildContext context) {
    return getEnteColorScheme(context).backgroundColour;
  }

  static GalleryAppBarConfig sliverConfig(
    GalleryType type,
    String? title,
    SelectedFiles selectedFiles, {
    String? subtitle,
    DeviceCollection? deviceCollection,
    EnteFile? cover,
    Widget? coverWidget,
    List<Widget> Function({required bool onCover, Color? foregroundColor})?
    actionsBuilder,
    String? coverHeroTag,
    Key? coverAppBarKey,
    List<EnteFile>? files,
    MagicSortType magicSortType = MagicSortType.mostRelevant,
    PreferredSizeWidget? bottom,
    bool showOverflowMenu = true,
  }) {
    assert(cover == null || deviceCollection != null || files != null);
    return GalleryAppBarConfig(
      extendBodyForCollapse:
          (cover != null || coverWidget != null) && bottom == null,
      sliverBuilder: (_) => GalleryAppBarWidget._(
        type,
        title,
        selectedFiles,
        subtitle: subtitle,
        deviceCollection: deviceCollection,
        cover: cover,
        coverWidget: coverWidget,
        actionsBuilder: actionsBuilder,
        coverHeroTag: coverHeroTag,
        coverAppBarKey: coverAppBarKey,
        files: files,
        magicSortType: magicSortType,
        bottom: bottom,
        showOverflowMenu: showOverflowMenu,
      ),
      geometryBuilder: (context) => _resolveSliverGeometry(
        context,
        subtitle: subtitle,
        bottomHeight: bottom?.preferredSize.height,
        hasCover: cover != null || coverWidget != null,
      ),
    );
  }

  static HeaderAppBarGeometry _resolveSliverGeometry(
    BuildContext context, {
    String? subtitle,
    double? bottomHeight,
    required bool hasCover,
  }) {
    final hasCustomBottom = bottomHeight != null;
    bottomHeight ??= 0.0;
    if (_usesCoverHeader(
      hasCover: hasCover,
      hasCustomBottom: hasCustomBottom,
    )) {
      return AlbumCoverAppBar.resolveGeometry(
        context,
        collapsedHeight: toolbarHeight,
        bottomHeight: bottomHeight,
      );
    }
    return SliverAppBarComponent.resolveGeometry(
      context,
      subtitle: subtitle,
      expandedHeight: _sliverExpandedHeight,
      collapsedHeight: toolbarHeight,
      titleBuilderHeight: null,
      bottomHeight: bottomHeight,
    );
  }

  static bool _usesCoverHeader({
    required bool hasCover,
    required bool hasCustomBottom,
  }) => hasCover && !hasCustomBottom;

  final GalleryType type;
  final String? title;
  final String? subtitle;
  final SelectedFiles selectedFiles;
  final DeviceCollection? deviceCollection;
  final EnteFile? cover;
  final Widget? coverWidget;
  final List<Widget> Function({required bool onCover, Color? foregroundColor})?
  actionsBuilder;
  final String? coverHeroTag;
  final Key? coverAppBarKey;
  final List<EnteFile>? files;
  final MagicSortType magicSortType;
  final PreferredSizeWidget? bottom;
  final bool showOverflowMenu;

  const GalleryAppBarWidget._(
    this.type,
    this.title,
    this.selectedFiles, {
    this.subtitle,
    this.deviceCollection,
    this.cover,
    this.coverWidget,
    this.actionsBuilder,
    this.coverHeroTag,
    this.coverAppBarKey,
    this.files,
    required this.magicSortType,
    this.bottom,
    required this.showOverflowMenu,
  });

  @override
  State<GalleryAppBarWidget> createState() => _GalleryAppBarWidgetState();
}

// Offline fork: the album (server collection) actions are removed. Only the
// actions of the local gallery types remain.
enum AlbumPopupAction { albumSlideshow, editLocation, deleteLocation }

class _GalleryAppBarWidgetState extends State<GalleryAppBarWidget> {
  final _logger = Logger("GalleryAppBar");
  late Function() _selectedFilesListener;
  late String _appBarTitle;
  late GalleryType galleryType;

  @override
  void initState() {
    super.initState();
    _selectedFilesListener = () {
      setState(() {});
    };
    widget.selectedFiles.addListener(_selectedFilesListener);

    _appBarTitle = widget.title ?? "";
    galleryType = widget.type;
  }

  @override
  void didUpdateWidget(covariant GalleryAppBarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title) {
      _appBarTitle = widget.title ?? "";
    }
  }

  @override
  void dispose() {
    widget.selectedFiles.removeListener(_selectedFilesListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (galleryType == GalleryType.homepage) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final bottom = widget.bottom;
    if (GalleryAppBarWidget._usesCoverHeader(
      hasCover: widget.cover != null || widget.coverWidget != null,
      hasCustomBottom: bottom != null,
    )) {
      return _albumCoverAppBar(bottom: bottom);
    }
    return _GallerySliverAppBar(
      title: _appBarTitle,
      subtitle: widget.subtitle,
      actions: _getDefaultActions(context, onCover: false),
      bottom: bottom,
    );
  }

  Widget _albumCoverAppBar({PreferredSizeWidget? bottom}) {
    final strings = context.strings;
    return AlbumCoverAppBar(
      key: widget.coverAppBarKey,
      cover: widget.cover,
      coverWidget: widget.coverWidget,
      subtitle: widget.subtitle,
      heroTag: widget.coverHeroTag,
      title: _appBarTitle,
      backgroundColor: GalleryAppBarWidget.backgroundColor(context),
      collapsedHeight: GalleryAppBarWidget.toolbarHeight,
      bottom: bottom,
      actionsBuilder: (foregroundColor) => _getDefaultActions(
        context,
        onCover: true,
        foregroundColor: foregroundColor,
      ),
      coverActions: [
        if (widget.selectedFiles.files.isEmpty) ...[
          AlbumCoverActionButton(
            icon: HugeIcons.strokeRoundedPlay,
            tooltip: strings.slideshow,
            onTap: _startAlbumSlideshow,
          ),
        ],
      ],
    );
  }

  List<Widget> _getDefaultActions(
    BuildContext context, {
    required bool onCover,
    Color? foregroundColor,
  }) {
    if (widget.actionsBuilder != null) {
      return widget.actionsBuilder!(
        onCover: onCover,
        foregroundColor: foregroundColor,
      );
    }
    final List<Widget> actions = <Widget>[];
    final iconButtonVariant = onCover
        ? IconButtonComponentVariant.unfilled
        : IconButtonComponentVariant.primary;
    if (widget.selectedFiles.files.isNotEmpty) {
      return actions;
    }

    final strings = context.strings;
    if (galleryType == GalleryType.magic) {
      actions.add(
        IconButtonComponent(
          tooltip: strings.sort,
          icon: HugeIcon(
            icon: HugeIcons.strokeRoundedFilterHorizontal,
            color: foregroundColor,
          ),
          variant: iconButtonVariant,
          size: onCover ? kMinInteractiveDimension : 36,
          iconSize: onCover ? IconSizes.medium : IconSizes.small,
          shouldSurfaceExecutionStates: false,
          onTap: () async {
            final sortType = await showMagicSortSheet(
              context,
              sortType: widget.magicSortType,
            );
            if (mounted &&
                sortType != null &&
                sortType != widget.magicSortType) {
              Bus.instance.fire(MagicSortChangeEvent(sortType));
            }
          },
        ),
      );
    }

    // Offline fork: the album menu entries are removed. Location tags are
    // local data, so their edit and delete entries show without an account.
    final hasLocationMenu = galleryType == GalleryType.locationTag;
    final hasSlideshowMenu = !onCover && widget.deviceCollection != null;
    if (!widget.showOverflowMenu || !(hasLocationMenu || hasSlideshowMenu)) {
      return actions;
    }

    final overflowMenuAction = onCover
        ? galleryAppBarActionsSheetAction
        : galleryAppBarPopupMenuAction;
    actions.add(
      overflowMenuAction<AlbumPopupAction>(
        tooltip: strings.more,
        icon: HugeIcon(
          icon: HugeIcons.strokeRoundedMoreVertical,
          color: foregroundColor,
        ),
        optionsBuilder: () => [
          if (hasLocationMenu) ..._locationMenuOptions(strings),
          if (hasSlideshowMenu) _slideshowMenuOption(strings),
        ],
        onSelected: (AlbumPopupAction value) async {
          switch (value) {
            case AlbumPopupAction.albumSlideshow:
              await _startAlbumSlideshow();
            case AlbumPopupAction.editLocation:
              editLocation();
            case AlbumPopupAction.deleteLocation:
              await deleteLocation();
          }
        },
      ),
    );

    return actions;
  }

  List<EntePopupMenuOption<AlbumPopupAction>> _locationMenuOptions(
    StringsLocalizations strings,
  ) {
    final warningColor = context.componentColors.warning;
    return [
      _menuOption(
        AlbumPopupAction.editLocation,
        strings.editLocation,
        const HugeIcon(
          icon: HugeIcons.strokeRoundedLocation01,
          size: IconSizes.small,
        ),
      ),
      _menuOption(
        AlbumPopupAction.deleteLocation,
        strings.deleteLocation,
        Builder(
          builder: (context) => HugeIcon(
            icon: HugeIcons.strokeRoundedDelete01,
            size: IconSizes.small,
            color: context.componentColors.warning,
          ),
        ),
        labelColor: warningColor,
      ),
    ];
  }

  EntePopupMenuOption<AlbumPopupAction> _slideshowMenuOption(
    StringsLocalizations strings,
  ) {
    return _menuOption(
      AlbumPopupAction.albumSlideshow,
      strings.slideshow,
      const HugeIcon(
        icon: HugeIcons.strokeRoundedPresentation03,
        size: IconSizes.small,
      ),
    );
  }

  EntePopupMenuOption<AlbumPopupAction> _menuOption(
    AlbumPopupAction value,
    String label,
    Widget leadingWidget, {
    Color? labelColor,
  }) {
    return EntePopupMenuOption(
      value: value,
      label: label,
      labelColor: labelColor,
      leadingWidget: leadingWidget,
    );
  }

  Future<void> _startAlbumSlideshow() async {
    final dialog = createProgressDialog(context, context.strings.pleaseWait);
    await dialog.show();
    List<EnteFile>? galleryFiles;
    try {
      galleryFiles = await _loadAllGalleryFiles();
    } catch (e, s) {
      _logger.severe("Failed to load files for album slideshow", e, s);
    } finally {
      await dialog.hide();
    }
    if (!mounted) return;
    if (galleryFiles == null) {
      showToast(context, context.strings.somethingWentWrong);
      return;
    }

    await showAlbumSlideshow(
      context,
      files: galleryFiles,
      title: widget.deviceCollection?.name ?? _appBarTitle,
      includeBackupExcludedFiles:
          widget.deviceCollection != null || galleryType == GalleryType.cluster,
    );
  }

  Future<List<EnteFile>?> _loadAllGalleryFiles() async {
    if (widget.files != null) {
      return widget.files!;
    }

    final deviceCollection = widget.deviceCollection;
    if (deviceCollection == null) {
      return null;
    }
    final filesResult = await FilesDB.instance.getFilesInDeviceCollection(
      deviceCollection,
      galleryLoadStartTime,
      galleryLoadEndTime,
    );
    return filesResult.files;
  }

  void editLocation() {
    showEditLocationSheet(
      context,
      InheritedLocationScreenState.of(context).locationTagEntity,
    );
  }

  Future<void> deleteLocation() async {
    try {
      await locationService.deleteLocationTag(
        InheritedLocationScreenState.of(context).locationTagEntity.id,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      await showGenericErrorDialog(context: context, error: e);
    }
  }
}

class _GallerySliverAppBar extends StatelessWidget {
  const _GallerySliverAppBar({
    required this.title,
    this.subtitle,
    required this.actions,
    this.bottom,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;

  @override
  Widget build(BuildContext context) {
    return SliverAppBarComponent(
      title: title,
      subtitle: subtitle,
      actions: actions,
      bottom: bottom,
      expandedHeight: GalleryAppBarWidget._sliverExpandedHeight,
      collapsedHeight: GalleryAppBarWidget.toolbarHeight,
      backgroundColor: GalleryAppBarWidget.backgroundColor(context),
    );
  }
}

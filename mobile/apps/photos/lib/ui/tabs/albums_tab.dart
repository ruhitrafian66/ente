import "dart:async";
import "dart:io";

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:photos/core/constants.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/album_sort_order_change_event.dart";
import "package:photos/events/backup_folders_updated_event.dart";
import "package:photos/events/tab_changed_event.dart";
import "package:photos/service_locator.dart";
import "package:photos/settings/local_settings.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/collections/device/device_folders_vertical_grid_view.dart";
import "package:photos/ui/components/empty_state_component.dart";
import "package:photos/ui/viewer/gallery/trash_page.dart";
import "package:photos/utils/device_info.dart";

enum _AlbumsMenuAction { toggleView, name, lastUpdated }

class AlbumsTab extends StatefulWidget {
  const AlbumsTab({
    super.key,
    this.isActive = true,
    this.isSearchActiveNotifier,
    this.shouldConsumeBackNotifier,
  });

  final bool isActive;
  final ValueNotifier<bool>? isSearchActiveNotifier;
  final ValueNotifier<bool>? shouldConsumeBackNotifier;

  @override
  State<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends State<AlbumsTab>
    with AutomaticKeepAliveClientMixin {
  static const int _kAlbumsTabIndex = 1;
  static const double _kHeaderToolbarHeight = 60;
  static const Duration _kSearchTransitionDuration = Duration(
    milliseconds: 240,
  );
  static const Duration _kContentTransitionDuration = Duration(
    milliseconds: 150,
  );
  static const double _kContentBottomPadding = 200;

  late final ValueNotifier<AlbumViewType> _viewType = ValueNotifier(
    localSettings.albumViewType(),
  );
  late final ValueNotifier<AlbumSortKey> _sortKey = ValueNotifier(
    localSettings.albumSortKey(),
  );
  late final ValueNotifier<AlbumSortDirection> _sortDirection = ValueNotifier(
    localSettings.albumSortDirection(),
  );
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  ScrollController _scrollController = ScrollController();
  final List<ScrollController> _retiredScrollControllers = [];

  bool _isSearchActive = false;
  String _searchQuery = "";

  late final StreamSubscription<AlbumSortOrderChangeEvent>
  _albumSortOrderChangeEvent;
  late final StreamSubscription<BackupFoldersUpdatedEvent>
  _backupFoldersUpdatedEvent;
  late final StreamSubscription<TabChangedEvent> _tabChangedEvent;

  @override
  void initState() {
    super.initState();
    _albumSortOrderChangeEvent = Bus.instance
        .on<AlbumSortOrderChangeEvent>()
        .listen((_) {
          _syncSortState();
        });
    _backupFoldersUpdatedEvent = Bus.instance
        .on<BackupFoldersUpdatedEvent>()
        .listen((_) {
          if (mounted) {
            setState(() {});
          }
        });
    _tabChangedEvent = Bus.instance.on<TabChangedEvent>().listen(
      _handleTabChanged,
    );
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    widget.isSearchActiveNotifier?.addListener(_handleSearchStateChanged);
    _syncSearchNotifier(_isSearchActive);
    _syncSearchBackNotifier();
  }

  @override
  void didUpdateWidget(covariant AlbumsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSearchActiveNotifier != widget.isSearchActiveNotifier) {
      oldWidget.isSearchActiveNotifier?.removeListener(
        _handleSearchStateChanged,
      );
      widget.isSearchActiveNotifier?.addListener(_handleSearchStateChanged);
      _syncSearchNotifier(_isSearchActive);
    }
    if (oldWidget.shouldConsumeBackNotifier !=
        widget.shouldConsumeBackNotifier) {
      _syncSearchBackNotifier(false, oldWidget.shouldConsumeBackNotifier);
      _syncSearchBackNotifier();
    }
  }

  void _handleSearchStateChanged() {
    if (widget.isSearchActiveNotifier?.value == false && _isSearchActive) {
      _deactivateSearch(syncNotifier: false);
    }
  }

  void _handleTabChanged(TabChangedEvent event) {
    if (event.selectedIndex != _kAlbumsTabIndex) {
      _searchFocusNode.unfocus();
    }
  }

  void _handleSearchFocusChanged() {
    _syncSearchBackNotifier();
  }

  void _syncSearchNotifier(bool isSearchActive) {
    final notifier = widget.isSearchActiveNotifier;
    if (notifier == null || notifier.value == isSearchActive) return;
    notifier.value = isSearchActive;
  }

  void _syncSearchBackNotifier([
    bool? shouldConsumeBack,
    ValueNotifier<bool>? notifier,
  ]) {
    final backNotifier = notifier ?? widget.shouldConsumeBackNotifier;
    final shouldConsume =
        shouldConsumeBack ?? (_searchFocusNode.hasFocus || _hasSearchQuery);
    if (backNotifier == null || backNotifier.value == shouldConsume) return;
    backNotifier.value = shouldConsume;
  }

  bool get _hasSearchQuery => _searchQuery.trim().isNotEmpty;

  void _syncSortState() {
    _sortKey.value = localSettings.albumSortKey();
    _sortDirection.value = localSettings.albumSortDirection();
    _viewType.value = localSettings.albumViewType();
  }

  void _activateSearch() {
    if (_isSearchActive) return;
    setState(() {
      _isSearchActive = true;
    });
    _syncSearchNotifier(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _deactivateSearch({bool syncNotifier = true}) {
    _searchController.clear();
    _searchFocusNode.unfocus();
    if (!_isSearchActive && _searchQuery.isEmpty) {
      _syncSearchBackNotifier(false);
      if (syncNotifier) {
        _syncSearchNotifier(false);
      }
      return;
    }
    _resetScrollForNextContent();
    setState(() {
      _isSearchActive = false;
      _searchQuery = "";
    });
    _syncSearchBackNotifier(false);
    if (syncNotifier) {
      _syncSearchNotifier(false);
    }
  }

  void _resetScrollForNextContent() {
    final oldController = _scrollController;
    _retiredScrollControllers.add(oldController);
    _scrollController = ScrollController();
    Future<void>.delayed(
      _kContentTransitionDuration + const Duration(milliseconds: 50),
      () {
        if (!_retiredScrollControllers.remove(oldController)) {
          return;
        }
        oldController.dispose();
      },
    );
  }

  Widget _buildSearchSectionHeader(String title) {
    final textTheme = getEnteTextTheme(context);
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 16),
      child: Text(
        title,
        style: TextStyles.h2.copyWith(color: textTheme.largeBold.color),
      ),
    );
  }

  Widget _buildGlobalSearchEmptyStateSliver(StringsLocalizations strings) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: TickerMode(
        enabled: widget.isActive,
        child: EmptyStateComponent(
          assetPath: "assets/ente-nomatch-ducky.riv",
          animated: true,
          illustrationSize: const Size(181, 138),
          title: strings.noMatchesFound,
          textWidth: 240,
        ),
      ),
    );
  }

  Widget _buildGlobalSearchResultsSliver(StringsLocalizations strings) {
    return SliverMainAxisGroup(
      slivers: [
        DeviceFolderVerticalGridSliver(
          key: const ValueKey("album_search_local_device_folders"),
          searchQuery: _searchQuery.trim(),
          albumViewType: _viewType.value,
          sortKey: _sortKey.value,
          sortDirection: _sortDirection.value,
          showEmptyState: true,
          topPadding: 8,
          bottomPadding: 0,
          sectionHeader: _buildSearchSectionHeader(strings.onDevice),
          emptyStateSliver: _buildGlobalSearchEmptyStateSliver(strings),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: _kContentBottomPadding),
        ),
      ],
    );
  }

  Widget _buildContentSliver(StringsLocalizations strings) {
    if (_hasSearchQuery) {
      return _buildGlobalSearchResultsSliver(strings);
    }
    return DeviceFolderVerticalGridSliver(
      searchQuery: _searchQuery.trim(),
      albumViewType: _viewType.value,
      sortKey: _sortKey.value,
      sortDirection: _sortDirection.value,
      bottomPadding: _kContentBottomPadding,
    );
  }

  Key _contentStateKey() {
    return ValueKey<Object>((
      _hasSearchQuery ? "search" : "filter",
      _viewType.value,
    ));
  }

  Future<void> _toggleViewMode() async {
    final next = _viewType.value == AlbumViewType.grid
        ? AlbumViewType.list
        : AlbumViewType.grid;
    _viewType.value = next;
    await localSettings.setAlbumViewType(next);
  }

  Future<void> _setSortMode(AlbumSortKey key) async {
    AlbumSortDirection nextDirection;
    if (_sortKey.value == key) {
      nextDirection = _sortDirection.value == AlbumSortDirection.ascending
          ? AlbumSortDirection.descending
          : AlbumSortDirection.ascending;
    } else {
      nextDirection = AlbumSortDirection.ascending;
    }

    _sortKey.value = key;
    _sortDirection.value = nextDirection;
    await localSettings.setAlbumSortKey(key);
    await localSettings.setAlbumSortDirection(nextDirection);
    if (mounted) {
      Bus.instance.fire(AlbumSortOrderChangeEvent());
    }
  }

  List<EntePopupMenuOption<_AlbumsMenuAction>> _buildAlbumsMenuOptions() {
    final strings = context.strings;
    final isListView = _viewType.value == AlbumViewType.list;
    final showSortActions = !_hasSearchQuery;
    final currentSortKey = _sortKey.value;
    final currentSortDirection = _sortDirection.value;
    final nameSortDirection = currentSortKey == AlbumSortKey.albumName
        ? currentSortDirection
        : null;
    final activeTrailingWidget = HugeIcon(
      icon: currentSortDirection == AlbumSortDirection.ascending
          ? HugeIcons.strokeRoundedArrowUp02
          : HugeIcons.strokeRoundedArrowDown02,
      size: 12,
      strokeWidth: 3,
    );

    return [
      EntePopupMenuOption(
        value: _AlbumsMenuAction.toggleView,
        label: isListView ? strings.grid : strings.list,
        showDivider: showSortActions,
        trailingWidget: HugeIcon(
          icon: isListView
              ? HugeIcons.strokeRoundedGridView
              : HugeIcons.strokeRoundedMenu01,
          size: 12,
          strokeWidth: 3,
        ),
      ),
      if (showSortActions) ...[
        EntePopupMenuOption(
          value: _AlbumsMenuAction.name,
          label: strings.name,
          secondaryLabel: nameSortDirection != AlbumSortDirection.descending
              ? strings.sortAToZ
              : strings.sortZToA,
          isActive: currentSortKey == AlbumSortKey.albumName,
        ),
        EntePopupMenuOption(
          value: _AlbumsMenuAction.lastUpdated,
          label: strings.lastUpdated,
          isActive: currentSortKey == AlbumSortKey.lastUpdated,
          activeTrailingWidget: activeTrailingWidget,
          showDivider: false,
        ),
      ],
    ];
  }

  Future<void> _handleAlbumsMenuSelection(_AlbumsMenuAction selected) async {
    switch (selected) {
      case _AlbumsMenuAction.toggleView:
        await _toggleViewMode();
        break;
      case _AlbumsMenuAction.name:
        await _setSortMode(AlbumSortKey.albumName);
        break;
      case _AlbumsMenuAction.lastUpdated:
        await _setSortMode(AlbumSortKey.lastUpdated);
        break;
    }
  }

  Future<void> _showAlbumsOptionsMenu(BuildContext buttonContext) async {
    final options = _buildAlbumsMenuOptions();
    if (options.isEmpty) {
      return;
    }
    final selected = await showEntePopupMenu<_AlbumsMenuAction>(
      context: buttonContext,
      options: options,
    );
    if (selected == null || !mounted) return;
    await _handleAlbumsMenuSelection(selected);
  }

  @override
  void dispose() {
    _albumSortOrderChangeEvent.cancel();
    _backupFoldersUpdatedEvent.cancel();
    _tabChangedEvent.cancel();
    widget.isSearchActiveNotifier?.removeListener(_handleSearchStateChanged);
    _syncSearchBackNotifier(false);
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    for (final controller in _retiredScrollControllers) {
      controller.dispose();
    }
    _retiredScrollControllers.clear();
    _viewType.dispose();
    _sortKey.dispose();
    _sortDirection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final componentColors = context.componentColors;
    final textTheme = getEnteTextTheme(context);
    final strings = context.strings;
    final albumsOptionsButton = Builder(
      builder: (buttonContext) => IconButtonComponent(
        tooltip: strings.sort,
        variant: IconButtonComponentVariant.primary,
        shouldSurfaceExecutionStates: false,
        icon: const HugeIcon(icon: HugeIcons.strokeRoundedFilterHorizontal),
        onTap: () => unawaited(_showAlbumsOptionsMenu(buttonContext)),
      ),
    );
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: _kHeaderToolbarHeight,
              child: AnimatedSwitcher(
                duration: _kSearchTransitionDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previousChildren, ?currentChild],
                ),
                transitionBuilder: (child, animation) {
                  final curvedAnimation = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  );
                  final beginOffset =
                      child.key == const ValueKey("albums_search_toolbar")
                      ? const Offset(0.035, 0)
                      : const Offset(-0.035, 0);
                  return FadeTransition(
                    opacity: curvedAnimation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: beginOffset,
                        end: Offset.zero,
                      ).animate(curvedAnimation),
                      child: child,
                    ),
                  );
                },
                child: _isSearchActive
                    ? Row(
                        key: const ValueKey("albums_search_toolbar"),
                        children: [
                          Expanded(
                            child: TextInputComponent(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              hintText: strings.searchAlbums,
                              autofocus: true,
                              shouldUnfocusOnClearOrSubmit: true,
                              prefix: HugeIcon(
                                icon: HugeIcons.strokeRoundedSearch01,
                                size: 18,
                                color: componentColors.textLight,
                              ),
                              suffix: HugeIcon(
                                icon: HugeIcons.strokeRoundedCancel01,
                                size: 18,
                                color: componentColors.textLight,
                              ),
                              onSuffixTap: _deactivateSearch,
                              onChanged: (value) {
                                final hadSearchQuery = _hasSearchQuery;
                                if (!hadSearchQuery &&
                                    value.trim().isNotEmpty) {
                                  _resetScrollForNextContent();
                                }
                                setState(() {
                                  _searchQuery = value;
                                });
                                _syncSearchBackNotifier();
                              },
                            ),
                          ),
                        ],
                      )
                    : Row(
                        key: const ValueKey("albums_title_toolbar"),
                        children: [
                          Expanded(
                            child: Text(
                              strings.albums,
                              key: const ValueKey("albums_title"),
                              style: TextStyles.display1.copyWith(
                                color: textTheme.h4Bold.color,
                              ),
                            ),
                          ),
                          IconButtonComponent(
                            tooltip: strings.search,
                            variant: IconButtonComponentVariant.primary,
                            shouldSurfaceExecutionStates: false,
                            icon: const HugeIcon(
                              icon: HugeIcons.strokeRoundedSearch01,
                            ),
                            onTap: _activateSearch,
                          ),
                          const SizedBox(width: 6),
                          albumsOptionsButton,
                          const _LocalGalleryTrashButton(
                            before: SizedBox(width: 6),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _viewType,
                _sortKey,
                _sortDirection,
              ]),
              builder: (context, _) {
                return AnimatedSwitcher(
                  duration: _kContentTransitionDuration,
                  reverseDuration: _kContentTransitionDuration,
                  switchInCurve: Curves.easeInQuart,
                  switchOutCurve: Curves.easeOutExpo,
                  layoutBuilder: (currentChild, previousChildren) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        for (final previousChild in previousChildren)
                          Positioned.fill(
                            child: HeroMode(
                              enabled: false,
                              child: previousChild,
                            ),
                          ),
                        if (currentChild != null)
                          Positioned.fill(child: HeroMode(child: currentChild)),
                      ],
                    );
                  },
                  transitionBuilder: (child, animation) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                  child: Scrollbar(
                    key: _contentStateKey(),
                    controller: _scrollController,
                    interactive: true,
                    child: CustomScrollView(
                      controller: _scrollController,
                      physics: const BouncingScrollPhysics(),
                      slivers: [_buildContentSliver(strings)],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _LocalGalleryTrashButton extends StatefulWidget {
  final Widget before;

  const _LocalGalleryTrashButton({required this.before});

  @override
  State<_LocalGalleryTrashButton> createState() =>
      _LocalGalleryTrashButtonState();
}

class _LocalGalleryTrashButtonState extends State<_LocalGalleryTrashButton> {
  late final Future<bool> _isTrashSupported;

  @override
  void initState() {
    _isTrashSupported = (() async {
      return Platform.isAndroid &&
          !await isAndroidSDKVersionLowerThan(android11SDKINT);
    })();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _isTrashSupported,
      builder: (_, snapshot) => (snapshot.data ?? false)
          ? Row(
              children: [
                widget.before,
                IconButtonComponent(
                  tooltip: context.strings.trash,
                  variant: IconButtonComponentVariant.primary,
                  shouldSurfaceExecutionStates: false,
                  icon: const HugeIcon(icon: HugeIcons.strokeRoundedDelete02),
                  onTap: () => showTrashPage(context),
                ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}

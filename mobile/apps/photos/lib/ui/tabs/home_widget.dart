import "dart:async";
import "dart:io";

import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:flutter/scheduler.dart";
import "package:flutter_local_notifications/flutter_local_notifications.dart";
import "package:logging/logging.dart";
import "package:media_extension/media_extension_action_types.dart";
import "package:move_to_background/move_to_background.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/events/app_mode_changed_event.dart";
import "package:photos/events/backup_folders_updated_event.dart";
import "package:photos/events/christmas_banner_event.dart";
import "package:photos/events/clear_and_unfocus_search_bar_event.dart";
import "package:photos/events/homepage_swipe_to_select_in_progress_event.dart";
import "package:photos/events/opened_settings_event.dart";
import "package:photos/events/permission_granted_event.dart";
import "package:photos/events/sync_status_update_event.dart";
import "package:photos/events/tab_changed_event.dart";
import "package:photos/events/trigger_logout_event.dart";
import "package:photos/events/user_logged_out_event.dart";
import "package:photos/models/home_tab.dart";
import "package:photos/models/search/index_of_indexed_stack.dart";
import "package:photos/models/selected_albums.dart";
import "package:photos/models/selected_files.dart";
import "package:photos/offline_fork.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/app_lifecycle_service.dart";
import "package:photos/services/app_navigation_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/services/machine_learning/semantic_search/semantic_search_service.dart";
import "package:photos/services/memory_home_widget_service.dart";
import "package:photos/services/notification_service.dart";
import "package:photos/services/people_home_widget_service.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/models/button_type.dart";
import "package:photos/ui/extents_page_view.dart";
import "package:photos/ui/home/christmas/christmas_pull_animation.dart";
import "package:photos/ui/home/christmas/christmas_utils.dart";
import "package:photos/ui/home/christmas/snow_fall_overlay.dart";
import "package:photos/ui/home/grant_permissions_widget.dart";
import "package:photos/ui/home/header_widget.dart";
import "package:photos/ui/home/home_bottom_nav_bar.dart";
import "package:photos/ui/home/home_gallery_widget.dart";
import "package:photos/ui/home/loading_photos_widget.dart";
import "package:photos/ui/rewind/entry/rewind_entry.dart";
import "package:photos/ui/settings_page.dart";
import "package:photos/ui/tabs/albums_tab.dart";
import "package:photos/ui/viewer/actions/file_viewer.dart";
import "package:photos/ui/viewer/search_tab/search_tab.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/intent_util.dart";
import "package:receive_sharing_intent/receive_sharing_intent.dart";

class HomeWidget extends StatefulWidget {
  const HomeWidget({super.key});

  @override
  State<StatefulWidget> createState() => _HomeWidgetState();
}

class _HomeWidgetState extends State<HomeWidget> {
  final _logger = Logger("HomeWidgetState");
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // Offline fork: always empty (no server albums). Kept only because
  // HomeBottomNavigationBar still takes it.
  final _selectedAlbums = SelectedAlbums();
  final _selectedFiles = SelectedFiles();
  final _hasSelectedFilesNotifier = ValueNotifier<bool>(false);

  final PageController _pageController = PageController();
  int _selectedTabIndex = 0;
  final ValueNotifier<int> _selectedTabIndexNotifier = ValueNotifier<int>(0);
  final ValueNotifier<double> _christmasPullOffsetNotifier =
      ValueNotifier<double>(0);
  final ValueNotifier<bool> _christmasPullReleasedNotifier =
      ValueNotifier<bool>(false);

  // ignore: unused_field
  StreamSubscription? _intentDataStreamSubscription;
  bool _mediaViewFallbackNavigationScheduled = false;
  bool _personSyncTriggered = false;
  // Offline fork: always use the account-free entry flow, so the landing
  // (sign-up / login) page is unreachable.
  bool _startWithoutAccount =
      kOfflineFork || localSettings.isLocalGalleryOnboardingPending;
  final isOnSearchTabNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isAlbumsSearchActiveNotifier = ValueNotifier<bool>(
    false,
  );
  final ValueNotifier<bool> _shouldAlbumsSearchConsumeBackNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<bool> _shouldSearchTabSearchConsumeBackNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<bool> _swipeToSelectInProgressNotifier =
      ValueNotifier<bool>(false);

  late StreamSubscription<TabChangedEvent> _tabChangedEventSubscription;
  late StreamSubscription<TriggerLogoutEvent> _triggerLogoutEvent;
  late StreamSubscription<UserLoggedOutEvent> _loggedOutEvent;
  late StreamSubscription<PermissionGrantedEvent> _permissionGrantedEvent;
  late StreamSubscription<SyncStatusUpdate> _firstImportEvent;
  late StreamSubscription<BackupFoldersUpdatedEvent> _backupFoldersUpdatedEvent;
  late StreamSubscription<HomepageSwipeToSelectInProgressEvent>
  _homepageSwipeToSelectInProgressEventSubscription;
  late StreamSubscription<ChristmasBannerEvent>
  _christmasBannerEventSubscription;
  late StreamSubscription<AppModeChangedEvent> _appModeChangedEventSubscription;

  List<int> get _tabIndices => homeTabIndices(showFeed: !isLocalGalleryMode);

  @override
  void initState() {
    _logger.info("initstate");
    super.initState();
    _selectedFiles.addListener(_selectedFilesListener);

    NotificationService.instance
        .initialize(_onDidReceiveNotificationResponse)
        .ignore();

    if (LocalSyncService.instance.hasCompletedFirstImportOrBypassed()) {
      syncWidget();
    }
    _tabChangedEventSubscription = Bus.instance.on<TabChangedEvent>().listen((
      event,
    ) {
      final tabIndices = _tabIndices;
      final pageIndex = tabIndices.indexOf(event.selectedIndex);
      if (pageIndex < 0) return;
      final previousTabIndex = _selectedTabIndex;
      _selectedTabIndex = event.selectedIndex;
      _selectedTabIndexNotifier.value = event.selectedIndex;

      if (event.selectedIndex == searchTabIndex) {
        isOnSearchTabNotifier.value = true;
        unawaited(SemanticSearchService.instance.prepareForInteractiveSearch());
      } else {
        isOnSearchTabNotifier.value = false;
      }
      if (event.source != TabChangedEventSource.pageView) {
        debugPrint(
          "TabChange going from $previousTabIndex to ${event.selectedIndex} source: ${event.source}",
        );
        if (_pageController.hasClients) {
          final pageDelta = (pageIndex - tabIndices.indexOf(previousTabIndex))
              .abs();
          if (pageDelta <= 1 && event.source != TabChangedEventSource.appMode) {
            _pageController.animateToPage(
              pageIndex,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
            );
          } else {
            _pageController.jumpToPage(pageIndex);
          }
        }
      }
    });
    _triggerLogoutEvent = Bus.instance.on<TriggerLogoutEvent>().listen((
      event,
    ) async {
      await _autoLogoutAlert();
    });
    _loggedOutEvent = Bus.instance.on<UserLoggedOutEvent>().listen((event) {
      _logger.info('logged out, selectTab index to 0');
      _selectedTabIndex = 0;
      _selectedTabIndexNotifier.value = 0;
      isOnSearchTabNotifier.value = false;
      // Offline fork: never leave the account-free flow.
      _startWithoutAccount = kOfflineFork;
      if (mounted) {
        setState(() {});
      }
    });
    _permissionGrantedEvent = Bus.instance.on<PermissionGrantedEvent>().listen((
      event,
    ) async {
      if (mounted) {
        setState(() {});
      }
    });
    _appModeChangedEventSubscription = Bus.instance
        .on<AppModeChangedEvent>()
        .listen((event) async {
          if (mounted) {
            final selectedTabIndex = _tabIndices.contains(_selectedTabIndex)
                ? _selectedTabIndex
                : 0;
            setState(() {});
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              Bus.instance.fire(
                TabChangedEvent(
                  selectedTabIndex,
                  TabChangedEventSource.appMode,
                ),
              );
            });
          }
        });
    _firstImportEvent = Bus.instance.on<SyncStatusUpdate>().listen((
      event,
    ) async {
      if (mounted && event.status == SyncStatus.completedFirstGalleryImport) {
        Duration delayInRefresh = const Duration(milliseconds: 0);
        // Let navigation to BackupFolderSelectionPage finish before rebuilding.
        if (!permissionService.hasGrantedLimitedPermissions()) {
          delayInRefresh = const Duration(milliseconds: 250);
        }
        Future.delayed(delayInRefresh, () {
          if (mounted) {
            setState(() {});
            syncWidget();
          }
        });
      }
    });
    _backupFoldersUpdatedEvent = Bus.instance
        .on<BackupFoldersUpdatedEvent>()
        .listen((event) async {
          if (mounted) {
            setState(() {});
          }
        });

    _initMediaShareSubscription();

    _homepageSwipeToSelectInProgressEventSubscription = Bus.instance
        .on<HomepageSwipeToSelectInProgressEvent>()
        .listen((inProgress) {
          _swipeToSelectInProgressNotifier.value = inProgress.isInProgress;
        });

    _christmasBannerEventSubscription = Bus.instance
        .on<ChristmasBannerEvent>()
        .listen((_) {
          if (mounted) {
            setState(() {});
          }
        });
  }

  Future<void> syncWidget() async {
    await Future.delayed(const Duration(seconds: 5));

    _logger.info("Syncing home widget");
    await PeopleHomeWidgetService.instance.checkPendingPeopleSync();
    await MemoryHomeWidgetService.instance.checkPendingMemorySync();
  }

  bool get _isGuestViewActive =>
      AppNavigationService.instance.isGuestViewActive;

  Future<void> _autoLogoutAlert() async {
    final AlertDialog alert = AlertDialog(
      title: Text(context.strings.sessionExpired),
      content: Text(context.strings.pleaseLoginAgain),
      actions: [
        TextButton(
          child: Text(
            context.strings.ok,
            style: TextStyle(
              color: Theme.of(context).colorScheme.greenAlternative,
            ),
          ),
          onPressed: () async {
            Navigator.of(context).pop('dialog');
            Navigator.of(context).popUntil((route) => route.isFirst);
            final dialog = createProgressDialog(
              context,
              context.strings.loggingOut,
            );
            await dialog.show();
            await Configuration.instance.logout();
            await dialog.hide();
          },
        ),
      ],
    );

    await showDialog(
      useRootNavigator: false,
      context: context,
      builder: (BuildContext context) {
        return alert;
      },
    );
  }

  void _selectedFilesListener() {
    _hasSelectedFilesNotifier.value = _selectedFiles.files.isNotEmpty;
  }

  @override
  void dispose() {
    _selectedFiles.removeListener(_selectedFilesListener);
    _hasSelectedFilesNotifier.dispose();
    _tabChangedEventSubscription.cancel();
    _triggerLogoutEvent.cancel();
    _loggedOutEvent.cancel();
    _permissionGrantedEvent.cancel();
    _appModeChangedEventSubscription.cancel();
    _firstImportEvent.cancel();
    _backupFoldersUpdatedEvent.cancel();
    _intentDataStreamSubscription?.cancel();
    isOnSearchTabNotifier.dispose();
    _isAlbumsSearchActiveNotifier.dispose();
    _shouldAlbumsSearchConsumeBackNotifier.dispose();
    _shouldSearchTabSearchConsumeBackNotifier.dispose();
    _pageController.dispose();
    _homepageSwipeToSelectInProgressEventSubscription.cancel();
    _christmasBannerEventSubscription.cancel();
    _swipeToSelectInProgressNotifier.dispose();
    _selectedTabIndexNotifier.dispose();
    _christmasPullOffsetNotifier.dispose();
    _christmasPullReleasedNotifier.dispose();
    super.dispose();
  }

  void _initMediaShareSubscription() {
    _intentDataStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(
          (List<SharedMediaFile> value) {
            unawaited(_handleSharedMediaStream(value));
          },
          onError: (err) {
            _logger.severe("getIntentDataStream error: $err");
          },
        );
    ReceiveSharingIntent.instance.getInitialMedia().then((
      List<SharedMediaFile> value,
    ) {
      unawaited(_handleInitialSharedMedia(value));
    });
  }

  Future<void> _handleSharedMediaStream(List<SharedMediaFile> value) async {
    if (!mounted || _isGuestViewActive || value.isEmpty) {
      return;
    }

    // Offline fork: a public album link needs the network. Ignore it.
    if (_isPublicAlbumUrl(value[0].path)) {
      return;
    }

    if (await _consumeAndroidMediaViewIntent()) {
      if (!mounted || _isGuestViewActive) return;
      _scheduleMediaViewFallbackNavigation();
      return;
    }

    if (!mounted || _isGuestViewActive) {
      return;
    }
    if (value[0].mimeType != null &&
        (value[0].mimeType!.contains("image") ||
            value[0].mimeType!.contains("video"))) {
      unawaited(
        showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              actions: [
                const SizedBox(height: 24),
                ButtonWidget(
                  labelText: context.strings.openFile,
                  buttonType: ButtonType.primary,
                  onTap: () async {
                    Navigator.of(context).pop(true);
                  },
                ),
              ],
            );
          },
        ).then((shouldOpenFile) {
          if (!mounted || _isGuestViewActive || shouldOpenFile != true) {
            return;
          }
          unawaited(
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) {
                  return FileViewer(sharedMediaFile: value[0]);
                },
              ),
            ),
          );
        }),
      );
    }
  }

  Future<void> _handleInitialSharedMedia(List<SharedMediaFile> value) async {
    if (!mounted || _isGuestViewActive) {
      return;
    }
    // Offline fork: a public album link needs the network. Ignore it.
    if (value.isNotEmpty && _isPublicAlbumUrl(value[0].path)) {
      return;
    }

    if (await _consumeAndroidMediaViewIntent()) {
      if (!mounted || _isGuestViewActive) {
        return;
      }
      unawaited(
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) {
              return const FileViewer();
            },
          ),
        ),
      );
    }
    // Offline fork: media shared to the app at start had only the "add to
    // album" (upload) sheet as its target. That sheet is gone.
  }

  Future<bool> _consumeAndroidMediaViewIntent() async {
    if (!Platform.isAndroid || _isGuestViewActive) {
      return false;
    }

    final mediaExtensionAction = await initIntentAction();
    if (!mounted || _isGuestViewActive) return false;

    final isMediaView = _isMediaViewAction(mediaExtensionAction);
    if (isMediaView) {
      _logger.info("Consuming shared media callback for Android media view");
      await ReceiveSharingIntent.instance.reset();
      if (!mounted || _isGuestViewActive) return false;
    }

    AppLifecycleService.instance.setMediaExtensionAction(mediaExtensionAction);
    return isMediaView;
  }

  bool _isMediaViewAction(MediaExtentionAction action) {
    return action.action == IntentAction.view &&
        (action.type == MediaType.image || action.type == MediaType.video);
  }

  void _scheduleMediaViewFallbackNavigation() {
    if (_mediaViewFallbackNavigationScheduled) {
      return;
    }
    _mediaViewFallbackNavigationScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      _mediaViewFallbackNavigationScheduled = false;
      if (!mounted ||
          _isGuestViewActive ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      unawaited(
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) {
              return const FileViewer();
            },
          ),
        ),
      );
    });
  }

  bool _isPublicAlbumUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? "";
    return _isPublicAlbumHost(host);
  }

  bool _isPublicAlbumHost(String host) {
    return host == "albums.ente.io" || host == "albums.ente.com";
  }

  @override
  Widget build(BuildContext context) {
    _logger.info("Building home_Widget with tab $_selectedTabIndex");
    final enableDrawer = _shouldEnableDrawer();
    final action = AppLifecycleService.instance.mediaExtensionAction.action;
    final isOnOnlineGrantPermissionScreen =
        Configuration.instance.hasConfiguredAccount() &&
        !isLocalGalleryMode &&
        _shouldShowPermissionWidget();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final isStartWithoutAccountFlow =
            _startWithoutAccount &&
            !Configuration.instance.hasConfiguredAccount() &&
            !localSettings.isAppModeSet;
        // Offline fork: isAppModeSet is always true, so this branch (back
        // to the landing page) cannot run.
        if (isStartWithoutAccountFlow) {
          unawaited(localSettings.setLocalGalleryOnboardingPending(false));
          setState(() {
            _startWithoutAccount = false;
          });
          return;
        }
        if (_selectedTabIndex == 0) {
          if (_selectedFiles.files.isNotEmpty) {
            _selectedFiles.clearAll();
            return;
          }
          if (_isDrawerOpen()) {
            Navigator.pop(context);
          } else if (Platform.isAndroid && action == IntentAction.main) {
            unawaited(MoveToBackground.moveTaskToBack());
          } else {
            Navigator.pop(context);
          }
          return;
        }
        if (_selectedTabIndex == 1) {
          if (_shouldAlbumsSearchConsumeBackNotifier.value) {
            _isAlbumsSearchActiveNotifier.value = false;
            return;
          }
          if (_isAlbumsSearchActiveNotifier.value) {
            _isAlbumsSearchActiveNotifier.value = false;
          }
        }
        if (_selectedTabIndex == searchTabIndex) {
          if (_shouldSearchTabSearchConsumeBackNotifier.value) {
            Bus.instance.fire(ClearAndUnfocusSearchBar());
            return;
          }
        }
        Bus.instance.fire(TabChangedEvent(0, TabChangedEventSource.backButton));
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawerScrimColor: getEnteColorScheme(context).strokeFainter,
        drawerEnableOpenDragGesture: false,
        drawer: enableDrawer
            ? ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width < 600
                      ? double.infinity
                      : 430,
                ),
                child: const Drawer(
                  width: double.infinity,
                  shape: RoundedRectangleBorder(),
                  child: SettingsPage(),
                ),
              )
            : null,
        onDrawerChanged: (isOpened) {
          if (isOpened) {
            Bus.instance.fire(OpenedSettingsEvent());
          }
        },
        body: Stack(
          children: [
            Builder(
              builder: (context) {
                return _getBody(context);
              },
            ),
            if (isChristmasPeriod())
              ValueListenableBuilder<double>(
                valueListenable: _christmasPullOffsetNotifier,
                builder: (context, pullOffset, child) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: _christmasPullReleasedNotifier,
                    builder: (context, isReleased, child) {
                      if (pullOffset <= 0) {
                        return const SizedBox.shrink();
                      }
                      return Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: ChristmasPullOverlay(
                          pullOffset: pullOffset,
                          isReleased: isReleased,
                        ),
                      );
                    },
                  );
                },
              ),
            if (isChristmasPeriod())
              Positioned.fill(
                child: FadingSnowOverlay(
                  pullOffsetNotifier: _christmasPullOffsetNotifier,
                ),
              ),
          ],
        ),

        // Keep an AppBar so the status bar color follows the current screen.
        appBar: isOnOnlineGrantPermissionScreen
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(0),
                child: ValueListenableBuilder<bool>(
                  valueListenable: isOnSearchTabNotifier,
                  builder: (context, isOnSearchTab, _) {
                    return AnimatedBuilder(
                      animation: IndexOfStackNotifier(),
                      builder: (context, _) {
                        final colorScheme = getEnteColorScheme(context);
                        final resultsBackground = EnteTheme.isDark(context)
                            ? colorScheme.backgroundColour
                            : colorScheme.backgroundElevated2;
                        final isSearchResults =
                            isOnSearchTab && IndexOfStackNotifier().index == 1;
                        final isOnLandingPage =
                            !Configuration.instance.hasConfiguredAccount() &&
                            !isLocalGalleryMode &&
                            !_startWithoutAccount;
                        final isOnOnlineGrantPermissionScreen =
                            Configuration.instance.hasConfiguredAccount() &&
                            !isLocalGalleryMode &&
                            _shouldShowPermissionWidget();
                        return AppBar(
                          backgroundColor: isOnLandingPage
                              ? colorScheme.greenBase
                              : isSearchResults
                              ? resultsBackground
                              : isOnOnlineGrantPermissionScreen
                              ? colorScheme.backgroundColour
                              : colorScheme.backgroundColour,
                        );
                      },
                    );
                  },
                ),
              ),
        resizeToAvoidBottomInset: false,
      ),
    );
  }

  Widget _getBody(BuildContext context) {
    final bool localGalleryMode = isLocalGalleryMode;
    final tabIndices = _tabIndices;
    if (!Configuration.instance.hasConfiguredAccount()) {
      _closeDrawerIfOpen();
      final shouldBootstrapLocalGalleryEntryFlow =
          _startWithoutAccount && !localGalleryMode;
      final hasPersistedLocalGalleryMode =
          localSettings.isAppModeSet && localGalleryMode;
      final canResumePersistedLocalGalleryMode =
          hasPersistedLocalGalleryMode &&
          permissionService.hasGrantedPermissions();
      final shouldUseLocalGalleryEntryFlow =
          _startWithoutAccount || canResumePersistedLocalGalleryMode;

      if (shouldBootstrapLocalGalleryEntryFlow) {
        return const GrantPermissionsWidget(startWithoutAccount: true);
      }
      if (shouldUseLocalGalleryEntryFlow && _shouldShowPermissionWidget()) {
        return const GrantPermissionsWidget(startWithoutAccount: true);
      }
      // Offline fork: there is no landing (sign-up / login) page.
      if (!shouldUseLocalGalleryEntryFlow) {
        return const GrantPermissionsWidget(startWithoutAccount: true);
      }
    }
    _ensurePersonSync();
    if (_shouldShowPermissionWidget()) {
      _ensurePersonSync();
      return const GrantPermissionsWidget();
    }
    if (_shouldShowLoadingWidget()) {
      return const LoadingPhotosWidget();
    }

    return Stack(
      children: [
        Builder(
          builder: (context) {
            return ListenableBuilder(
              listenable: Listenable.merge([
                _swipeToSelectInProgressNotifier,
                _hasSelectedFilesNotifier,
              ]),
              builder: (context, child) {
                final isPageScrollLocked =
                    _swipeToSelectInProgressNotifier.value ||
                    _hasSelectedFilesNotifier.value;
                return ValueListenableBuilder<int>(
                  valueListenable: _selectedTabIndexNotifier,
                  builder: (context, selectedTabIndex, _) {
                    return ExtentsPageView(
                      onPageChanged: (page) {
                        if (page >= tabIndices.length) return;
                        Bus.instance.fire(
                          TabChangedEvent(
                            tabIndices[page],
                            TabChangedEventSource.pageView,
                          ),
                        );
                      },
                      controller: _pageController,
                      openDrawer: Scaffold.of(context).openDrawer,
                      physics: isPageScrollLocked
                          ? const NeverScrollableScrollPhysics()
                          : const NoLeftBounceScrollPhysics(),
                      children: [
                        _buildTabHeroMode(0, selectedTabIndex, child!),
                        _buildTabHeroMode(
                          1,
                          selectedTabIndex,
                          AlbumsTab(
                            isActive: selectedTabIndex == 1,
                            isSearchActiveNotifier:
                                _isAlbumsSearchActiveNotifier,
                            shouldConsumeBackNotifier:
                                _shouldAlbumsSearchConsumeBackNotifier,
                          ),
                        ),
                        _buildTabHeroMode(
                          3,
                          selectedTabIndex,
                          SearchTab(
                            shouldConsumeBackNotifier:
                                _shouldSearchTabSearchConsumeBackNotifier,
                            isOnSearchTab: isOnSearchTabNotifier,
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (!isChristmasPeriod()) return false;

                  if (notification.metrics.axis != Axis.vertical) return false;

                  const double maxPullOffset = 200.0;

                  if (notification is ScrollUpdateNotification) {
                    final double pixels = notification.metrics.pixels;
                    if (pixels < 0) {
                      if (pixels < -maxPullOffset) {
                        final scrollPosition = Scrollable.of(
                          notification.context!,
                        ).position;
                        scrollPosition.correctBy(-maxPullOffset - pixels);
                      }

                      final double clampedOffset = (-pixels).clamp(
                        0.0,
                        maxPullOffset,
                      );
                      _christmasPullOffsetNotifier.value = clampedOffset;
                      if (_christmasPullReleasedNotifier.value) {
                        _christmasPullReleasedNotifier.value = false;
                      }
                    } else if (_christmasPullOffsetNotifier.value != 0) {
                      _christmasPullOffsetNotifier.value = 0;
                    }
                  } else if (notification is ScrollEndNotification) {
                    if (_christmasPullOffsetNotifier.value > 0) {
                      _christmasPullReleasedNotifier.value = true;
                    }
                  }
                  return false;
                },
                child: HomeGalleryWidget(
                  header: const HeaderWidget(),
                  footer: const SizedBox(height: 160),
                  selectedFiles: _selectedFiles,
                ),
              ),
            );
          },
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: ValueListenableBuilder(
            valueListenable: isOnSearchTabNotifier,
            builder: (context, value, child) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HomeBottomNavigationBar(
                    _selectedFiles,
                    _selectedAlbums,
                    selectedTabIndex: _selectedTabIndex,
                    showFeed: !localGalleryMode,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTabHeroMode(int tabIndex, int selectedTabIndex, Widget child) {
    return ClipRect(
      child: HeroMode(enabled: tabIndex == selectedTabIndex, child: child),
    );
  }

  bool _isDrawerOpen() {
    return _scaffoldKey.currentState?.isDrawerOpen ?? false;
  }

  void _closeDrawerIfOpen() {
    if (_isDrawerOpen()) {
      SchedulerBinding.instance.addPostFrameCallback((timeStamp) {
        _scaffoldKey.currentState?.closeDrawer();
      });
    }
  }

  void _onDidReceiveNotificationResponse(
    NotificationResponse notificationResponse,
  ) async {
    if (!mounted || _isGuestViewActive) return;
    final String? payload = notificationResponse.payload;
    if (payload != null) {
      debugPrint('notification payload: $payload');
      final uri = Uri.tryParse(payload);
      if (uri != null && uri.host.toLowerCase() == "rewind") {
        await RewindEntry.openWhenReady(context);
        return;
      }
      if (payload.toLowerCase().contains("onthisday")) {
        // ignore: unawaited_futures
        memoriesCacheService.goToOnThisDayMemory();
      } else if (payload.toLowerCase().contains("birthday")) {
        final personID = payload.substring("birthday_".length);
        // ignore: unawaited_futures
        memoriesCacheService.goToPersonMemory(personID);
      }
    }
  }

  bool _shouldEnableDrawer() {
    final isFirstImportCompleted = LocalSyncService.instance
        .hasCompletedFirstImportOrBypassed();
    return isFirstImportCompleted;
  }

  bool _shouldShowPermissionWidget() {
    return !permissionService.hasGrantedPermissions() &&
        !backupPreferenceService.hasSkippedOnboardingPermission;
  }

  bool _shouldShowLoadingWidget() {
    if (isLocalGalleryMode) {
      return false;
    }
    if (!permissionService.hasGrantedPermissions()) {
      return false;
    }
    final isFirstImportCompletedOrBypassed = LocalSyncService.instance
        .hasCompletedFirstImportOrBypassed();
    return !isFirstImportCompletedOrBypassed;
  }

  void _ensurePersonSync() {
    if (_personSyncTriggered) {
      return;
    }
    if (isLocalGalleryMode) {
      return;
    }
    _personSyncTriggered = true;
    unawaited(_syncPersons());
  }

  Future<void> _syncPersons() async {
    try {
      await entityService.syncEntities();
      await PersonService.instance.sync();
      await PersonService.instance.refreshPersonCache();
    } catch (e, s) {
      _logger.warning("Failed to sync persons", e, s);
      _personSyncTriggered = false;
    }
  }
}

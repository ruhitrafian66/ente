import "dart:async";
import "dart:io";
import "dart:math";

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import "package:logging/logging.dart";
import 'package:photo_manager/photo_manager.dart';
import "package:photos/core/event_bus.dart";
import "package:photos/events/permission_granted_event.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/ml_service.dart";
import "package:photos/services/machine_learning/semantic_search/semantic_search_service.dart";
import 'package:photos/services/sync/sync_service.dart';
import "package:photos/theme/ente_theme.dart";
import "package:rive/rive.dart" as rive;

class GrantPermissionsWidget extends StatefulWidget {
  const GrantPermissionsWidget({super.key});

  @override
  State<GrantPermissionsWidget> createState() => _GrantPermissionsWidgetState();
}

class _GrantPermissionsWidgetState extends State<GrantPermissionsWidget>
    with WidgetsBindingObserver {
  final Logger _logger = Logger("_GrantPermissionsWidgetState");
  bool _isEnteringLocalGallery = false;
  late final rive.FileLoader _permissionsAnimationLoader;

  @override
  void initState() {
    super.initState();
    _permissionsAnimationLoader = rive.FileLoader.fromAsset(
      "assets/home_tab.riv",
      riveFactory: rive.Factory.flutter,
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(_enterLocalGalleryIfPermitted());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _permissionsAnimationLoader.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_enterLocalGalleryIfPermitted());
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildOfflinePermissionScreen(context);
  }

  Widget _buildPermissionsAnimation() {
    return rive.RiveWidgetBuilder(
      fileLoader: _permissionsAnimationLoader,
      builder: (BuildContext context, rive.RiveState state) {
        if (state is rive.RiveLoaded) {
          return rive.RiveWidget(
            controller: state.controller,
            fit: rive.Fit.contain,
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _onTapOfflineGrantPermission() async {
    try {
      final wasDecidedBefore =
          Platform.isIOS &&
          await permissionService.getPermissionState() !=
              PermissionState.notDetermined;
      await localSettings.setLocalGalleryOnboardingPending(true);
      final state = await permissionService.requestPhotoManagerPermissions();
      _logger.info("Offline permission state: $state");
      if (state.hasAccess) {
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          await _enterLocalGallery(state);
        }
      } else if (wasDecidedBefore ||
          permissionService.hasAttemptedPermission()) {
        await PhotoManager.openSetting();
      } else {
        await permissionService.setHasAttemptedPermission();
      }
    } catch (e) {
      _logger.severe("Failed to request permission: ${e.toString()}", e);
    }
  }

  Future<void> _enterLocalGalleryIfPermitted() async {
    // Offline fork: do not wait for the "onboarding pending" flag. Enter the
    // gallery as soon as the OS permission is present.
    try {
      final state = await permissionService.getPermissionState();
      if (state.hasAccess) {
        await _enterLocalGallery(state);
      }
    } catch (e) {
      _logger.severe("Failed to check permission: ${e.toString()}", e);
    }
  }

  Future<void> _enterLocalGallery(PermissionState state) async {
    if (!mounted || _isEnteringLocalGallery) {
      return;
    }
    _isEnteringLocalGallery = true;
    try {
      localSettings.localGalleryModeEnabledThisSession = true;
      try {
        await setMLConsent(true);
      } catch (e) {
        _logger.severe("Failed to record ML consent after permission grant", e);
      }
      await permissionService.onUpdatePermission(state);
      await localSettings.setLocalGalleryOnboardingPending(false);
    } catch (e) {
      _isEnteringLocalGallery = false;
      rethrow;
    }
    final Future<void> firstSync = SyncService.instance.onPermissionGranted();
    Bus.instance.fire(PermissionGrantedEvent());
    try {
      await MLService.instance.init();
      await SemanticSearchService.instance.init();
      unawaited(MLService.instance.runAllML(force: true));
      // Offline fork: the run above can start before the first local sync
      // has imported the device files, and then it finds no file to index.
      // No later event starts a new run in the foreground, so start one
      // when the first sync is complete.
      unawaited(() async {
        try {
          await firstSync;
          await MLService.instance.runAllML(force: true);
        } catch (e) {
          _logger.warning("ML run after the first sync failed", e);
        }
      }());
    } catch (e) {
      _logger.severe("Failed to initialize ML after permission grant", e);
    }
  }

  Widget _buildOfflinePermissionScreen(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          _buildSkeletonGallery(context),
          _buildOfflinePermissionHeader(context),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colorScheme.contentReverse.withValues(alpha: 0.4),
                    colorScheme.contentReverse,
                  ],
                  stops: const [0.0, 0.45],
                ),
              ),
            ),
          ),
          SafeArea(
            child: CustomScrollView(
              primary: false,
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 32),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.sizeOf(context).height * 0.2,
                          ),
                          child: _buildPermissionsAnimation(),
                        ),
                        const Flexible(child: SizedBox(height: 22)),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 297),
                          child: Text(
                            context.strings.bringMemoriesTogether,
                            textAlign: .center,
                            textScaler: .noScaling,
                            style: TextStyle(
                              fontWeight: .w900,
                              fontFamily: TextStyles.outfitFontFamily,
                              package: TextStyles.fontPackage,
                              fontSize: min(
                                MediaQuery.of(context).size.width * 0.125,
                                32,
                              ),
                              height: 1.08,
                              color: colorScheme.textBase,
                            ),
                          ),
                        ),
                        const Flexible(child: SizedBox(height: 24)),
                        Text(
                          context.strings.localGalleryPermissionDesc,
                          textAlign: TextAlign.center,
                          style: TextStyles.body.copyWith(
                            color: colorScheme.contentLight.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                        const Flexible(child: SizedBox(height: 32)),
                        ButtonComponent(
                          variant: ButtonComponentVariant.neutral,
                          density: ButtonComponentDensity.compact,
                          label: context.strings.continueLabel,
                          shouldShowSuccessState: false,
                          onTap: _onTapOfflineGrantPermission,
                        ),
                        const Flexible(child: SizedBox(height: 42)),
                        const Flexible(child: SizedBox(height: 24)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflinePermissionHeader(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              HugeIcon(
                icon: HugeIcons.strokeRoundedMenu01,
                size: 18,
                color: colorScheme.strokeBase,
              ),
              SvgPicture.asset(
                "assets/ente-branding.svg",
                height: 15,
                colorFilter: ColorFilter.mode(
                  colorScheme.content,
                  BlendMode.srcIn,
                ),
              ),
              HugeIcon(
                icon: HugeIcons.strokeRoundedUpload01,
                size: 18,
                color: colorScheme.strokeBase,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSkeletonGallery(BuildContext context) {
    const skeletonColor = Color.fromRGBO(217, 217, 217, 0.39);
    const memoryAspectRatio = 0.75;
    final topPadding = MediaQuery.of(context).padding.top;

    return Padding(
      padding: EdgeInsets.only(top: topPadding + 56, left: 8, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3 * memoryAspectRatio,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                childAspectRatio: memoryAspectRatio,
              ),
              itemCount: 3,
              itemBuilder: (context, index) {
                return Container(
                  decoration: BoxDecoration(
                    color: skeletonColor,
                    borderRadius: BorderRadius.circular(13),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: 71,
            height: 19,
            decoration: BoxDecoration(
              color: skeletonColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: 9,
              itemBuilder: (context, index) {
                return Container(
                  decoration: BoxDecoration(
                    color: skeletonColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

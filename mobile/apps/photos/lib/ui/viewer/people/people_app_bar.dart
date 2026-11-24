import 'dart:async';

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import "package:photos/events/people_changed_event.dart";
import 'package:photos/models/file/file.dart';
import 'package:photos/models/gallery_type.dart';
import "package:photos/models/ml/face/person.dart";
import 'package:photos/models/selected_files.dart';
import "package:photos/offline_fork.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_actions.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_config.dart";
import "package:photos/ui/viewer/gallery/gallery_app_bar_widget.dart";
import "package:photos/ui/viewer/gallery/hooks/pick_person_avatar.dart";
import "package:photos/ui/viewer/people/merge_persons_offline.dart";
import "package:photos/ui/viewer/people/person_cluster_suggestion.dart";
import "package:photos/ui/viewer/people/person_face_widget.dart";
import "package:photos/ui/viewer/people/reassign_me_selection_page.dart";
import "package:photos/ui/viewer/people/save_or_edit_person.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/person_contact_linking_util.dart";

const kShowUnnamedIgnoredPersonEventSource =
    "_AppBarWidgetState._showPersonUnnamedDelete";

class PeopleAppBar extends StatefulWidget {
  static GalleryAppBarConfig sliverConfig(
    GalleryType type,
    String? title,
    SelectedFiles selectedFiles,
    PersonEntity person, {
    required List<EnteFile> files,
    Key? coverAppBarKey,
    String? coverHeroTag,
    bool memoryLaneReady = false,
    Future<void> Function()? onMemoryLaneTap,
  }) {
    final config = GalleryAppBarWidget.sliverConfig(
      type,
      title,
      selectedFiles,
      coverWidget: files.isEmpty
          ? null
          : PersonFaceWidget(personId: person.remoteID),
    );
    return GalleryAppBarConfig(
      extendBodyForCollapse: config.extendBodyForCollapse,
      sliverBuilder: (_) => PeopleAppBar._(
        type,
        title,
        selectedFiles,
        person,
        files: files,
        coverAppBarKey: coverAppBarKey,
        coverHeroTag: coverHeroTag,
        memoryLaneReady: memoryLaneReady,
        onMemoryLaneTap: onMemoryLaneTap,
      ),
      geometryBuilder: config.geometryBuilder,
    );
  }

  final List<EnteFile> files;
  final Key? coverAppBarKey;
  final String? coverHeroTag;
  final GalleryType type;
  final String? title;
  final SelectedFiles selectedFiles;
  final PersonEntity person;
  final bool memoryLaneReady;
  final Future<void> Function()? onMemoryLaneTap;

  bool get isIgnored => person.data.isIgnored;

  const PeopleAppBar._(
    this.type,
    this.title,
    this.selectedFiles,
    this.person, {
    this.memoryLaneReady = false,
    this.onMemoryLaneTap,
    required this.files,
    this.coverAppBarKey,
    this.coverHeroTag,
  });

  @override
  State<PeopleAppBar> createState() => _AppBarWidgetState();
}

enum PeoplePopupAction {
  rename,
  setCover,
  pinPerson,
  hideFromMemories,
  ignore,
  removeLabel,
  reviewSuggestions,
  unignore,
  reassignMe,
  memoryLane,
  // Offline fork: merge this person into another named person.
  mergeWithPerson,
}

class _AppBarWidgetState extends State<PeopleAppBar> {
  final _logger = Logger("_AppBarWidgetState");
  late Function() _selectedFilesListener;
  String? _appBarTitle;
  bool isQuickLink = false;
  late GalleryType galleryType;
  late PersonEntity person;
  late StreamSubscription<PeopleChangedEvent> _peopleChangedEventSubscription;

  String? _resolveAppBarTitle({
    required PersonEntity sourcePerson,
    required String? title,
  }) {
    // Offline fork: there is no account, so no person is "me".
    if (!kOfflineFork &&
        isCurrentUserContactLink(
          email: sourcePerson.data.email,
          userID: sourcePerson.data.userID,
        )) {
      if (title == null) {
        return context.strings.me;
      }
      return context.strings.accountOwnerPersonAppbarTitle(title: title);
    }
    return title;
  }

  @override
  void initState() {
    super.initState();
    person = widget.person;
    galleryType = widget.type;
    _selectedFilesListener = () {
      setState(() {});
    };

    widget.selectedFiles.addListener(_selectedFilesListener);

    _peopleChangedEventSubscription = Bus.instance
        .on<PeopleChangedEvent>()
        .listen((event) {
          if (event.person != null &&
              event.type == PeopleEventType.saveOrEditPerson &&
              widget.person.remoteID == event.person!.remoteID &&
              event.source == "reassignMe") {
            person = event.person!;
            setState(() {
              _appBarTitle = _resolveAppBarTitle(
                sourcePerson: person,
                title: person.data.name,
              );
            });
          }
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appBarTitle = _resolveAppBarTitle(
      sourcePerson: person,
      title: widget.title,
    );
  }

  @override
  void didUpdateWidget(covariant PeopleAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.person.remoteID != widget.person.remoteID ||
        oldWidget.person.data.name != widget.person.data.name ||
        oldWidget.person.data.email != widget.person.data.email ||
        oldWidget.person.data.userID != widget.person.data.userID) {
      person = widget.person;
      _appBarTitle = _resolveAppBarTitle(
        sourcePerson: person,
        title: widget.title,
      );
    }
  }

  @override
  void dispose() {
    widget.selectedFiles.removeListener(_selectedFilesListener);
    _peopleChangedEventSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GalleryAppBarWidget.sliverConfig(
      widget.type,
      _appBarTitle,
      widget.selectedFiles,
      files: widget.files,
      coverAppBarKey: widget.coverAppBarKey,
      coverWidget: widget.files.isEmpty
          ? null
          : PersonFaceWidget(
              personId: person.remoteID,
              cachedPixelWidth:
                  (MediaQuery.sizeOf(context).width *
                          MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
            ),
      coverHeroTag: widget.coverHeroTag,
      actionsBuilder: ({required onCover, foregroundColor}) =>
          _getDefaultActions(
            context,
            onCover: onCover,
            foregroundColor: foregroundColor,
          ),
    ).buildSliver(context);
  }

  Future<dynamic> _editPerson(BuildContext context) async {
    final clusterID = person.data.assigned.isEmpty
        ? null
        : person.data.assigned.first.id;
    final result = await routeToPage(
      context,
      SaveOrEditPerson(clusterID, person: person, isEditing: true),
    );
    if (!mounted) return;
    if (result is PersonEntity) {
      _appBarTitle = result.data.name;
      person = result;
      setState(() {});
    }
  }

  List<Widget> _getDefaultActions(
    BuildContext context, {
    required bool onCover,
    Color? foregroundColor,
  }) {
    final bool isIgnored = person.data.isIgnored;
    final bool isPinned = person.data.isPinned;
    final bool hideFromMemories = person.data.hideFromMemories;
    final bool hasAssignedCluster = person.data.assigned.isNotEmpty;
    final List<Widget> actions = <Widget>[];
    // Offline fork: person actions work without an account.
    if (widget.selectedFiles.files.isNotEmpty ||
        (!kOfflineFork && !Configuration.instance.hasConfiguredAccount())) {
      return actions;
    }

    final List<EntePopupMenuOption<PeoplePopupAction>> items = [];
    final bool showTimelineAction =
        widget.memoryLaneReady && widget.onMemoryLaneTap != null;
    if (showTimelineAction) {
      items.add(
        EntePopupMenuOption(
          value: PeoplePopupAction.memoryLane,
          label: context.strings.facesTimelineAppBarTitle,
          leadingWidget: const HugeIcon(
            icon: HugeIcons.strokeRoundedSparkles,
            size: IconSizes.small,
          ),
        ),
      );
    }

    if (!isIgnored) {
      items.addAll([
        EntePopupMenuOption(
          value: PeoplePopupAction.rename,
          label: context.strings.edit,
          leadingWidget: const HugeIcon(
            icon: HugeIcons.strokeRoundedPencilEdit01,
            size: IconSizes.small,
          ),
        ),
        if (hasAssignedCluster)
          EntePopupMenuOption(
            value: PeoplePopupAction.reviewSuggestions,
            label: context.strings.review,
            leadingWidget: const HugeIcon(
              icon: HugeIcons.strokeRoundedSearch01,
              size: IconSizes.small,
            ),
          ),
        if (hasAssignedCluster)
          EntePopupMenuOption(
            value: PeoplePopupAction.setCover,
            label: context.strings.setCover,
            leadingWidget: const HugeIcon(
              icon: HugeIcons.strokeRoundedImage01,
              size: IconSizes.small,
            ),
          ),
        EntePopupMenuOption(
          value: PeoplePopupAction.pinPerson,
          label: isPinned
              ? context.strings.unpinPerson
              : context.strings.pinPerson,
          leadingWidget: HugeIcon(
            icon: isPinned
                ? HugeIcons.strokeRoundedPinOff
                : HugeIcons.strokeRoundedPin,
            size: IconSizes.small,
          ),
        ),
        EntePopupMenuOption(
          value: PeoplePopupAction.hideFromMemories,
          label: hideFromMemories
              ? context.strings.showInMemories
              : context.strings.hideFromMemories,
          leadingWidget: HugeIcon(
            icon: hideFromMemories
                ? HugeIcons.strokeRoundedView
                : HugeIcons.strokeRoundedViewOffSlash,
            size: IconSizes.small,
          ),
        ),
        // Offline fork: person-to-person merge. Not localized.
        if (kOfflineFork && person.data.name.trim().isNotEmpty)
          const EntePopupMenuOption(
            value: PeoplePopupAction.mergeWithPerson,
            label: "Merge with another person",
            leadingWidget: HugeIcon(
              icon: HugeIcons.strokeRoundedGitMerge,
              size: IconSizes.small,
            ),
          ),
        // Offline fork: "me" needs an account, so reassign never shows.
        if (!kOfflineFork &&
            isCurrentUserContactLink(
              email: person.data.email,
              userID: person.data.userID,
            ))
          EntePopupMenuOption(
            value: PeoplePopupAction.reassignMe,
            label: context.strings.reassignMe,
            leadingWidget: const HugeIcon(
              icon: HugeIcons.strokeRoundedUser,
              size: IconSizes.small,
            ),
          ),
        EntePopupMenuOption(
          value: PeoplePopupAction.ignore,
          label: context.strings.ignore,
          leadingWidget: const HugeIcon(
            icon: HugeIcons.strokeRoundedUserBlock01,
            size: IconSizes.small,
          ),
        ),
        EntePopupMenuOption(
          value: PeoplePopupAction.removeLabel,
          label: context.strings.remove,
          leadingWidget: const HugeIcon(
            icon: HugeIcons.strokeRoundedDelete01,
            size: IconSizes.small,
          ),
        ),
      ]);
    } else {
      items.addAll([
        EntePopupMenuOption(
          value: PeoplePopupAction.rename,
          label: context.strings.edit,
          leadingWidget: const HugeIcon(
            icon: HugeIcons.strokeRoundedPencilEdit01,
            size: IconSizes.small,
          ),
        ),
        if (hasAssignedCluster)
          EntePopupMenuOption(
            value: PeoplePopupAction.reviewSuggestions,
            label: context.strings.review,
            leadingWidget: const HugeIcon(
              icon: HugeIcons.strokeRoundedSearch01,
              size: IconSizes.small,
            ),
          ),
        EntePopupMenuOption(
          value: PeoplePopupAction.unignore,
          label: context.strings.showPerson,
          leadingWidget: const HugeIcon(
            icon: HugeIcons.strokeRoundedView,
            size: IconSizes.small,
          ),
        ),
      ]);
    }

    final overflowMenuAction = onCover
        ? galleryAppBarActionsSheetAction
        : galleryAppBarPopupMenuAction;
    actions.add(
      overflowMenuAction<PeoplePopupAction>(
        tooltip: context.strings.more,
        icon: HugeIcon(
          icon: HugeIcons.strokeRoundedMoreVertical,
          color: foregroundColor,
        ),
        optionsBuilder: () => items,
        onSelected: (PeoplePopupAction value) async {
          if (value == PeoplePopupAction.reviewSuggestions) {
            unawaited(
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => PersonReviewClusterSuggestion(person),
                ),
              ),
            );
          } else if (value == PeoplePopupAction.memoryLane) {
            final callback = widget.onMemoryLaneTap;
            if (callback != null) {
              unawaited(callback());
            }
          } else if (value == PeoplePopupAction.rename) {
            await _editPerson(context);
          } else if (value == PeoplePopupAction.setCover) {
            await setCoverPhoto(context);
          } else if (value == PeoplePopupAction.pinPerson) {
            await _togglePinState();
          } else if (value == PeoplePopupAction.hideFromMemories) {
            await _toggleHideFromMemories();
          } else if (value == PeoplePopupAction.ignore) {
            await _ignorePerson(context);
          } else if (value == PeoplePopupAction.unignore) {
            await _showPerson(context);
          } else if (value == PeoplePopupAction.removeLabel) {
            await _resetPerson(context);
          } else if (value == PeoplePopupAction.reassignMe) {
            await _reassignMe(context);
          } else if (value == PeoplePopupAction.mergeWithPerson) {
            await _mergeWithAnotherPerson(context);
          }
        },
      ),
    );

    return actions;
  }

  // Offline fork: merges this person into a person that the user picks,
  // then closes this page because this person no longer exists.
  Future<void> _mergeWithAnotherPerson(BuildContext context) async {
    final target = await mergePersonIntoPickedPerson(context, person);
    if (target == null || !context.mounted) return;
    showShortToast(context, "Merged into ${target.data.name}");
    Navigator.of(context).pop();
  }

  Future<void> _togglePinState() async {
    final shouldPin = !person.data.isPinned;
    try {
      final updatedPerson = await PersonService.instance.updateAttributes(
        person.remoteID,
        isPinned: shouldPin,
      );
      setState(() {
        person = updatedPerson;
      });
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.saveOrEditPerson,
          source: "_AppBarWidgetState._togglePinState",
          person: updatedPerson,
        ),
      );
    } catch (e, s) {
      _logger.severe('Failed to update pin state', e, s);
    }
  }

  Future<void> _toggleHideFromMemories() async {
    final shouldHideFromMemories = !person.data.hideFromMemories;
    try {
      final updatedPerson = await PersonService.instance.updateAttributes(
        person.remoteID,
        hideFromMemories: shouldHideFromMemories,
      );
      if (mounted) {
        setState(() {
          person = updatedPerson;
        });
      }
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.saveOrEditPerson,
          source: "_AppBarWidgetState._toggleHideFromMemories",
          person: updatedPerson,
        ),
      );
    } catch (e, s) {
      _logger.severe('Failed to update hide from memories state', e, s);
    }
  }

  Future<void> _resetPerson(BuildContext context) async {
    await showChoiceDialog(
      context,
      title: context.strings.areYouSureYouWantToResetThisPerson,
      body: context.strings.allPersonGroupingWillReset,
      firstButtonLabel: context.strings.yesResetPerson,
      firstButtonOnTap: () async {
        try {
          await PersonService.instance.deletePerson(person.remoteID);
          if (!context.mounted) return;
          Navigator.of(context).pop();
        } catch (e, s) {
          _logger.severe('Resetting person failed', e, s);
        }
      },
    );
  }

  bool _isLegacyIgnoredName(String name) {
    final normalizedName = name.trim().toLowerCase();
    return normalizedName.isEmpty ||
        normalizedName == "(ignored)" ||
        normalizedName == "(hidden)";
  }

  Future<void> _ignorePerson(BuildContext context) async {
    final result = await showChoiceDialog(
      context,
      title: context.strings.areYouSureYouWantToIgnoreThisPerson,
      body: context.strings.thePersonWillNotBeDisplayed,
      firstButtonLabel: context.strings.yesIgnore,
      firstButtonOnTap: () async {
        try {
          final updatedPerson = await PersonService.instance.updateAttributes(
            person.remoteID,
            isHidden: true,
          );
          setState(() {
            person = updatedPerson;
          });
          Bus.instance.fire(
            PeopleChangedEvent(
              type: PeopleEventType.saveOrEditPerson,
              source: "_AppBarWidgetState._ignorePerson",
              person: updatedPerson,
            ),
          );
        } catch (e, s) {
          _logger.severe('Ignoring/showing person failed', e, s);
          rethrow;
        }
      },
    );
    if (!mounted || result?.action != ButtonAction.error) {
      return;
    }
    if (!context.mounted) return;
    showShortToast(context, context.strings.somethingWentWrongPleaseTryAgain);
  }

  Future<void> _showPerson(BuildContext context) async {
    final isUnnamedIgnoredPerson = _isLegacyIgnoredName(person.data.name);
    var shouldCloseDetailPage = false;
    final result = await showChoiceDialog(
      context,
      title:
          context.strings.areYouSureYouWantToShowThisPersonInPeopleSectionAgain,
      firstButtonLabel: context.strings.yesShowPerson,
      isDismissible: false,
      firstButtonOnTap: () async {
        try {
          if (isUnnamedIgnoredPerson) {
            await PersonService.instance.deletePerson(person.remoteID);
            Bus.instance.fire(
              PeopleChangedEvent(
                source: kShowUnnamedIgnoredPersonEventSource,
                person: person,
              ),
            );
            shouldCloseDetailPage = true;
          } else {
            final updatedPerson = await PersonService.instance.updateAttributes(
              person.remoteID,
              isHidden: false,
            );
            setState(() {
              person = updatedPerson;
              _appBarTitle = _resolveAppBarTitle(
                sourcePerson: person,
                title: person.data.name,
              );
            });
            Bus.instance.fire(
              PeopleChangedEvent(
                type: PeopleEventType.saveOrEditPerson,
                source: "_AppBarWidgetState._showPerson",
                person: updatedPerson,
              ),
            );
          }
        } catch (e, s) {
          _logger.severe('Unignoring/showing person failed', e, s);
        }
      },
    );
    if (!mounted ||
        result?.action != ButtonAction.first ||
        !shouldCloseDetailPage) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).maybePop();
  }

  Future<void> setCoverPhoto(BuildContext context) async {
    final result = await showPersonAvatarPhotoSheet(context, person);
    if (result != null) {
      _logger.info('Person avatar updated');
      Bus.instance.fire(
        PeopleChangedEvent(
          type: PeopleEventType.saveOrEditPerson,
          source: "_PeopleAppBarState.setCoverPhoto",
          person: result,
        ),
      );
      if (!mounted) return;
      setState(() {
        person = result;
      });
    }
  }

  Future<void> _reassignMe(BuildContext context) async {
    await routeToPage(
      context,
      ReassignMeSelectionPage(currentMeId: widget.person.remoteID),
    );
  }
}

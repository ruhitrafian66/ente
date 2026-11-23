// Offline fork: UI helpers to merge two or more NAMED persons.
//
// Upstream can only add an unnamed cluster to a person. The fork adds a
// person-to-person merge (`PersonService.mergePersons`). The strings in this
// file are not localized.

import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/models/search/search_constants.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/viewer/people/face_thumbnail_squircle.dart";
import "package:photos/ui/viewer/people/merge_clusters_to_person_sheet.dart";
import "package:photos/ui/viewer/people/person_face_widget.dart";
import "package:photos/utils/dialog_util.dart";

final _logger = Logger("MergePersonsOffline");

/// Asks which of [persons] to keep. Returns null if the user closes the sheet.
Future<PersonEntity?> showKeepPersonSheet(
  BuildContext context,
  List<PersonEntity> persons,
) {
  return showBottomSheetComponent<PersonEntity>(
    context: context,
    builder: (context) => _KeepPersonSheet(persons: persons),
  );
}

/// Asks the user to confirm a merge into [targetName]. A merge cannot be
/// undone, so each person merge must call this first.
Future<bool> confirmMergeIntoPerson(
  BuildContext context, {
  required String targetName,
  String? sourceName,
}) async {
  final result = await showChoiceDialog(
    context,
    title: context.strings.mergeWithPersonTitle(name: targetName),
    // Offline fork: not localized
    body: sourceName != null
        ? "All photos of $sourceName move to $targetName, and $sourceName is removed. You cannot undo this."
        : "All photos of the other selected people and groups move to $targetName. The other people are removed. You cannot undo this.",
    firstButtonLabel: context.strings.merge,
  );
  return result?.action == ButtonAction.first;
}

/// Opens a person picker, then merges [source] into the picked person.
///
/// Returns the updated target person, or null if the user cancelled or the
/// merge failed.
Future<PersonEntity?> mergePersonIntoPickedPerson(
  BuildContext context,
  PersonEntity source,
) async {
  final candidates = (await loadMergeablePersons())
      .where((result) => result.params[kPersonParamID] != source.remoteID)
      .toList();
  if (!context.mounted) return null;
  if (candidates.isEmpty) {
    await showErrorDialog(
      context,
      // Offline fork: not localized
      "No other person",
      "Name a second person before you merge.",
    );
    return null;
  }
  final selection = await showMergeClustersToPersonPage(
    context,
    initialPersons: candidates,
  );
  if (selection == null || selection.personId.isEmpty) return null;
  if (selection.personId == source.remoteID) return null;
  final target =
      selection.person ??
      await PersonService.instance.getPerson(selection.personId);
  if (target == null || !context.mounted) return null;

  final confirmed = await confirmMergeIntoPerson(
    context,
    targetName: target.data.name,
    sourceName: source.data.name,
  );
  if (!confirmed) return null;
  try {
    return await PersonService.instance.mergePersons(
      sourceID: source.remoteID,
      targetID: target.remoteID,
    );
  } catch (e, s) {
    _logger.severe("Failed to merge persons", e, s);
    if (context.mounted) {
      await showGenericErrorDialog(context: context, error: e);
    }
    return null;
  }
}

class _KeepPersonSheet extends StatelessWidget {
  const _KeepPersonSheet({required this.persons});

  final List<PersonEntity> persons;

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return BottomSheetComponent(
      // Offline fork: not localized
      title: "Keep which person?",
      isScrollable: true,
      shrinkWrap: true,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            // Offline fork: not localized
            "The other selected people and groups are merged into the person you select.",
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
          const SizedBox(height: Spacing.md),
          for (final person in persons)
            _KeepPersonTile(
              key: ValueKey(person.remoteID),
              person: person,
              onTap: () => Navigator.of(context).pop(person),
            ),
        ],
      ),
    );
  }
}

class _KeepPersonTile extends StatelessWidget {
  const _KeepPersonTile({super.key, required this.person, required this.onTap});

  final PersonEntity person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const avatarSize = 44.0;
    final colors = context.componentColors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
          child: Row(
            children: [
              SizedBox(
                width: avatarSize,
                height: avatarSize,
                child: FaceThumbnailSquircleClip(
                  child: PersonFaceWidget(
                    personId: person.remoteID,
                    useFullFile: false,
                    cachedPixelWidth:
                        (avatarSize * MediaQuery.devicePixelRatioOf(context))
                            .round(),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  person.data.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.body.copyWith(color: colors.textBase),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

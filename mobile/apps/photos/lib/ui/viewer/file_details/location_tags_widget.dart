import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:ente_ui/components/loading_widget.dart";
import "package:flutter/material.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/location_tag_updated_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/service_locator.dart";
import "package:photos/states/location_screen_state.dart";
import 'package:photos/ui/viewer/location/add_location_sheet.dart';
import "package:photos/ui/viewer/location/location_screen.dart";

class LocationTagsWidget extends StatefulWidget {
  final EnteFile file;

  const LocationTagsWidget(this.file, {super.key});

  @override
  State<LocationTagsWidget> createState() => _LocationTagsWidgetState();
}

class _LocationTagsWidgetState extends State<LocationTagsWidget> {
  String? title;
  late Future<List<Widget>> locationTagChips;
  late StreamSubscription<LocationTagUpdatedEvent> _locTagUpdateListener;

  @override
  void initState() {
    locationTagChips = _getLocationTags();
    _locTagUpdateListener = Bus.instance.on<LocationTagUpdatedEvent>().listen((
      event,
    ) {
      locationTagChips = _getLocationTags();
    });

    super.initState();
  }

  @override
  void dispose() {
    _locTagUpdateListener.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title ?? context.strings.location, style: TextStyles.h2),
        const SizedBox(height: Spacing.lg),
        FutureBuilder<List<Widget>>(
          future: locationTagChips,
          builder: (context, snapshot) {
            final Widget child;
            if (snapshot.hasData) {
              child = Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: snapshot.data!,
              );
            } else {
              child = EnteLoadingWidget(
                padding: 3,
                size: 11,
                color: colors.strokeFaint,
                alignment: Alignment.centerLeft,
              );
            }
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeInOutExpo,
              child: child,
            );
          },
        ),
      ],
    );
  }

  Future<List<Widget>> _getLocationTags() async {
    final locationTags = await locationService.enclosingLocationTags(
      widget.file.location!,
    );
    if (!mounted) return const [];
    setState(() {
      title = context.strings.location;
    });
    if (locationTags.isEmpty) {
      return [
        FilterChipComponent(
          label: context.strings.addLocation,
          onChanged: (_) =>
              showAddLocationSheet(context, widget.file.location!),
        ),
      ];
    } else {
      final result = locationTags
          .map<Widget>(
            (locationTagEntity) => FilterChipComponent(
              label: locationTagEntity.item.name,
              onChanged: (_) {
                routeToPage(
                  context,
                  LocationScreenStateProvider(
                    locationTagEntity,
                    const LocationScreen(),
                  ),
                );
              },
            ),
          )
          .toList();
      result.add(
        IconButtonComponent(
          tooltip: context.strings.addLocation,
          size: FilterChipComponent.minHeight,
          icon: const HugeIcon(
            icon: HugeIcons.strokeRoundedPlusSign,
            size: IconSizes.small,
          ),
          variant: IconButtonComponentVariant.circular,
          shouldSurfaceExecutionStates: false,
          onTap: () => showAddLocationSheet(context, widget.file.location!),
        ),
      );
      return result;
    }
  }
}

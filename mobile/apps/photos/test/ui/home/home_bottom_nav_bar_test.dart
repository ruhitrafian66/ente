import "package:ente_components/theme/theme.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/tab_changed_event.dart";
import "package:photos/models/selected_files.dart";
import "package:photos/ui/home/home_bottom_nav_bar.dart";
import "package:photos/ui/tabs/nav_bar.dart";

void main() {
  testWidgets("Local Gallery tabs preserve Search navigation", (tester) async {
    final selectedFiles = SelectedFiles();
    addTearDown(selectedFiles.dispose);

    final tabEvents = <TabChangedEvent>[];
    final doubleTapEvents = <TabDoubleTapEvent>[];
    final tabsSubscription = Bus.instance.on<TabChangedEvent>().listen(
      tabEvents.add,
    );
    final doubleTapSubscription = Bus.instance.on<TabDoubleTapEvent>().listen(
      doubleTapEvents.add,
    );
    addTearDown(tabsSubscription.cancel);
    addTearDown(doubleTapSubscription.cancel);

    await tester.pumpWidget(
      MaterialApp(
        theme: ComponentTheme.lightTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: HomeBottomNavigationBar(selectedFiles, selectedTabIndex: 0),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel("Home"), findsOneWidget);
    expect(find.bySemanticsLabel("Albums"), findsOneWidget);
    expect(find.bySemanticsLabel("Feed"), findsNothing);
    final search = find.bySemanticsLabel("Search");
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(tabEvents.single.selectedIndex, 3);

    Bus.instance.fire(TabChangedEvent(3, TabChangedEventSource.pageView));
    await tester.pumpAndSettle();
    final searchButton = tester.widget<GButton>(
      find.ancestor(of: search, matching: find.byType(GButton)),
    );
    expect(searchButton.active, isTrue);

    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(doubleTapEvents.single.selectedIndex, 3);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

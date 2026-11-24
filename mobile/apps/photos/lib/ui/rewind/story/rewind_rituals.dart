import "package:flutter/foundation.dart";

// Offline fork: rituals are removed. This class only holds the numbers that
// the ritual streak page shows (the debug gallery uses a sample).
@immutable
class RewindRituals {
  const RewindRituals({
    required this.longestStreak,
    required this.checkIns,
    required this.busiestMonth,
    required this.continued,
    required this.icons,
  });

  final int longestStreak;
  final int checkIns;
  final int busiestMonth;
  final int continued;
  final List<String> icons;

  @override
  bool operator ==(Object other) =>
      other is RewindRituals &&
      other.longestStreak == longestStreak &&
      other.checkIns == checkIns &&
      other.busiestMonth == busiestMonth &&
      other.continued == continued &&
      listEquals(other.icons, icons);

  @override
  int get hashCode => Object.hash(
    longestStreak,
    checkIns,
    busiestMonth,
    continued,
    Object.hashAll(icons),
  );
}

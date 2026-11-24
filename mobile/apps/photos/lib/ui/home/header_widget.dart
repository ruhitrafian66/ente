import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import "package:photos/ui/home/memories/memories_strip.dart";
import 'package:photos/ui/home/status_bar_widget.dart';

class HeaderWidget extends StatelessWidget {
  const HeaderWidget({super.key});

  static final Logger _logger = Logger("Header");

  @override
  Widget build(BuildContext context) {
    _logger.info("Building header widget");
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [StatusBarWidget(), MemoriesStripWidget()],
    );
  }
}

import 'package:flutter/material.dart';

import 'theme.dart';

class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.child,
    this.horizontalPadding = 24,
  });

  final Widget child;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          20,
          horizontalPadding,
          14,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Expanded(child: child)],
        ),
      ),
    );
  }
}

class SettingPanel extends StatelessWidget {
  const SettingPanel({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: tileDecoration(context),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

BoxDecoration tileDecoration(BuildContext context, {bool song = false}) {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(
      width: song ? 0.8 : 1,
      color: song
          ? MediaQuery.highContrastOf(context)
                ? themeAccent(context)
                : Color.alphaBlend(
                    themeAccent(context).withValues(alpha: 0.45),
                    Colors.white,
                  )
          : MediaQuery.highContrastOf(context)
          ? Theme.of(context).colorScheme.outline
          : Theme.of(context).colorScheme.outlineVariant,
    ),
  );
}

class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}

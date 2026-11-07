import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';

class ThemePalette {
  const ThemePalette(
    this.id,
    this.name,
    this.primary,
    this.background,
    this.tint,
  );

  final String id;
  final String name;
  final Color primary;
  final Color background;
  final Color tint;
}

const themePalettes = [
  ThemePalette(
    'lightGreen',
    '青竹',
    Color(0xFF287858),
    Color(0xFFF0F6F1),
    Color(0xFFDDEEE2),
  ),
  ThemePalette(
    'skyBlue',
    '晴空',
    Color(0xFF2466A8),
    Color(0xFFF0F5FB),
    Color(0xFFDDEBFA),
  ),
  ThemePalette(
    'lavender',
    '暮紫',
    Color(0xFF7251A2),
    Color(0xFFF5F2F9),
    Color(0xFFECE2F7),
  ),
  ThemePalette(
    'rose',
    '樱粉',
    Color(0xFFA13F66),
    Color(0xFFFCF2F5),
    Color(0xFFF7DFE8),
  ),
  ThemePalette(
    'apricot',
    '暖杏',
    Color(0xFF97521F),
    Color(0xFFFBF5ED),
    Color(0xFFF5E5D2),
  ),
  ThemePalette(
    'graphite',
    '石墨',
    Color(0xFF4F5B68),
    Color(0xFFF2F4F6),
    Color(0xFFE0E5EB),
  ),
];

final _themeCache = <String, ThemeData>{};

/// Every theme uses solid surfaces; changing a theme only changes colors.
ThemeData qingTingTheme({String theme = 'lightGreen'}) {
  final id = normalizeAppTheme(theme);
  return _themeCache.putIfAbsent(id, () {
    final palette = themePalettes.firstWhere((value) => value.id == id);
    final font = Platform.isLinux ? 'Noto Sans CJK SC' : 'Microsoft YaHei';
    final scheme =
        ColorScheme.fromSeed(
          seedColor: palette.primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: palette.primary,
          onPrimary: Colors.white,
          primaryContainer: palette.tint,
          onPrimaryContainer: palette.primary,
          secondary: palette.primary,
          secondaryContainer: palette.tint,
          onSecondaryContainer: palette.primary,
          surface: Colors.white,
          onSurface: appInk,
          onSurfaceVariant: appMuted,
          outline: palette.primary,
          outlineVariant: palette.tint,
        );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      dividerColor: palette.tint,
      fontFamily: font,
      textTheme: ThemeData.light().textTheme.apply(
        fontFamily: font,
        bodyColor: appInk,
        displayColor: appInk,
      ),
      appBarTheme: const AppBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        foregroundColor: appInk,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: Colors.white,
          shape: shape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.primary,
          backgroundColor: Colors.white,
          side: BorderSide(color: palette.tint),
          shape: shape,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        hintStyle: const TextStyle(color: appMuted, fontSize: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: palette.tint),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: palette.primary, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: palette.tint,
        side: BorderSide(color: palette.tint),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        labelStyle: const TextStyle(color: appInk, fontWeight: FontWeight.w600),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
    );
  });
}

Color themeLine(BuildContext context) => MediaQuery.highContrastOf(context)
    ? Theme.of(context).colorScheme.outline
    : Theme.of(context).colorScheme.outlineVariant;

Color themeAccent(BuildContext context) =>
    Theme.of(context).colorScheme.primary;
Color themeTint(BuildContext context) =>
    Theme.of(context).colorScheme.primaryContainer;

class AppThemeScope extends StatelessWidget {
  const AppThemeScope({super.key, required this.theme, required this.child});

  final ValueListenable<String> theme;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: theme,
    child: child,
    builder: (context, id, child) {
      final theme = qingTingTheme(theme: id);
      return Theme(
        data: theme,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemUiOverlayStyle.copyWith(
            statusBarColor: theme.scaffoldBackgroundColor,
            systemNavigationBarColor: theme.scaffoldBackgroundColor,
          ),
          child: child!,
        ),
      );
    },
  );
}

class ThemeSurface extends StatelessWidget {
  const ThemeSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 22,
    this.isolateContent = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool isolateContent;

  @override
  Widget build(BuildContext context) {
    final pane = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: MediaQuery.highContrastOf(context)
              ? Theme.of(context).colorScheme.outline
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: padding,
        child: isolateContent ? RepaintBoundary(child: child) : child,
      ),
    );
    if (!isolateContent) return pane;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: pane,
      ),
    );
  }
}

class NavigationButton extends StatelessWidget {
  const NavigationButton({
    super.key,
    required this.child,
    required this.onTap,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: child,
      ),
    ),
  );
}

const appInk = Color(0xFF1F2A24);

const appMuted = Color(0xFF6B756F);

const systemUiOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.white,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.white,
  systemNavigationBarIconBrightness: Brightness.dark,
);

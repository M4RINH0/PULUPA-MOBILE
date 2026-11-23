import 'package:material_ui/material_ui.dart';

abstract final class PulupaColors {
  static const blue = Color(0xFF345CFF);
  static const yellow = Color(0xFFFFD928);
  static const pink = Color(0xFFFF55A5);
  static const red = Color(0xFFF04452);
  static const purple = Color(0xFF8B5CF6);
  static const navy = Color(0xFF17213A);
  static const paper = Color(0xFFF7F6F0);
  static const line = Color(0xFFE2E3EB);
  static const muted = Color(0xFF526079);
}

ThemeData pulupaTheme() {
  const radius = BorderRadius.all(Radius.circular(18));
  const touchPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 15);
  final base = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: PulupaColors.blue).copyWith(
      primary: PulupaColors.blue,
      onPrimary: Colors.white,
      secondary: PulupaColors.purple,
      onSurface: PulupaColors.navy,
      surface: PulupaColors.paper,
      error: const Color(0xFFB71B37),
    ),
    scaffoldBackgroundColor: PulupaColors.paper,
    appBarTheme: const AppBarTheme(
      backgroundColor: PulupaColors.paper,
      foregroundColor: PulupaColors.navy,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: PulupaColors.navy,
        fontWeight: FontWeight.w900,
        fontSize: 22,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 54),
        padding: touchPadding,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: touchPadding,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: PulupaColors.yellow,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineMedium: const TextStyle(
        color: PulupaColors.navy,
        fontSize: 32,
        height: 1.1,
        fontWeight: FontWeight.w900,
        letterSpacing: -1,
      ),
      titleMedium: const TextStyle(
        color: PulupaColors.navy,
        fontSize: 17,
        fontWeight: FontWeight.w800,
      ),
      bodyMedium: const TextStyle(
        color: PulupaColors.muted,
        fontSize: 15,
        height: 1.4,
      ),
    ),
  );
}

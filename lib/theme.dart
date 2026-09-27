import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// =========================================================================
/// AppTheme
/// -------------------------------------------------------------------------
/// A single source of truth for the app's visual language.
///
/// Design principles:
/// 1. High-contrast, WCAG AA-compliant text at every surface.
/// 2. Two seeded palettes (light / dark) that stay visually related.
/// 3. One accent colour drives every interactive surface.
/// 4. Rounded, tactile geometry — friendly but not childish.
/// 5. Consistent spacing scale (4 / 8 / 12 / 16 / 24 / 32).
/// =========================================================================
abstract final class AppTheme {
  // --- Brand seed colours ---
  // A confident, globally-neutral teal. Reads well on both light and dark
  // surfaces and doesn't carry cultural baggage across regions.
  static const Color _seed = Color(0xFF00A67E);

  // Semantic accents (used sparingly for status only).
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFDC2626);
  static const Color info = Color(0xFF2563EB);

  // --- Spacing scale (use these instead of raw numbers) ---
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;
  static const double space2xl = 32;

  // --- Radii ---
  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 24;
  static const double radiusPill = 999;

  // --- Elevation / shadow ---
  static const List<BoxShadow> softShadow = [
    BoxShadow(color: Color(0x14000000), blurRadius: 20, offset: Offset(0, 8)),
  ];

  // =======================================================================
  // LIGHT THEME
  // =======================================================================
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    );

    return _buildTheme(scheme: scheme, isDark: false);
  }

  // =======================================================================
  // DARK THEME
  // =======================================================================
  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );

    return _buildTheme(scheme: scheme, isDark: true);
  }

  // =======================================================================
  // Shared builder — guarantees light/dark parity.
  // =======================================================================
  static ThemeData _buildTheme({
    required ColorScheme scheme,
    required bool isDark,
  }) {
    final base = isDark ? ThemeData.dark() : ThemeData.light();
    final textTheme = _buildTextTheme(base.textTheme, scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      textTheme: textTheme,

      // --- Scaffold ---
      scaffoldBackgroundColor: scheme.surface,

      // --- AppBar ---
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),

      // --- Bottom Navigation Bar ---
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        selectedLabelStyle: textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: textTheme.labelSmall,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        showUnselectedLabels: true,
      ),

      // --- Navigation Bar (M3) ---
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        elevation: 3,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
      ),

      // --- Buttons ---
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: spaceXl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          elevation: 0,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // --- Inputs ---
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spaceLg,
          vertical: spaceLg,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),

      // --- Cards ---
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
      ),

      // --- Chips ---
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.14),
        side: BorderSide.none,
        labelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(
          horizontal: spaceMd,
          vertical: spaceSm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusPill),
        ),
      ),

      // --- Bottom sheet (the heart of this app's UX) ---
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        modalBarrierColor: Colors.black.withValues(alpha: 0.45),
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLg)),
        ),
        clipBehavior: Clip.antiAlias,
        showDragHandle: true,
        dragHandleColor: scheme.outlineVariant,
        constraints: const BoxConstraints(maxWidth: 640),
      ),

      // --- Dialog ---
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),

      // --- Snackbar ---
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? scheme.surfaceContainerHighest
            : scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: isDark ? scheme.onSurface : scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        elevation: 3,
        insetPadding: const EdgeInsets.all(spaceLg),
      ),

      // --- Divider ---
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 1,
        space: 1,
      ),

      // --- Progress indicator ---
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHigh,
        circularTrackColor: scheme.surfaceContainerHigh,
      ),

      // --- Icon ---
      iconTheme: IconThemeData(color: scheme.onSurface, size: 22),

      // --- Page transitions ---
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        },
      ),

      // --- Splash / ripple ---
      splashFactory: InkSparkle.splashFactory,
    );
  }

  // =======================================================================
  // Typography — tuned for legibility across scripts (Latin, Arabic, CJK…).
  // =======================================================================
  static TextTheme _buildTextTheme(TextTheme base, ColorScheme scheme) {
    TextStyle style({
      required double size,
      required FontWeight weight,
      double? height,
      double? letter,
    }) {
      return TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: height ?? 1.25,
        letterSpacing: letter ?? 0,
        color: scheme.onSurface,
      );
    }

    return base.copyWith(
      displayLarge: style(size: 40, weight: FontWeight.w700, letter: -0.5),
      displayMedium: style(size: 32, weight: FontWeight.w700, letter: -0.4),
      displaySmall: style(size: 28, weight: FontWeight.w600, letter: -0.3),

      headlineLarge: style(size: 26, weight: FontWeight.w700, letter: -0.2),
      headlineMedium: style(size: 22, weight: FontWeight.w600, letter: -0.2),
      headlineSmall: style(size: 20, weight: FontWeight.w600),

      titleLarge: style(size: 18, weight: FontWeight.w600),
      titleMedium: style(size: 16, weight: FontWeight.w600),
      titleSmall: style(size: 14, weight: FontWeight.w600),

      bodyLarge: style(size: 16, weight: FontWeight.w400, height: 1.4),
      bodyMedium: style(size: 14, weight: FontWeight.w400, height: 1.4),
      bodySmall: style(size: 12, weight: FontWeight.w400, height: 1.35),

      labelLarge: style(size: 15, weight: FontWeight.w600, letter: 0.1),
      labelMedium: style(size: 13, weight: FontWeight.w500, letter: 0.1),
      labelSmall: style(size: 11, weight: FontWeight.w500, letter: 0.2),
    );
  }
}

/// =========================================================================
/// AppConstants
/// -------------------------------------------------------------------------
/// Small, app-wide constants that don't belong on the theme.
/// =========================================================================
abstract final class AppConstants {
  /// Height of the primary bottom action bar on dashboards.
  static const double actionBarHeight = 92;

  /// Zoom limits shared by every map screen.
  ///
  /// OpenStreetMap serves tiles up to a native z19, so the tile layers keep
  /// drawing that level scaled up past it rather than going blank. Capping the
  /// camera at 19 itself left very little room: a route fitted to the screen
  /// often starts at 17, which is only two taps from the ceiling.
  static const double mapMinZoom = 3;
  static const double mapMaxZoom = 21;

  /// Highest zoom level for which real tile imagery exists.
  static const int mapNativeMaxZoom = 19;

  /// Standard duration for modal open/close.
  static const Duration sheetDuration = Duration(milliseconds: 260);

  /// Debounce for address search typing.
  static const Duration searchDebounce = Duration(milliseconds: 280);

  /// Telemetry ping interval (see project spec — every 3 seconds).
  static const Duration telemetryInterval = Duration(seconds: 3);

  /// Rider matching timeout (see project spec — 60 seconds).
  static const Duration matchingTimeout = Duration(seconds: 60);

  /// Driver request countdown (see project spec — 15 seconds).
  static const Duration requestCountdown = Duration(seconds: 15);
}

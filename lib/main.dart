import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'theme.dart';
import 'feature/auth/auth_gate.dart';
import 'feature/auth/login_screen.dart';
import 'feature/auth/register_screen.dart';
import 'rider/rider_dashboard2.dart';
import 'rider/profile_screen.dart';
import 'rider/rides_history_screen.dart';
import 'driver/driver_dashboard_view.dart';

void main() async {
  // Ensure Flutter bindings are ready before any async work.
  WidgetsFlutterBinding.ensureInitialized();

  // Global error handling — prevents silent crashes in release.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (kReleaseMode) {
      // Hook your crash reporter here (Sentry, Firebase Crashlytics, etc.)
      // FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    }
  };

  // Catch errors outside the Flutter framework (async gaps, isolates).
  PlatformDispatcher.instance.onError = (error, stack) {
    if (kReleaseMode) {
      // FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    }
    return true;
  };

  // Lock orientation to portrait — ride-hailing apps are used one-handed.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Edge-to-edge: draw behind system bars for a modern, immersive look.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  // Enable edge-to-edge rendering (Android 15+ requires this).
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
  );

  runApp(const RideApp());
}

/// Root application widget.
///
/// Owns:
/// - Theme configuration (light + dark, following system preference)
/// - App-level route table (currently two top-level entry points)
/// - Global navigator + scaffold messenger keys (for overlay access)
class RideApp extends StatefulWidget {
  const RideApp({super.key});

  @override
  State<RideApp> createState() => _RideAppState();
}

class _RideAppState extends State<RideApp> with WidgetsBindingObserver {
  /// Global keys — allow showing snackbars/dialogs from non-widget code
  /// (e.g. WebSocket client error handlers).
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Force rebuild so theme re-resolves against new brightness.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ride',
      debugShowCheckedModeBanner: false,

      // --- Theming ---
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,

      // --- Navigation ---
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      initialRoute: AppRoutes.auth,
      onGenerateRoute: AppRouter.onGenerateRoute,

      // --- Accessibility & UX polish ---
      builder: (context, child) {
        // Clamp text scaling to prevent layout explosions on extreme
        // accessibility settings (e.g. 2.0x+) while still respecting
        // user preference within a sane range.
        final mediaQuery = MediaQuery.of(context);
        final clampedScaler = mediaQuery.textScaler.clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.3,
        );
        return MediaQuery(
          data: mediaQuery.copyWith(textScaler: clampedScaler),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

/// Centralised route names — no magic strings anywhere else in the app.
abstract final class AppRoutes {
  static const String auth = '/auth';
  static const String login = '/auth/login';
  static const String register = '/auth/register';
  static const String rider = '/rider';
  static const String driver = '/driver';
  static const String profile = '/profile';
}

/// Route generator — keeps navigation declarative and centralised.
abstract final class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.auth:
        return _fadeRoute(const AuthGate());
      case AppRoutes.login:
        return _fadeRoute(const LoginScreen());
      case AppRoutes.register:
        return _fadeRoute(const RegisterScreen());
      case AppRoutes.rider:
        return _fadeRoute(const RiderDashboardView());
      case AppRoutes.driver:
        return _fadeRoute(const DriverDashboardView());
      case AppRoutes.profile:
        return _fadeRoute(const ProfileScreen());
      case '/profile/rides':
        return _fadeRoute(const RidesHistoryScreen());
      default:
        return _fadeRoute(
          _UnknownRouteScreen(routeName: settings.name ?? 'unknown'),
        );
    }
  }

  /// Subtle fade — feels premium, avoids the jarring default slide.
  static PageRouteBuilder<T> _fadeRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: child,
        );
      },
    );
  }
}

/// Shown only if a route name is unrecognised — should never happen,
/// but guarantees a graceful UI instead of a red error screen.
class _UnknownRouteScreen extends StatelessWidget {
  const _UnknownRouteScreen({required this.routeName});

  final String routeName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.explore_off_outlined,
                  size: 64,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Route not found',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'We could not open "$routeName".',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
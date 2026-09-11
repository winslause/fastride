import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as perm;

/// =========================================================================
/// LocationService
/// -------------------------------------------------------------------------
/// A thin, well-behaved wrapper over `geolocator` + `permission_handler`.
///
/// Responsibilities:
///   • Ask for permission the right way (foreground first, then background).
///   • Verify location services (GPS) are actually enabled.
///   • Expose a single `Stream<Position>` that:
///       - always emits the last known position on subscribe,
///       - then emits live updates at a configurable cadence,
///       - survives app backgrounding when background permission is granted.
///   • Surface a rich `LocationStatus` so the UI can render the correct
///     empty state ("GPS off", "Permission denied", …) without guessing.
///
/// Design choices:
///   - We do NOT auto-start tracking on construction. The driver dashboard
///     toggles it explicitly. This avoids surprise battery drain.
///   - All exceptions are caught and translated to status values — the
///     stream never throws.
/// =========================================================================
class LocationService {
  LocationService({
    this.accuracy = LocationAccuracy.high,
    this.distanceFilterMeters = 5,
    this.interval = const Duration(seconds: 3),
  });

  /// Desired accuracy — `high` balances GPS precision and battery.
  final LocationAccuracy accuracy;

  /// Minimum movement (meters) required to emit a new position.
  /// Suppresses jitter when the vehicle is parked.
  final double distanceFilterMeters;

  /// Desired emission cadence (matches the 3s telemetry spec).
  final Duration interval;

  // -- Public API -----------------------------------------------------------

  /// Ensures location services are on AND permissions are granted.
  ///
  /// Returns a `LocationStatus` describing the outcome. The UI uses this
  /// to decide whether to show a "Grant permission" or "Turn on GPS" CTA.
  Future<LocationStatus> ensureReady({
    bool requestBackground = false,
  }) async {
    // 1. Is the device's location service (GPS) enabled at all?
    final servicesEnabled = await Geolocator.isLocationServiceEnabled();
    if (!servicesEnabled) {
      return LocationStatus.serviceDisabled;
    }

    // 2. Foreground permission.
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      return LocationStatus.permissionDenied;
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationStatus.permissionDeniedForever;
    }

    // 3. Background permission — only ask if explicitly requested
    //    (driver going online). Riders never need it.
    if (requestBackground) {
      final bg = await perm.Permission.locationAlways.status;
      if (!bg.isGranted) {
        final requested = await perm.Permission.locationAlways.request();
        if (!requested.isGranted) {
          // Foreground works fine; background is a nice-to-have.
          // Return ready but let the caller know background is limited.
          return LocationStatus.readyForegroundOnly;
        }
      }
    }

    return LocationStatus.ready;
  }

  /// Convenience: just check current status without prompting.
  Future<LocationStatus> checkStatus() async {
    final services = await Geolocator.isLocationServiceEnabled();
    if (!services) return LocationStatus.serviceDisabled;

    final permission = await Geolocator.checkPermission();
    return switch (permission) {
      LocationPermission.always => LocationStatus.ready,
      LocationPermission.whileInUse => LocationStatus.readyForegroundOnly,
      LocationPermission.denied => LocationStatus.permissionDenied,
      LocationPermission.deniedForever => LocationStatus.permissionDeniedForever,
      LocationPermission.unableToDetermine => LocationStatus.unknown,
    };
  }

  /// Get the last known position fast (no GPS warm-up).
  /// Returns null if nothing is cached.
  Future<Position?> lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (e) {
      debugPrint('[Location] lastKnown failed: $e');
      return null;
    }
  }

  /// One-shot current position with a timeout.
  Future<Position?> current({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: timeout,
        ),
      );
    } catch (e) {
      debugPrint('[Location] current failed: $e');
      return null;
    }
  }

  /// Live position stream.
  ///
  /// Behaviour:
  ///   • Immediately emits the last known position (if any).
  ///   • Then emits updates from the OS according to `interval` and
  ///     `distanceFilterMeters`.
  ///   • Errors are swallowed and logged — the stream stays alive.
  Stream<Position> positionStream({
    bool foregroundOnly = true,
  }) {
    final settings = AndroidSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilterMeters.round(),
      intervalDuration: interval,
      forceLocationManager: false,
      foregroundNotificationConfig: foregroundOnly
          ? null
          : const ForegroundNotificationConfig(
              notificationTitle: 'Ride — you are online',
              notificationText:
                  'Sharing your location so riders can find you.',
              enableWakeLock: true,
              notificationIcon: AndroidResource(
                name: 'ic_launcher',
                defType: 'mipmap',
              ),
            ),
    );

    final appleSettings = AppleSettings(
      accuracy: accuracy,
      activityType: ActivityType.automotiveNavigation,
      distanceFilter: distanceFilterMeters.round(),
      pauseLocationUpdatesAutomatically: false,
      showBackgroundLocationIndicator: !foregroundOnly,
      allowBackgroundLocationUpdates: !foregroundOnly,
    );

    final stream = Geolocator.getPositionStream(
      locationSettings: _isAndroid ? settings : appleSettings,
    );

    return stream.handleError((Object e, StackTrace s) {
      debugPrint('[Location] stream error: $e');
    });
  }

  /// Open the OS settings page so the user can grant a permission
  /// they previously denied.
  Future<bool> openAppSettings() => perm.openAppSettings();

  /// Open the OS location-services page (for "GPS is off" state).
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  /// Distance between two coordinates in meters.
  double distanceBetween(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {
    return Geolocator.distanceBetween(startLat, startLng, endLat, endLng);
  }

  /// Great-circle bearing from A → B in degrees [0, 360).
  double bearingBetween(
    double startLat,
    double startLng,
    double endLat,
    double endLng,
  ) {
    return Geolocator.bearingBetween(startLat, startLng, endLat, endLng);
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
}

/// =========================================================================
/// Status
/// =========================================================================

enum LocationStatus {
  /// Everything is granted — foreground + background.
  ready,

  /// Foreground works; background is denied (driver will need the app open).
  readyForegroundOnly,

  /// User denied this session — we can re-prompt.
  permissionDenied,

  /// User denied permanently — must open app settings.
  permissionDeniedForever,

  /// GPS / location services are off at the OS level.
  serviceDisabled,

  /// We couldn't determine the state (rare).
  unknown,
}

extension LocationStatusX on LocationStatus {
  bool get isUsable =>
      this == LocationStatus.ready ||
      this == LocationStatus.readyForegroundOnly;

  /// Human-friendly title for a UI banner.
  String get title => switch (this) {
        LocationStatus.ready => 'Location ready',
        LocationStatus.readyForegroundOnly => 'Location ready (app open only)',
        LocationStatus.permissionDenied => 'Location permission needed',
        LocationStatus.permissionDeniedForever => 'Location blocked',
        LocationStatus.serviceDisabled => 'Location services are off',
        LocationStatus.unknown => 'Location unavailable',
      };

  /// Human-friendly explanation for a UI banner.
  String get message => switch (this) {
        LocationStatus.ready =>
          'Your live location is being shared with the platform.',
        LocationStatus.readyForegroundOnly =>
          'Keep the app open to stay visible to riders.',
        LocationStatus.permissionDenied =>
          'Allow location access so we can match you with nearby rides.',
        LocationStatus.permissionDeniedForever =>
          'Enable location in your device settings to continue.',
        LocationStatus.serviceDisabled =>
          'Turn on GPS so we can find your position.',
        LocationStatus.unknown =>
          'We could not read your location. Please try again.',
      };
}
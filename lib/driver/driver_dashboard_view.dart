import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/auth_service.dart';
import '../core/location_service.dart';
import '../core/websocket_client.dart';
import '../models/driver_model.dart';
import '../models/ride_model.dart';
import '../shared/map_zoom_controls.dart';
import '../rider/help_screen.dart';
import '../rider/profile_screen.dart'
    show showChangePasswordDialog, showEditProfile;
import '../theme.dart';
import 'driver_rides_screen.dart';
import 'earnings_summary_sheet.dart';
import 'incoming_request_sheet.dart';
import 'navigation_sheet.dart';
import 'pricing_screen.dart';
import 'services_screen.dart';
import 'vehicles_screen.dart';

/// =========================================================================
/// Driver dashboard
/// -------------------------------------------------------------------------
/// Mirrors the rider dashboard: a permanent sidebar on wide screens, a drawer
/// on narrow ones, and a map home screen with an online toggle.
///
/// Unlike the rider sidebar, the driver's items are operational:
///   0 Home       — map, online toggle, live stats
///   1 Earnings   — today / week / month summary
///   2 My rides   — every trip this driver has made
///   3 Vehicles   — manage the cars they drive
///   4 Services   — manage the extras they offer
///   5 Help       — support
///   6 Settings   — profile, password, sign out
/// =========================================================================
class DriverDashboardView extends StatefulWidget {
  const DriverDashboardView({super.key});

  @override
  State<DriverDashboardView> createState() => _DriverDashboardViewState();
}

class _DriverDashboardViewState extends State<DriverDashboardView>
    with WidgetsBindingObserver {
  // --- Dependencies --------------------------------------------------------
  late final ApiClient _api;
  late final LocationService _location;
  late AuthService _auth;
  late SharedPreferences _prefs;
  WebSocketClient? _socket;

  final MapController _mapController = MapController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  static const LatLng _fallbackCenter = LatLng(1.2921, 36.8219);
  static const double _wideBreakpoint = 900;

  // --- Preferences keys ----------------------------------------------------
  static const _kLat = 'driver_last_lat';
  static const _kLng = 'driver_last_lng';
  static const _kHeading = 'driver_last_heading';

  // --- UI + map state ------------------------------------------------------
  bool _sidebarExpanded = true;
  bool _isOnline = false;
  LatLng _center = _fallbackCenter;
  LatLng? _myPosition;
  double? _heading;
  bool _mapReady = false;
  bool _followingUser = true;
  LocationStatus? _locationStatus;
  int _navIndex = 0;

  // --- Driver data ---------------------------------------------------------
  DriverProfile? _profile;
  bool _loadingProfile = true;
  String? _profileError;

  // --- Trip state ----------------------------------------------------------
  RideModel? _activeRide;
  DriverState _state = DriverState.offline;
  RideOffer? _activeOffer;

  StreamSubscription<Position>? _posSub;
  StreamSubscription<WsEvent>? _wsSub;
  StreamSubscription<WsStatus>? _wsStatusSub;
  Timer? _telemetryTimer;
  Timer? _locationSyncTimer;
  Timer? _locationRetryTimer;
  Timer? _offerPoll;
  final Set<String> _seenOfferIds = <String>{};
  bool _showingOffer = false;
  Position? _lastSent;
  WsStatus _wsStatus = WsStatus.disconnected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient(
      baseUrl: const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://127.0.0.1:8000',
      ),
      osrmBaseUrl: const String.fromEnvironment(
        'OSRM_BASE_URL',
        defaultValue: 'https://router.project-osrm.org',
      ),
      geocoderBaseUrl: const String.fromEnvironment(
        'GEOCODER_BASE_URL',
        defaultValue: 'https://photon.komoot.io',
      ),
    );
    _location = LocationService();
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _wsSub?.cancel();
    _wsStatusSub?.cancel();
    _telemetryTimer?.cancel();
    _locationSyncTimer?.cancel();
    _locationRetryTimer?.cancel();
    _offerPoll?.cancel();
    _socket?.dispose();
    _api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _posSub?.pause();
      _telemetryTimer?.cancel();
      _offerPoll?.cancel();
      _offerPoll = null;
      // Backgrounded: leave the roster so riders aren't offered to a
      // driver who can't respond.
      if (_isOnline) _markOfflineOnBackend();
    } else if (state == AppLifecycleState.resumed) {
      _posSub?.resume();
      // Back in the foreground — rejoin the roster automatically.
      unawaited(_ensureOnline());
    }
  }

  // =========================================================================
  // Bootstrap
  // =========================================================================

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    _auth = AuthService(api: _api, preferences: _prefs);
    await _auth.initialize();

    // 1. Paint immediately from cache so the dashboard is never blank.
    _restoreFromCache();
    if (mounted) setState(() {});

    // 2. Location — the marker must appear even before a live GPS fix.
    unawaited(_initLocation());

    // 3. Backend truth: online flag, stats, cars, services.
    await _refreshProfile();
  }

  /// Paints the map from the last cached fix so the driver sees their marker
  /// immediately, before GPS locks. Availability is never restored from
  /// cache — it is always re-established against the backend.
  void _restoreFromCache() {
    final lat = _prefs.getDouble(_kLat);
    final lng = _prefs.getDouble(_kLng);
    final heading = _prefs.getDouble(_kHeading);

    if (lat != null && lng != null) {
      final here = LatLng(lat, lng);
      _myPosition = here;
      _center = here;
      _heading = heading;
    }
  }

  Future<void> _initLocation() async {
    final status = await _location.ensureReady();
    if (!mounted) return;
    _locationStatus = status;

    if (!status.isUsable) {
      _toast('${status.title} — turn on location to receive rides.');
      // Keep retrying: the user may enable GPS from the system settings
      // while the dashboard is open.
      _locationRetryTimer ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => _retryLocation(),
      );
      return;
    }
    _locationRetryTimer?.cancel();
    _locationRetryTimer = null;

    final last = await _location.lastKnown();
    if (last != null && mounted) _applyPosition(last, moveMap: true);

    if (!kIsWeb) {
      _posSub ??= _location.positionStream().listen(
        (pos) {
          if (mounted) _applyPosition(pos, moveMap: _followingUser);
        },
      );
    }

    _locationSyncTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => _syncLocation(),
    );

    // Freshen the marker with a real fix.
    try {
      final now = await _location.current();
      if (now != null && mounted) _applyPosition(now, moveMap: true);
    } catch (_) {}

    // Location just became usable — join the roster if the profile load
    // happened before that.
    await _ensureOnline();
  }

  Future<void> _retryLocation() async {
    final status = await _location.ensureReady();
    if (!mounted) return;
    if (!status.isUsable) return;
    _locationStatus = status;
    setState(() {});
    await _initLocation();
  }

  void _applyPosition(Position pos, {bool moveMap = false}) {
    final here = LatLng(pos.latitude, pos.longitude);
    setState(() {
      _myPosition = here;
      if (moveMap) {
        _center = here;
        _followingUser = true;
      }
      if (pos.heading >= 0) _heading = pos.heading;
    });
    if (moveMap) _safeMove(here);
    _cachePosition(pos);
  }

  void _cachePosition(Position pos) {
    _prefs.setDouble(_kLat, pos.latitude);
    _prefs.setDouble(_kLng, pos.longitude);
    if (pos.heading >= 0) _prefs.setDouble(_kHeading, pos.heading);
  }

  void _safeMove(LatLng target, {double? zoom}) {
    if (!_mapReady) return;
    try {
      _mapController.move(target, zoom ?? _mapController.camera.zoom);
    } catch (_) {}
  }

  Future<void> _syncLocation() async {
    if (!mounted) return;
    if (!_auth.isReady || !_auth.isAuthenticated) return;
    final here = _myPosition;
    if (here == null) return;
    try {
      await _api.saveLocation(lat: here.latitude, lng: here.longitude);
    } catch (_) {}
  }

  Future<void> _refreshProfile() async {
    if (mounted) {
      setState(() {
        _loadingProfile = true;
        _profileError = null;
      });
    }
    try {
      final profile = await _api.fetchDriverProfile();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loadingProfile = false;
      });

      if (profile != null) {
        // Drivers are always on the roster while the app is open, so the
        // driver's own record decides — not a manual toggle.
        await _ensureOnline();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingProfile = false;
        _profileError = 'Could not reach the server.';
      });
    }
  }

  // =========================================================================
  // Availability
  // -------------------------------------------------------------------------
  // There is no online/offline button: signing in as a driver puts them on
  // the roster automatically, and they drop off when the app closes or is
  // backgrounded.
  // =========================================================================

  /// Brings the driver online once per session, retrying if location or the
  /// backend wasn't ready the first time.
  Future<void> _ensureOnline() async {
    if (_isOnline) return;
    final status = await _location.ensureReady(requestBackground: true);
    if (!mounted) return;
    _locationStatus = status;
    if (!status.isUsable) {
      setState(() {});
      return;
    }
    await _goOnline();
  }

  Future<void> _goOnline() async {
    // Make sure we have a fix before we announce ourselves as available —
    // riders filter on both `is_online` and a recent position.
    if (_myPosition == null) {
      final pos = await _location.lastKnown();
      if (pos != null && mounted) _applyPosition(pos, moveMap: true);
    }

    // Optimistic: the UI reacts instantly, the backend catches up.
    setState(() {
      _isOnline = true;
      _state = DriverState.available;
    });
    HapticFeedback.mediumImpact();

    await _connectSocket();
    _startTelemetry();
    _startOfferPolling();
    await _pushOnlineState(true);
    unawaited(_resumeActiveRide());
  }

  /// ------------------------------------------------------------------------
  /// Resuming an unfinished ride
  /// ------------------------------------------------------------------------
  /// Signing out mid-trip only clears the local session, so the ride row is
  /// still on the server. This puts the driver straight back on the map
  /// instead of leaving them on an empty dashboard.
  Future<void> _resumeActiveRide() async {
    if (!mounted || _activeRide != null) return;

    RideModel? ride;
    try {
      ride = await _api.activeRide();
    } catch (_) {
      return;
    }
    if (!mounted || ride == null || ride.driverId == null) return;

    // Only resume a ride this driver is actually the assigned driver of.
    final myDriverId = _profile?.driver.id;
    if (myDriverId != null && ride.driverId != myDriverId) return;

    final offer = RideOffer(
      rideId: ride.id,
      pickup: ride.pickup,
      dropoff: ride.dropoff,
      distanceMeters: ride.distanceMeters ?? 0,
      durationSeconds: ride.durationSeconds ?? 0,
      payout: ride.fareFinal ?? ride.fareEstimate ?? 0,
      currency: ride.currency,
      riderName: ride.rider?.fullName ?? 'Rider',
      riderRating: 5,
      riderPhone: ride.rider?.phone ?? '',
      distanceToPickupMeters: _distanceTo(ride.pickup),
      otp: ride.otp,
      pricing: _profile?.pricing ?? const DriverPricing(),
    );

    setState(() => _activeOffer = offer);
    _toast('Picking up your trip in progress.');
    await _startNavigation(offer, resumeStage: _stageFor(ride.state));
  }

  /// Where a resumed trip had got to, so the driver is not sent back to the
  /// start of a trip they were already halfway through.
  NavigationStage? _stageFor(RideState state) {
    switch (state) {
      case RideState.ongoing:
        return NavigationStage.onTrip;
      case RideState.driverArrived:
        return NavigationStage.atPickup;
      case RideState.driverArriving:
        return NavigationStage.toPickup;
      default:
        return null;
    }
  }

  /// Drops the driver off the roster — only on sign-out, since a logged-in
  /// driver is otherwise always available.
  Future<void> _leaveRoster() async {
    setState(() {
      _isOnline = false;
      _state = _activeRide != null ? _state : DriverState.offline;
    });
    HapticFeedback.lightImpact();

    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _offerPoll?.cancel();
    _offerPoll = null;
    await _disconnectSocket();
    await _pushOnlineState(false);
  }

  Future<void> _pushOnlineState(bool online) async {
    final here = _myPosition;
    try {
      final ok = await _api.setDriverOnline(
        isOnline: online,
        lat: here?.latitude,
        lng: here?.longitude,
      );
      if (!ok && mounted) {
        _toast('Server did not confirm the status change.');
      }
    } catch (_) {
      if (mounted) {
        _toast(
          online
              ? 'Could not reach the server — riders may not see you.'
              : 'Could not reach the server.',
        );
      }
    }
  }

  Future<void> _markOfflineOnBackend() {
    return _api.setDriverOnline(isOnline: false).catchError((_) => false);
  }

  Future<void> _promptForLocation(LocationStatus status) async {
    if (!mounted) return;
    final fix = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.location_off_rounded),
        title: const Text('Location is off'),
        content: Text(
          '${status.message}\n\nFastRide needs your location to show you on the map and send you nearby ride requests.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    if (fix == true) {
      if (status == LocationStatus.serviceDisabled) {
        await _location.openLocationSettings();
      } else {
        await _location.openAppSettings();
      }
      await _retryLocation();
    }
  }

  // =========================================================================
  // Socket
  // =========================================================================

  Future<void> _connectSocket() async {
    if (_socket != null) return;
    final socket = WebSocketClient(
      url: const String.fromEnvironment(
        'WS_URL',
        defaultValue: 'ws://127.0.0.1:8000/ws',
      ),
      headers: const {'X-Role': 'driver'},
    );
    _socket = socket;
    _wsSub = socket.events.listen(_onSocketEvent);
    _wsStatusSub = socket.status.listen((s) {
      if (mounted) setState(() => _wsStatus = s);
    });
    await socket.connect();
  }

  Future<void> _disconnectSocket() async {
    await _wsSub?.cancel();
    _wsSub = null;
    await _wsStatusSub?.cancel();
    _wsStatusSub = null;
    await _socket?.dispose();
    _socket = null;
    if (mounted) setState(() => _wsStatus = WsStatus.disconnected);
  }

  void _startTelemetry() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(AppConstants.telemetryInterval, (_) async {
      if (!_isOnline || !mounted) return;
      final pos = await _location.lastKnown();
      if (pos == null || _socket == null) return;
      if (_lastSent != null) {
        final moved = _location.distanceBetween(
          _lastSent!.latitude,
          _lastSent!.longitude,
          pos.latitude,
          pos.longitude,
        );
        if (moved < 5) return;
      }
      _lastSent = pos;
      _socket!.send({
        'type': 'telemetry',
        'lat': pos.latitude,
        'lng': pos.longitude,
        'heading': pos.heading,
        'speed': pos.speed,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  void _onSocketEvent(WsEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'ride_offer':
        _handleRideOffer(event);
      case 'ride_cancelled':
        if (_activeRide?.id == event.rideId) {
          setState(() {
            _activeRide = null;
            _activeOffer = null;
            _state = _isOnline ? DriverState.available : DriverState.offline;
          });
          _toast('Rider cancelled this trip.');
        }
      case 'error':
        _toast(event.payload['message']?.toString() ?? 'Connection error.');
      default:
        break;
    }
  }

  // =========================================================================
  // Ride offers (HTTP)
  // -------------------------------------------------------------------------
  // Riders create a ride against a specific driver, so the notification path
  // is a poll of `GET /drivers/me/offers` rather than a broadcast. The socket,
  // when a server provides it, still works and shares this handler.
  // =========================================================================

  void _startOfferPolling() {
    if (_offerPoll != null) return;
    unawaited(_pollOffers());
    _offerPoll = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _pollOffers(),
    );
  }

  Future<void> _pollOffers() async {
    if (!mounted || _showingOffer) return;
    if (_activeRide != null || !_isOnline) return;

    try {
      final result = await _api.driverOffers();
      if (!mounted) return;

      for (final id in result.expired) {
        _seenOfferIds.remove(id);
      }

      if (result.isEmpty) {
        // Nothing waiting: nothing to show, and no reason to keep growing
        // the seen-set.
        _seenOfferIds.clear();
        return;
      }

      // Oldest first — the rider has been waiting longest.
      for (final summary in result.offers) {
        if (summary.rideId.isEmpty) continue;
        if (_seenOfferIds.contains(summary.rideId)) continue;
        _seenOfferIds.add(summary.rideId);
        await _presentOffer(summary);
        return;
      }
    } catch (_) {
      // Offline or backend down; the next tick retries.
    }
  }

  Future<void> _presentOffer(RideOffer summary) async {
    final brief = await _api.fetchRideBrief(rideId: summary.rideId);
    if (!mounted) return;

    // `/rides/{id}/brief` is the authoritative record: coordinates, the
    // rider's phone, the OTP and the fare quoted from this driver's card.
    final offer = brief != null
        ? RideOffer(
            rideId: brief.id,
            pickup: brief.pickup,
            dropoff: brief.dropoff,
            distanceMeters: brief.distanceMeters,
            durationSeconds: brief.durationSeconds,
            payout: brief.fare,
            currency: brief.currency,
            riderName: brief.riderName,
            riderRating: summary.riderRating,
            riderPhone: brief.riderPhone,
            distanceToPickupMeters: _distanceTo(brief.pickup),
            otp: brief.otp,
            pricing: brief.pricing,
          )
        : RideOffer(
            rideId: summary.rideId,
            pickup: const RideLocation(
              lat: 0,
              lng: 0,
              address: '',
              placeName: '',
            ),
            dropoff: const RideLocation(
              lat: 0,
              lng: 0,
              address: '',
              placeName: '',
            ),
            distanceMeters: summary.distanceMeters,
            durationSeconds: summary.durationSeconds,
            payout: summary.payout,
            currency: summary.currency,
            riderName: summary.riderName,
            riderRating: summary.riderRating,
            riderPhone: summary.riderPhone,
            otp: summary.otp,
            pricing: summary.pricing,
          );

    if (offer.pickup.lat == 0 && offer.pickup.lng == 0) {
      _toast('That request is missing pickup details.');
      return;
    }

    _showingOffer = true;
    setState(() {
      _state = DriverState.incomingRequest;
      _activeOffer = offer;
    });
    HapticFeedback.heavyImpact();

    final accepted = await IncomingRequestSheet.show(
      context: context,
      offer: offer,
    );

    _showingOffer = false;
    if (!mounted) return;

    if (accepted == true) {
      try {
        await _api.acceptRide(offer.rideId);
        await _startNavigation(offer);
      } on ApiException catch (e) {
        _toast(e.message);
        _clearOffer();
      } catch (_) {
        _toast('Could not accept the request.');
        _clearOffer();
      }
    } else {
      try {
        await _api.declineRide(offer.rideId);
      } catch (_) {
        // The rider is told the offer expired either way.
      }
      _clearOffer();
    }
  }

  void _clearOffer() {
    if (!mounted) return;
    setState(() {
      _activeOffer = null;
      _state = _isOnline ? DriverState.available : DriverState.offline;
    });
  }

  double _distanceTo(RideLocation target) {
    final here = _myPosition;
    if (here == null) return 1200;
    const distance = Distance();
    return distance.as(
      LengthUnit.Meter,
      LatLng(here.latitude, here.longitude),
      LatLng(target.lat, target.lng),
    );
  }

  Future<void> _handleRideOffer(WsEvent event) async {
    if (_state != DriverState.available) {
      _socket?.send({
        'type': 'ride_reject',
        'ride_id': event.rideId,
        'reason': 'busy',
      });
      return;
    }

    var offer = _parseOffer(event);
    if (offer == null) return;

    // Seed the fare from the driver's own rate card so the total is correct
    // even if the backend brief is unavailable.
    final pricing = _profile?.pricing ?? const DriverPricing();
    offer = RideOffer(
      rideId: offer.rideId,
      pickup: offer.pickup,
      dropoff: offer.dropoff,
      distanceMeters: offer.distanceMeters,
      durationSeconds: offer.durationSeconds,
      payout: offer.payout > 0
          ? offer.payout
          : pricing.quote(
              distanceMeters: offer.distanceMeters,
              durationSeconds: offer.durationSeconds,
            ),
      currency: pricing.currency,
      riderName: offer.riderName,
      riderRating: offer.riderRating,
      riderPhone: offer.riderPhone,
      distanceToPickupMeters: offer.distanceToPickupMeters,
      otp: offer.otp,
      pricing: pricing,
    );

    // The socket message is intentionally small. Fetch the authoritative
    // details — especially the customer's phone number — from the backend.
    final brief = await _api.fetchRideBrief(rideId: offer.rideId);
    if (brief != null) offer = offer.mergeBrief(brief);
    if (!mounted) return;

    setState(() {
      _state = DriverState.incomingRequest;
      _activeOffer = offer;
    });

    final accepted = await IncomingRequestSheet.show(
      context: context,
      offer: offer,
    );

    if (!mounted) return;

    if (accepted == true) {
      _socket?.send({'type': 'ride_accept', 'ride_id': offer.rideId});
      // Persist the decision so the rider's poll sees it too. A socket-only
      // server would fail this, which is why failures are not fatal here.
      try {
        await _api.acceptRide(offer.rideId);
      } catch (_) {}
      await _startNavigation(offer);
    } else {
      _socket?.send({
        'type': 'ride_reject',
        'ride_id': offer.rideId,
        'reason': 'declined',
      });
      try {
        await _api.declineRide(offer.rideId);
      } catch (_) {}
      setState(() {
        _activeOffer = null;
        _state = _isOnline ? DriverState.available : DriverState.offline;
      });
    }
  }

  RideOffer? _parseOffer(WsEvent event) {
    try {
      final p = event.payload;
      final pickupJson = p['pickup'];
      final dropoffJson = p['dropoff'];
      if (pickupJson is! Map || dropoffJson is! Map) return null;

      return RideOffer(
        rideId: event.rideId ?? '',
        pickup: RideLocation.fromJson(
          pickupJson.map((k, v) => MapEntry(k.toString(), v)),
        ),
        dropoff: RideLocation.fromJson(
          dropoffJson.map((k, v) => MapEntry(k.toString(), v)),
        ),
        distanceMeters: (p['distance_meters'] as num?)?.toDouble() ?? 0,
        durationSeconds: (p['duration_seconds'] as num?)?.toDouble() ?? 0,
        payout: (p['payout'] as num?)?.toDouble() ??
            (p['fare'] as num?)?.toDouble() ??
            0,
        currency: p['currency']?.toString() ?? 'KES',
        riderName: p['rider_name']?.toString() ?? 'Rider',
        riderRating: (p['rider_rating'] as num?)?.toDouble() ?? 5.0,
        riderPhone: p['rider_phone']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _startNavigation(
    RideOffer offer, {
    NavigationStage? resumeStage,
  }) async {
    final ride = RideModel(
      id: offer.rideId,
      riderId: '',
      state: RideState.accepted,
      pickup: offer.pickup,
      dropoff: offer.dropoff,
      distanceMeters: offer.distanceMeters,
      durationSeconds: offer.durationSeconds,
      fareEstimate: offer.payout,
      currency: offer.currency,
      otp: offer.otp,
      acceptedAt: DateTime.now(),
    );

    setState(() {
      _activeRide = ride;
      _state = resumeStage == NavigationStage.onTrip
          ? DriverState.onTrip
          : resumeStage == NavigationStage.atPickup
              ? DriverState.atPickup
              : DriverState.enRouteToPickup;
    });

    final outcome = await NavigationSheet.show(
      context: context,
      ride: ride,
      api: _api,
      socket: _socket,
      locationService: _location,
      riderPhone: offer.riderPhone,
      riderName: offer.riderName,
      initialStage: resumeStage,
    );

    if (!mounted) return;

    final wasOnline = _isOnline;
    setState(() {
      _activeRide = null;
      _activeOffer = null;
      _state = wasOnline ? DriverState.available : DriverState.offline;
    });

    if (outcome == NavigationOutcome.completed) {
      await _refreshProfile();
      if (!mounted) return;
      final stats = _profile?.stats;
      await EarningsSummarySheet.show(
        context: context,
        todayTrips: stats?.todayRides ?? 1,
        todayEarnings: stats?.todayEarnings ?? offer.payout,
        lastTrip: ride.copyWith(
          state: RideState.completed,
          completedAt: DateTime.now(),
          fareFinal: offer.payout,
        ),
      );
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =========================================================================
  // Build
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isWide = width >= _wideBreakpoint;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        key: _scaffoldKey,
        extendBody: true,
        drawer: isWide ? null : _buildDrawer(),
        body: SafeArea(
          bottom: false,
          child: Row(
            children: [
              if (isWide)
                AnimatedContainer(
                  duration: AppConstants.sheetDuration,
                  curve: Curves.easeOutCubic,
                  width: _sidebarExpanded ? 260 : 84,
                  child: _buildSidebarRail(),
                ),
              Expanded(
                child: ClipRRect(
                  borderRadius: isWide
                      ? const BorderRadius.horizontal(
                          left: Radius.circular(AppTheme.radiusLg),
                        )
                      : BorderRadius.zero,
                  child: _navIndex == 0
                      ? _buildHome(isWide: isWide)
                      : _buildSection(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Home — the map
  // -------------------------------------------------------------------------

  Widget _buildHome({required bool isWide}) {
    return Stack(
      children: [
        _buildMap(),
        _buildTopBar(isWide: isWide),
        _buildMapControls(),
        _buildHomeSheet(),
      ],
    );
  }

  Widget _buildMap() {
    final scheme = Theme.of(context).colorScheme;
    final offer = _activeOffer;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _center,
        initialZoom: 15,
        minZoom: AppConstants.mapMinZoom,
        maxZoom: AppConstants.mapMaxZoom,
        onMapReady: () {
          _mapReady = true;
          _safeMove(_center, zoom: 15);
        },
        onPositionChanged: (_, hasGesture) {
          if (hasGesture && _followingUser && mounted) {
            setState(() => _followingUser = false);
          }
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchMove,
        ),
        onTap: (_, __) => FocusScope.of(context).unfocus(),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.fastride.app',
          minZoom: AppConstants.mapMinZoom,
          maxZoom: AppConstants.mapMaxZoom,
          maxNativeZoom: AppConstants.mapNativeMaxZoom,
        ),
        // The customer's route: pickup and destination both red.
        if (offer != null)
          PolylineLayer(
            polylines: [
              Polyline(
                points: [
                  LatLng(offer.pickup.lat, offer.pickup.lng),
                  LatLng(offer.dropoff.lat, offer.dropoff.lng),
                ],
                strokeWidth: 4,
                color: AppTheme.danger,
                borderStrokeWidth: 2,
                borderColor: Colors.white,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            if (offer != null) ...[
              _redPin(
                LatLng(offer.pickup.lat, offer.pickup.lng),
                Icons.person_pin_circle_rounded,
              ),
              _redPin(
                LatLng(offer.dropoff.lat, offer.dropoff.lng),
                Icons.place_rounded,
              ),
            ],
            if (_myPosition != null)
              Marker(
                point: _myPosition!,
                width: 56,
                height: 56,
                alignment: Alignment.center,
                child: _selfMarker(scheme),
              ),
          ],
        ),
        const RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [
            TextSourceAttribution('OpenStreetMap contributors'),
          ],
        ),
      ],
    );
  }

  Marker _redPin(LatLng point, IconData icon) {
    return Marker(
      point: point,
      width: 44,
      height: 44,
      alignment: Alignment.center,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.danger,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: AppTheme.softShadow,
        ),
        child: Icon(icon, size: 22, color: Colors.white),
      ),
    );
  }

  Widget _selfMarker(ColorScheme scheme) {
    // Accuracy halo, then a heading arrow.
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Transform.rotate(
          angle: ((_heading ?? 0) * 3.1415926) / 180,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _isOnline ? AppTheme.success : scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: AppTheme.softShadow,
            ),
            child: const Icon(
              Icons.navigation_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar({required bool isWide}) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceLg,
            AppTheme.spaceSm,
            AppTheme.spaceLg,
            AppTheme.spaceSm,
          ),
          child: Row(
            children: [
              if (!isWide) ...[
                _roundButton(
                  icon: Icons.menu_rounded,
                  onTap: () => _scaffoldKey.currentState?.openDrawer(),
                ),
                const SizedBox(width: AppTheme.spaceMd),
              ],
              _roundButton(
                icon: Icons.person_rounded,
                onTap: _openProfile,
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(child: _statusPill()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 22),
        ),
      ),
    );
  }

  /// Live availability read-out. Never offers a toggle — the driver is on the
  /// roster for as long as the app is open.
  Widget _statusPill() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locStatus = _locationStatus;
    final needsLocation = locStatus != null && !locStatus.isUsable;

    // The driver is online by definition — only the trip stage changes, and
    // there is no transient "connecting" state to show.
    final (color, label) = switch ((_state, needsLocation)) {
      (_, true) => (AppTheme.danger, 'Turn on location'),
      (DriverState.available, _) => (AppTheme.success, 'Online'),
      (DriverState.incomingRequest, _) => (AppTheme.success, 'New request'),
      (DriverState.enRouteToPickup, _) => (AppTheme.success, 'Heading to pickup'),
      (DriverState.atPickup, _) => (AppTheme.success, 'At pickup'),
      (DriverState.onTrip, _) => (AppTheme.success, 'On trip'),
      (DriverState.offline, _) => (AppTheme.success, 'Online'),
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          onTap: needsLocation ? () => _promptForLocation(locStatus) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMapControls() {
    final scheme = Theme.of(context).colorScheme;
    final hasFix = _myPosition != null;
    final locStatus = _locationStatus;

    return Positioned(
      right: AppTheme.spaceLg,
      bottom: 208,
      child: Column(
        children: [
          if (locStatus != null && !locStatus.isUsable)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
              child: _mapChip(
                icon: Icons.location_off_rounded,
                label: 'GPS off',
                color: AppTheme.danger,
                onTap: () => _promptForLocation(locStatus),
              ),
            ),
          if (_isOnline && _wsStatus != WsStatus.connected)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
              child: _mapChip(
                icon: Icons.wifi_off_rounded,
                label: 'Reconnecting',
                color: AppTheme.warning,
                onTap: _refreshProfile,
              ),
            ),
          MapZoomControls(controller: _mapController),
          const SizedBox(height: AppTheme.spaceSm),
          _roundButton(
            icon: _followingUser
                ? Icons.my_location_rounded
                : Icons.location_searching_rounded,
            onTap: () async {
              setState(() => _followingUser = true);
              final pos = await _location.current();
              if (pos != null && mounted) _applyPosition(pos, moveMap: true);
              if (_myPosition != null) _safeMove(_myPosition!, zoom: 16);
            },
          ),
          if (!hasFix)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.spaceSm),
              child: _mapChip(
                icon: Icons.gps_fixed_rounded,
                label: 'Locating…',
                color: scheme.onSurfaceVariant,
                onTap: _retryLocation,
              ),
            ),
        ],
      ),
    );
  }

  Widget _mapChip({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The panel at the bottom of the map: online CTA + live stats.
  Widget _buildHomeSheet() {
    final scheme = Theme.of(context).colorScheme;
    final stats = _profile?.stats;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppTheme.radiusLg),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 24,
              offset: Offset(0, -8),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceLg,
              AppTheme.spaceLg,
              AppTheme.spaceLg,
              AppTheme.spaceLg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _statsRow(scheme, stats),
                const SizedBox(height: AppTheme.spaceLg),
                _availabilityBanner(scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statsRow(ColorScheme scheme, DriverStats? stats) {
    return Row(
      children: [
        Expanded(
          child: _statTile(
            scheme,
            icon: Icons.payments_rounded,
            label: "Today's earnings",
            value: _money(stats?.todayEarnings ?? 0),
            color: AppTheme.success,
          ),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          child: _statTile(
            scheme,
            icon: Icons.route_rounded,
            label: 'Trips today',
            value: '${stats?.todayRides ?? 0}',
            color: scheme.primary,
          ),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          child: _statTile(
            scheme,
            icon: Icons.history_rounded,
            label: 'Total rides',
            value: '${stats?.totalRides ?? 0}',
            color: AppTheme.info,
          ),
        ),
      ],
    );
  }

  String _money(double value) => 'KSh ${value.toStringAsFixed(0)}';

  Widget _statTile(
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceMd,
        vertical: AppTheme.spaceMd,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Read-only availability banner. Replaces the old "Go online" button —
  /// the driver joins the roster automatically on sign-in.
  Widget _availabilityBanner(ColorScheme scheme) {
    final theme = Theme.of(context);
    final locStatus = _locationStatus;
    final needsLocation = locStatus != null && !locStatus.isUsable;

    final (icon, tint, title, subtitle) = needsLocation
        ? (
            Icons.location_off_rounded,
            AppTheme.danger,
            'Location is switched off',
            'Tap to turn it on so riders can find you',
          )
        : switch (_state) {
            DriverState.incomingRequest => (
                Icons.notifications_active_rounded,
                AppTheme.success,
                'New ride request',
                'Open the request to accept or decline',
              ),
            DriverState.enRouteToPickup => (
                Icons.navigation_rounded,
                scheme.primary,
                'Heading to pickup',
                'Drive to the customer pickup point',
              ),
            DriverState.atPickup => (
                Icons.pin_drop_rounded,
                scheme.primary,
                'At pickup',
                'Waiting for the customer to board',
              ),
            DriverState.onTrip => (
                Icons.local_taxi_rounded,
                scheme.primary,
                'Trip in progress',
                'Drive to the destination',
              ),
            _ => (
                Icons.check_circle_rounded,
                AppTheme.success,
                "You're online",
                'Waiting for a ride request near you',
              ),
          };

    return Material(
      color: tint.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: needsLocation ? () => _promptForLocation(locStatus) : null,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: Row(
            children: [
              Icon(icon, color: tint),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (needsLocation)
                Icon(Icons.chevron_right_rounded, color: tint)
              else
                _pulseDot(tint),
            ],
          ),
        ),
      ),
    );
  }

  /// Soft breathing dot that signals "we're listening for requests".
  Widget _pulseDot(Color color) {
    return SizedBox(
      width: 12,
      height: 12,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Secondary sections
  // -------------------------------------------------------------------------

  static const _sectionTitles = {
    1: 'Earnings',
    2: 'My rides',
    3: 'Vehicles',
    4: 'Services',
    5: 'Pricing',
    6: 'Help',
    7: 'Settings',
  };

  Widget _buildSection() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            AppTheme.spaceMd,
          ),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _sectionTitles[_navIndex] ?? 'Dashboard',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (_navIndex >= 3 && _navIndex <= 5)
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _refreshProfile,
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
        ),
        Expanded(
          child: switch (_navIndex) {
            1 => _buildEarnings(theme, scheme),
            2 => _buildRides(theme, scheme),
            3 => VehiclesScreen(
                api: _api,
                initialVehicles: _profile?.vehicles ?? const [],
                onChanged: _refreshProfile,
              ),
            4 => ServicesScreen(
                api: _api,
                initialServices: _profile?.services ?? const [],
                onChanged: _refreshProfile,
              ),
            5 => PricingScreen(
                api: _api,
                initialPricing: _profile?.pricing ?? const DriverPricing(),
                onChanged: _refreshProfile,
              ),
            6 => const HelpScreen(),
            7 => _buildSettings(theme, scheme),
            _ => const Center(child: Text('Unknown section')),
          },
        ),
      ],
    );
  }

  Widget _buildEarnings(ThemeData theme, ColorScheme scheme) {
    final stats = _profile?.stats;
    if (_loadingProfile) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _refreshProfile,
      child: ListView(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        children: [
          Row(
            children: [
              Expanded(
                child: _statTile(
                  scheme,
                  icon: Icons.payments_rounded,
                  label: 'Today',
                  value: _money(stats?.todayEarnings ?? 0),
                  color: AppTheme.success,
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: _statTile(
                  scheme,
                  icon: Icons.savings_rounded,
                  label: 'Lifetime',
                  value: _money(stats?.lifetimeEarnings ?? 0),
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: _statTile(
                  scheme,
                  icon: Icons.trending_up_rounded,
                  label: 'Avg / ride',
                  value: _money(stats?.avgPerRide ?? 0),
                  color: AppTheme.info,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spaceLg),
          Card(
            child: ListTile(
              leading: Icon(Icons.bar_chart_rounded, color: scheme.primary),
              title: const Text('Detailed breakdown'),
              subtitle: const Text('Today, this week and this month'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => EarningsSummarySheet.show(
                context: context,
                todayTrips: stats?.todayRides ?? 0,
                todayEarnings: stats?.todayEarnings ?? 0,
              ),
            ),
          ),
          if (_profileError != null)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.spaceLg),
              child: Text(
                _profileError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.danger,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRides(ThemeData theme, ColorScheme scheme) {
    final stats = _profile?.stats;
    return DriverRidesScreen(
      api: _api,
      fallbackStats: DriverRidesSummary(
        totalRides: stats?.totalRides ?? 0,
        todayRides: stats?.todayRides ?? 0,
        todayEarnings: stats?.todayEarnings ?? 0,
      ),
      onResumeRide: _resumeRide,
    );
  }

  /// Tapping an unfinished ride in "My rides" puts the driver back on the map
  /// with the route, at whatever point the trip had reached.
  Future<void> _resumeRide(RideModel ride) async {
    if (!mounted || _activeRide != null) return;
    if (!DriverRidesScreen.isOngoing(ride.state)) return;

    final offer = RideOffer(
      rideId: ride.id,
      pickup: ride.pickup,
      dropoff: ride.dropoff,
      distanceMeters: ride.distanceMeters ?? 0,
      durationSeconds: ride.durationSeconds ?? 0,
      payout: ride.fareFinal ?? ride.fareEstimate ?? 0,
      currency: ride.currency,
      riderName: ride.rider?.fullName ?? 'Rider',
      riderRating: 5,
      riderPhone: ride.rider?.phone ?? '',
      distanceToPickupMeters: _distanceTo(ride.pickup),
      otp: ride.otp,
      pricing: _profile?.pricing ?? const DriverPricing(),
    );

    // Jump to the My rides tab so the sheet is not covering the list.
    setState(() => _navIndex = 1);
    setState(() => _activeOffer = offer);
    await _startNavigation(offer, resumeStage: _stageFor(ride.state));
  }

  Widget _buildSettings(ThemeData theme, ColorScheme scheme) {
    final user = _auth.user;
    return ListView(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      children: [
        if (user != null) ...[
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.primary.withValues(alpha: 0.15),
                child: Text(
                  user.initials,
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              title: Text(
                user.fullName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                [user.email, user.phone]
                    .whereType<String>()
                    .where((e) => e.isNotEmpty)
                    .join(' · '),
              ),
              trailing: TextButton(
                onPressed: _openProfile,
                child: const Text('Edit'),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.spaceLg),
        ],
        ListTile(
          leading: Icon(Icons.person_outline_rounded, color: scheme.primary),
          title: const Text('Edit profile'),
          onTap: _openProfile,
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(Icons.lock_outline_rounded, color: scheme.primary),
          title: const Text('Change password'),
          onTap: () {
            final ctx = _scaffoldKey.currentContext;
            if (ctx == null) return;
            showChangePasswordDialog(context: ctx, auth: _auth);
          },
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(Icons.sync_rounded, color: scheme.primary),
          title: const Text('Refresh dashboard data'),
          onTap: _refreshProfile,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.logout_rounded, color: AppTheme.danger),
          title: Text(
            'Sign out',
            style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.danger),
          ),
          onTap: _logout,
        ),
      ],
    );
  }

  void _openProfile() {
    showEditProfile(context: context, auth: _auth, api: _api);
  }

  Future<void> _logout() async {
    // Leave the roster before dropping the session.
    await _leaveRoster();
    await _auth.logout();
    if (!mounted) return;
    final nav = Navigator.of(_scaffoldKey.currentContext ?? context);
    nav
      ..popUntil((route) => route.isFirst)
      ..pushReplacementNamed('/auth');
  }

  // -------------------------------------------------------------------------
  // Sidebar / drawer
  // -------------------------------------------------------------------------

  Widget _brandMark(ColorScheme scheme) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.local_taxi_rounded, color: scheme.onPrimary, size: 22),
    );
  }

  /// Sidebar badge showing the driver's current per-km rate.
  String get _rateBadge {
    final perKm = _profile?.pricing.pricePerKm ?? 25;
    final rate = perKm == perKm.roundToDouble()
        ? perKm.toStringAsFixed(0)
        : perKm.toStringAsFixed(2);
    return '$rate/km';
  }

  Widget _buildSidebarRail() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceLg,
              AppTheme.spaceSm,
              AppTheme.spaceMd,
              AppTheme.spaceMd,
            ),
            child: Row(
              children: [
                if (_sidebarExpanded)
                  Expanded(
                    child: Row(
                      children: [
                        _brandMark(scheme),
                        const SizedBox(width: AppTheme.spaceMd),
                        Flexible(
                          child: Text(
                            'FastRide',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _brandMark(scheme),
                IconButton(
                  tooltip: _sidebarExpanded ? 'Collapse' : 'Expand',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    setState(() => _sidebarExpanded = !_sidebarExpanded);
                  },
                  icon: Icon(
                    _sidebarExpanded
                        ? Icons.menu_open_rounded
                        : Icons.menu_rounded,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spaceSm,
                vertical: AppTheme.spaceSm,
              ),
              children: [
                _navTile(0, Icons.home_rounded, 'Home'),
                _navTile(
                  1,
                  Icons.account_balance_wallet_rounded,
                  'Earnings',
                ),
                _navTile(2, Icons.receipt_long_rounded, 'My rides', badge: '${_profile?.stats.totalRides ?? 0}'),
                _navTile(
                  3,
                  Icons.directions_car_rounded,
                  'Vehicles',
                  badge: '${_profile?.vehicleCount ?? 0}',
                ),
                _navTile(
                  4,
                  Icons.local_offer_rounded,
                  'Services',
                  badge: '${_profile?.services.length ?? 0}',
                ),
                _navTile(
                  5,
                  Icons.calculate_rounded,
                  'Pricing',
                  badge: _rateBadge,
                ),
                _navTile(6, Icons.help_outline_rounded, 'Help'),
                _navTile(7, Icons.settings_outlined, 'Settings'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppTheme.spaceSm),
            child: Column(
              children: [
                Divider(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                  height: 1,
                ),
                const SizedBox(height: AppTheme.spaceSm),
                _profileFooter(scheme, theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navTile(
    int index,
    IconData icon,
    String label, {
    String? badge,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _navIndex == index;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _navIndex = index);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spaceMd,
              vertical: 12,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                if (_sidebarExpanded) ...[
                  const SizedBox(width: AppTheme.spaceMd),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? scheme.primary.withValues(alpha: 0.18)
                            : scheme.surfaceContainerHigh,
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusPill),
                      ),
                      child: Text(
                        badge,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileFooter(ColorScheme scheme, ThemeData theme) {
    final user = _auth.user;
    final stats = _profile?.stats;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: _openProfile,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spaceSm,
            vertical: AppTheme.spaceSm,
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  user?.initials ?? '?',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (_sidebarExpanded) ...[
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.fullName ?? 'Driver',
                        style: theme.textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${_profile?.driver.ratingLabel ?? '5.0'} ★ · ${stats?.totalRides ?? 0} rides',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = _auth.user;
    final stats = _profile?.stats;

    return Drawer(
      backgroundColor: scheme.surface,
      width: 300,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(AppTheme.radiusLg),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceXl,
                AppTheme.spaceXl,
                AppTheme.spaceLg,
                AppTheme.spaceLg,
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      user?.initials ?? '?',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTheme.spaceLg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.fullName ?? 'Driver',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${stats?.totalRides ?? 0} rides · ${_profile?.driver.ratingLabel ?? '5.0'} ★',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: AppTheme.spaceSm),
                children: [
                  _drawerTile(Icons.home_rounded, 'Home', 0,
                      badge: '${stats?.totalRides ?? 0}'),
                  _drawerTile(
                      Icons.account_balance_wallet_rounded, 'Earnings', 1),
                  _drawerTile(Icons.receipt_long_rounded, 'My rides', 2,
                      badge: '${stats?.totalRides ?? 0}'),
                  _drawerTile(
                      Icons.directions_car_rounded, 'Vehicles', 3,
                      badge: '${_profile?.vehicleCount ?? 0}'),
                  _drawerTile(
                      Icons.local_offer_rounded, 'Services', 4,
                      badge: '${_profile?.services.length ?? 0}'),
                  _drawerTile(Icons.calculate_rounded, 'Pricing', 5,
                      badge: _rateBadge),
                  _drawerTile(Icons.help_outline_rounded, 'Help', 6),
                  _drawerTile(Icons.settings_outlined, 'Settings', 7),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerTile(
    IconData icon,
    String label,
    int index, {
    String? badge,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _navIndex == index;

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.1),
      leading: Icon(
        icon,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          color: selected ? scheme.primary : scheme.onSurface,
        ),
      ),
      trailing: badge == null
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppTheme.radiusPill),
              ),
              child: Text(
                badge,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceLg,
        vertical: 2,
      ),
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(_scaffoldKey.currentContext!).pop();
        Future.microtask(() {
          if (mounted) setState(() => _navIndex = index);
        });
      },
    );
  }
}

enum DriverState {
  offline,
  available,
  incomingRequest,
  enRouteToPickup,
  atPickup,
  onTrip,
}

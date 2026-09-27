import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/location_service.dart';
import '../core/websocket_client.dart';
import '../models/ride_model.dart';
import '../theme.dart';
import 'active_trip_sheet.dart';
import 'destination_sheet.dart';
import 'fare_select_sheet.dart';
import 'matching_sheet.dart';

/// =========================================================================
/// RiderDashboardView
/// -------------------------------------------------------------------------
/// The single consolidated container for the entire rider workflow.
///
/// Architecture:
///   ┌──────────────────────────────────────────────┐
///   │  FlutterMap (fills screen)                   │
///   │  ├─ tile layer (OSM)                         │
///   │  ├─ route polyline (when route ready)        │
///   │  ├─ pickup marker                            │
///   │  ├─ dropoff marker                           │
///   │  └─ driver marker (live, when assigned)      │
///   ├──────────────────────────────────────────────┤
///   │  Top: status pill + profile avatar           │
///   │  Bottom: NavigationBar OR active sheet CTA   │
///   │  Overlay: modal sheets by RiderState         │
///   └──────────────────────────────────────────────┘
///
/// No page-to-page navigation. The RiderState machine decides which
/// modal sheet is layered over the map.
/// =========================================================================
class RiderDashboardView extends StatefulWidget {
  const RiderDashboardView({super.key});

  @override
  State<RiderDashboardView> createState() => _RiderDashboardViewState();
}

class _RiderDashboardViewState extends State<RiderDashboardView>
    with WidgetsBindingObserver {
  // --- Dependencies --------------------------------------------------------
  late final ApiClient _api;
  late final LocationService _location;

  // --- Map ------------------------------------------------------------------
  final MapController _mapController = MapController();
  static const LatLng _fallbackCenter = LatLng(1.2921, 36.8219); // Nairobi

  // --- State ----------------------------------------------------------------
  RiderState _state = RiderState.draft;
  LatLng _center = _fallbackCenter;
  LatLng? _pickup;
  LatLng? _dropoff;
  RideLocation? _pickupLocation;
  RideLocation? _dropoffLocation;
  OsrmRoute? _route;
  RideModel? _ride;
  StreamSubscription<WsEvent>? _wsSub;
  StreamSubscription<Position>? _posSub;
  CancelToken? _routeCancel;
  Timer? _locationTimer;
  bool _mapReady = false;
  bool _routeLoading = false;
  int _navIndex = 0;
  Timer? _timeoutTimer;

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
    _loadAuthToken();
    _bootstrapLocation();
  }

  Future<void> _loadAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('fastride.auth.token');
    if (token != null) {
      _api.authToken = token;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wsSub?.cancel();
    _posSub?.cancel();
    _routeCancel?.cancel();
    _locationTimer?.cancel();
    _timeoutTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _posSub?.pause();
      _locationTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _posSub?.resume();
      _startLocationTimer();
    }
  }

  // =========================================================================
  // Bootstrap
  // =========================================================================

  Future<void> _bootstrapLocation() async {
    final status = await _location.ensureReady();
    if (!mounted) return;

    if (!status.isUsable) {
      _showLocationBanner(status);
      return;
    }

    Position? position = await _location.lastKnown();
    _posSub = _location.positionStream().listen((pos) {
      if (!mounted) return;
      _applyPosition(pos, follow: _state == RiderState.draft);
    });

    if (position != null && mounted) {
      _applyPosition(position, follow: true);
    } else if (mounted) {
      _location.current(timeout: const Duration(seconds: 8)).then((
        currentPosition,
      ) {
        if (!mounted || currentPosition == null || _state != RiderState.draft) {
          return;
        }
        _applyPosition(currentPosition, follow: true);
      });
    }

    _startLocationTimer();
  }

  void _startLocationTimer() {
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final position = await _location.lastKnown();
      if (position == null) {
        try {
          await _location.current(timeout: const Duration(seconds: 5));
        } catch (_) {}
        return;
      }
      try {
        await _api.saveLocation(
          lat: position.latitude,
          lng: position.longitude,
          accuracy: position.accuracy,
        );
      } catch (_) {
        // Silently ignore location save failures.
      }
    });
  }

  void _applyPosition(Position position, {required bool follow}) {
    final here = LatLng(position.latitude, position.longitude);
    setState(() {
      _center = here;
      if (follow || _pickup == null) {
        _pickup = here;
        _pickupLocation = RideLocation(
          lat: position.latitude,
          lng: position.longitude,
          placeName: 'Current location',
        );
      }
    });
    if (follow) _safeMove(here);
  }

  void _safeMove(LatLng target, {double? zoom}) {
    if (!_mapReady) return;
    try {
      _mapController.move(target, zoom ?? _mapController.camera.zoom);
    } catch (_) {
      // Map may not be attached yet — safe to ignore.
    }
  }

  Color _trafficColor(double avgSpeedKmh) {
    if (avgSpeedKmh < 10) return AppTheme.danger;
    if (avgSpeedKmh < 25) return AppTheme.warning;
    return AppTheme.success;
  }

  void _showLocationBanner(LocationStatus status) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.location_off_rounded, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    status.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(status.message, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Fix',
          onPressed: () {
            if (status == LocationStatus.serviceDisabled) {
              _location.openLocationSettings();
            } else {
              _location.openAppSettings();
            }
          },
        ),
      ),
    );
  }

  // =========================================================================
  // Rider flow transitions
  // =========================================================================

  Future<void> _openDestinationSheet() async {
    HapticFeedback.lightImpact();
    final result = await DestinationSheet.show(
      context: context,
      api: _api,
      bias: _center,
    );
    if (result == null || !mounted) return;

    _routeCancel?.cancel();
    setState(() {
      _dropoff = LatLng(result.lat, result.lng);
      _dropoffLocation = RideLocation(
        lat: result.lat,
        lng: result.lng,
        address: result.secondary,
        placeName: result.primary,
      );
      _route = null;
      _routeLoading = true;
      _state = RiderState.searching;
    });

    await _fetchRouteAndPrice();
  }

  Future<void> _fetchRouteAndPrice() async {
    if (_pickup == null || _dropoff == null) {
      setState(() {
        _state = RiderState.draft;
        _routeLoading = false;
        _dropoff = null;
        _dropoffLocation = null;
      });
      _toast('Location unavailable. Please try again.');
      return;
    }
    final from = _pickup!;
    final to = _dropoff!;
    _routeCancel?.cancel();
    final token = CancelToken();
    _routeCancel = token;

    try {
      final route = await _api.route(
        fromLat: from.latitude,
        fromLng: from.longitude,
        toLat: to.latitude,
        toLng: to.longitude,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _route = route;
        _routeLoading = false;
      });
      _fitBounds(from, to);
      // Give a beat so the map animation settles before the pricing sheet.
      await Future<void>.delayed(const Duration(milliseconds: 320));
      if (!mounted || token.isCancelled) return;
      await _openFareSheet(route);
    } on ApiException catch (e) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _state = RiderState.draft;
        _route = null;
        _routeLoading = false;
        _dropoff = null;
        _dropoffLocation = null;
      });
      _toast(e.message);
    }
  }

  Future<void> _openFareSheet(OsrmRoute route) async {
    setState(() => _state = RiderState.pricing);

    final selection = await FareSelectSheet.show(
      context: context,
      route: route,
      pickupLabel: _pickupLocation?.displayLabel ?? 'Pickup',
      dropoffLabel: _dropoffLocation?.displayLabel ?? 'Destination',
    );
    if (selection == null || !mounted) {
      // User dismissed without choosing — reset.
      setState(() {
        _state = RiderState.draft;
        _route = null;
        _dropoff = null;
        _dropoffLocation = null;
      });
      return;
    }

    await _openMatchingSheet(selection);
  }

  Future<void> _openMatchingSheet(FareSelection selection) async {
    setState(() => _state = RiderState.matching);

    final ride = await MatchingSheet.show(
      context: context,
      api: _api,
      pickup: _pickupLocation!,
      dropoff: _dropoffLocation!,
      vehicleClass: selection.vehicleClass,
      fare: selection.fare,
      distanceMeters: _route?.distanceMeters ?? 0,
      durationSeconds: _route?.durationSeconds ?? 0,
    );

    if (!mounted) return;

    if (ride == null) {
      // Cancelled or timed out.
      setState(() {
        _state = RiderState.draft;
        _route = null;
        _dropoff = null;
        _dropoffLocation = null;
      });
      return;
    }

    setState(() {
      _ride = ride;
    });

    _listenToRide();
    await _openActiveTripSheet(ride);
  }

  void _listenToRide() {
    _wsSub?.cancel();
    final rideId = _ride?.id;
    if (rideId == null) return;

    // The MatchingSheet already opened the socket; here we just react to
    // further updates for the currently active ride. In a real deployment
    // you'd share one WebSocketClient across sheets via a provider.
  }

  Future<void> _openActiveTripSheet(RideModel ride) async {
    final outcome = await ActiveTripSheet.show(
      context: context,
      ride: ride,
      api: _api,
    );

    if (!mounted) return;

    switch (outcome) {
      case ActiveTripOutcome.completed:
      case ActiveTripOutcome.cancelled:
        setState(() {
          _state = RiderState.draft;
          _route = null;
          _dropoff = null;
          _dropoffLocation = null;
          _ride = null;
        });
      case null:
        // Sheet dismissed without a terminal outcome — leave state as-is.
        break;
    }
  }

  // =========================================================================
  // Map helpers
  // =========================================================================

  void _fitBounds(LatLng a, LatLng b) {
    if (!_mapReady) return;
    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([a, b]),
          padding: const EdgeInsets.fromLTRB(60, 140, 60, 300),
          maxZoom: 16,
        ),
      );
    } catch (_) {}
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        extendBody: true,
        body: Stack(
          children: [
            _buildMap(),
            _buildTopBar(),
            _buildBottomArea(),
            if (_routeLoading) _buildRouteLoadingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteLoadingOverlay() {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.spaceLg),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spaceLg,
                  vertical: AppTheme.spaceMd,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                  boxShadow: AppTheme.softShadow,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: AppTheme.spaceMd),
                    Text(
                      'Finding your route…',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _center,
        initialZoom: 15,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: () {
          _mapReady = true;
          _safeMove(_center, zoom: 15);
        },
        interactionOptions: const InteractionOptions(
          flags:
              InteractiveFlag.drag |
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
          userAgentPackageName: 'com.ride.app',
          maxNativeZoom: 19,
          tileProvider: NetworkTileProvider(),
        ),
        if (_route != null && _route!.polyline.isNotEmpty)
          PolylineLayer(
            polylines: _route!.segments.isNotEmpty
                ? _route!.segments.asMap().map((i, seg) {
                    return MapEntry(
                      i,
                      Polyline(
                        points: seg.polyline
                            .map((p) => LatLng(p.lat, p.lng))
                            .toList(),
                        strokeWidth: 5,
                        color: _trafficColor(seg.avgSpeedKmh),
                        borderStrokeWidth: 1,
                        borderColor: Colors.white,
                      ),
                    );
                  }).values.toList()
                : [
                    Polyline(
                      points: _route!.polyline
                          .map((p) => LatLng(p.lat, p.lng))
                          .toList(),
                      strokeWidth: 5,
                      color: Theme.of(context).colorScheme.primary,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
          ),
        MarkerLayer(
          markers: [
            if (_pickup != null)
              _marker(
                point: _pickup!,
                color: Theme.of(context).colorScheme.primary,
                icon: Icons.my_location_rounded,
              ),
            if (_dropoff != null)
              _marker(
                point: _dropoff!,
                color: AppTheme.danger,
                icon: Icons.place_rounded,
              ),
          ],
        ),
        // Attribution — required by OSM's tile usage policy.
        const RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [TextSourceAttribution('OpenStreetMap contributors')],
        ),
      ],
    );
  }

  Marker _marker({
    required LatLng point,
    required Color color,
    required IconData icon,
  }) {
    return Marker(
      point: point,
      width: 44,
      height: 44,
      alignment: Alignment.center,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: AppTheme.softShadow,
          border: Border.all(color: color, width: 3),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }

  Widget _buildTopBar() {
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
              _profileAvatar(),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(child: _statusPill()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileAvatar() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
         onTap: () async {
           final prefs = await SharedPreferences.getInstance();
           if (prefs.getString('fastride.auth.user') == null) {
             _toast('Sign in to continue');
             return;
           }
           Navigator.of(context).pushNamed('/profile');
         },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            Icons.person_rounded,
            size: 22,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _statusPill() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (label, dot) = switch (_state) {
      RiderState.draft => ('Where to?', scheme.primary),
      RiderState.searching => ('Finding your route…', AppTheme.info),
      RiderState.pricing => ('Choose your ride', scheme.primary),
      RiderState.matching => (
        _ride?.state.label ?? 'Matching you…',
        AppTheme.warning,
      ),
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
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
    );
  }

  Widget _buildBottomArea() {
    // While the rider is in an active ride flow, the bottom of the screen
    // is owned by the sheet — hide the NavigationBar.
    final hideNav = _state != RiderState.draft;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedSlide(
        offset: hideNav ? const Offset(0, 1) : Offset.zero,
        duration: AppConstants.sheetDuration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: hideNav ? 0 : 1,
          duration: AppConstants.sheetDuration,
          child: _bottomNavigator(),
        ),
      ),
    );
  }

  Widget _bottomNavigator() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Primary CTA — opens the destination sheet.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceLg,
                AppTheme.spaceLg,
                AppTheme.spaceLg,
                AppTheme.spaceSm,
              ),
              child: _searchAnchor(),
            ),
            NavigationBar(
              selectedIndex: _navIndex,
              onDestinationSelected: (i) async {
                HapticFeedback.selectionClick();
                setState(() => _navIndex = i);
                switch (i) {
                  case 1:
                    Navigator.of(context).pushNamed('/profile/rides');
                  case 2:
                    _toast('Wallet and payments coming soon');
                  case 3:
                    Navigator.of(context).pushNamed('/profile');
                }
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long_rounded),
                  label: 'Rides',
                ),
                NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  selectedIcon: Icon(Icons.account_balance_wallet_rounded),
                  label: 'Wallet',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  selectedIcon: Icon(Icons.person_rounded),
                  label: 'Profile',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchAnchor() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: _openDestinationSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spaceLg,
            vertical: 16,
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, color: scheme.primary, size: 22),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: Text(
                  'Where are you going?',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum RiderState { draft, searching, pricing, matching }

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/api_client.dart';
import '../core/location_service.dart';
import '../core/websocket_client.dart';
import '../models/driver_model.dart';
import '../models/ride_model.dart';
import '../theme.dart';
import 'earnings_summary_sheet.dart';
import 'incoming_request_sheet.dart';
import 'navigation_sheet.dart';

class DriverDashboardView extends StatefulWidget {
  const DriverDashboardView({super.key});

  @override
  State<DriverDashboardView> createState() => _DriverDashboardViewState();
}

class _DriverDashboardViewState extends State<DriverDashboardView>
    with WidgetsBindingObserver {
  late final ApiClient _api;
  late final LocationService _location;
  WebSocketClient? _socket;

  final MapController _mapController = MapController();
  static const LatLng _fallbackCenter = LatLng(1.2921, 36.8219);

  bool _isOnline = false;
  bool _busy = false;
  LatLng _center = _fallbackCenter;
  LatLng? _myPosition;
  double? _heading;
  bool _mapReady = false;
  int _navIndex = 0;

  RideModel? _activeRide;
  DriverState _state = DriverState.offline;

  StreamSubscription<Position>? _posSub;
  StreamSubscription<WsEvent>? _wsSub;
  Timer? _telemetryTimer;
  Position? _lastSent;

  double _todayEarnings = 0;
  int _todayTrips = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = ApiClient(
      baseUrl: const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'https://api.example.com/v1',
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
    _bootstrapLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _wsSub?.cancel();
    _telemetryTimer?.cancel();
    _socket?.dispose();
    _api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _posSub?.pause();
      _telemetryTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _posSub?.resume();
      if (_isOnline) _startTelemetry();
    }
  }

  Future<void> _bootstrapLocation() async {
    final status = await _location.ensureReady();
    if (!mounted) return;

    if (!status.isUsable) {
      _showLocationBanner(status);
      return;
    }

    final last = await _location.lastKnown();
    if (last != null && mounted) {
      final here = LatLng(last.latitude, last.longitude);
      setState(() {
        _center = here;
        _myPosition = here;
        _heading = last.heading;
      });
      _safeMove(here);
    }

    _posSub = _location.positionStream().listen((pos) {
      if (!mounted) return;
      final here = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _center = here;
        _myPosition = here;
        if (pos.heading >= 0) _heading = pos.heading;
      });
      _safeMove(here);
    });
  }

  void _safeMove(LatLng target, {double? zoom}) {
    if (!_mapReady) return;
    try {
      _mapController.move(target, zoom ?? _mapController.camera.zoom);
    } catch (_) {}
  }

  void _showLocationBanner(LocationStatus status) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${status.title} — ${status.message}'),
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

  Future<void> _toggleOnline() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      if (!_isOnline) {
        final status = await _location.ensureReady(requestBackground: true);
        if (!status.isUsable) {
          _showLocationBanner(status);
          return;
        }

        final pos = await _location.current() ?? await _location.lastKnown();
        if (pos == null) {
          _toast('Waiting for GPS fix…');
          return;
        }

        await _connectSocket();
        _startTelemetry();

        if (!mounted) return;
        setState(() {
          _isOnline = true;
          _state = DriverState.available;
        });
        HapticFeedback.mediumImpact();
        _toast('You are online. Waiting for requests…');
      } else {
        await _disconnectSocket();
        _telemetryTimer?.cancel();

        if (!mounted) return;
        setState(() {
          _isOnline = false;
          _state = DriverState.offline;
        });
        HapticFeedback.lightImpact();
        _toast('You are offline.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectSocket() async {
    final socket = WebSocketClient(
      url: const String.fromEnvironment(
        'WS_URL',
        defaultValue: 'wss://api.example.com/ws',
      ),
      headers: const {'X-Role': 'driver'},
    );
    _socket = socket;
    _wsSub = socket.events.listen(_onSocketEvent);
    await socket.connect();
  }

  Future<void> _disconnectSocket() async {
    await _wsSub?.cancel();
    _wsSub = null;
    await _socket?.dispose();
    _socket = null;
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
            _state =
                _isOnline ? DriverState.available : DriverState.offline;
          });
          _toast('Rider cancelled this trip.');
        }
      case 'error':
        _toast(event.payload['message']?.toString() ?? 'Connection error.');
      default:
        break;
    }
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

    final offer = _parseOffer(event);
    if (offer == null) return;

    setState(() => _state = DriverState.incomingRequest);

    final accepted = await IncomingRequestSheet.show(
      context: context,
      offer: offer,
    );

    if (!mounted) return;

    if (accepted == true) {
      _socket?.send({
        'type': 'ride_accept',
        'ride_id': offer.rideId,
      });
      await _startNavigation(offer);
    } else {
      _socket?.send({
        'type': 'ride_reject',
        'ride_id': offer.rideId,
        'reason': 'declined',
      });
      setState(() {
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
        currency: p['currency']?.toString() ?? 'USD',
        riderName: p['rider_name']?.toString() ?? 'Rider',
        riderRating: (p['rider_rating'] as num?)?.toDouble() ?? 5.0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _startNavigation(RideOffer offer) async {
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
      acceptedAt: DateTime.now(),
    );

    setState(() {
      _activeRide = ride;
      _state = DriverState.enRouteToPickup;
    });

    final outcome = await NavigationSheet.show(
      context: context,
      ride: ride,
      api: _api,
      socket: _socket,
    );

    if (!mounted) return;

    if (outcome == NavigationOutcome.completed) {
      setState(() {
        _activeRide = null;
        _state = _isOnline ? DriverState.available : DriverState.offline;
        _todayTrips += 1;
        _todayEarnings += offer.payout;
      });
      await EarningsSummarySheet.show(
        context: context,
        todayTrips: _todayTrips,
        todayEarnings: _todayEarnings,
        lastTrip: ride.copyWith(
          state: RideState.completed,
          completedAt: DateTime.now(),
          fareFinal: offer.payout,
        ),
      );
    } else if (outcome == NavigationOutcome.cancelled) {
      setState(() {
        _activeRide = null;
        _state = _isOnline ? DriverState.available : DriverState.offline;
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

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
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    final scheme = Theme.of(context).colorScheme;

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
          maxNativeZoom: 19,
        ),
        if (_activeRide != null)
          PolylineLayer(
            polylines: [
              Polyline(
                points: [
                  LatLng(_activeRide!.pickup.lat, _activeRide!.pickup.lng),
                  LatLng(_activeRide!.dropoff.lat, _activeRide!.dropoff.lng),
                ],
                strokeWidth: 4,
                color: scheme.primary,
                borderStrokeWidth: 2,
                borderColor: Colors.white,
              ),
            ],
          ),
        if (_myPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _myPosition!,
                width: 60,
                height: 60,
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

  Widget _selfMarker(ColorScheme scheme) {
    return Transform.rotate(
      angle: ((_heading ?? 0) * 3.1415926) / 180,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: AppTheme.softShadow,
        ),
        child: const Icon(
          Icons.navigation_rounded,
          color: Colors.white,
          size: 22,
        ),
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
              Expanded(child: _onlinePill()),
              const SizedBox(width: AppTheme.spaceMd),
              _onlineToggle(),
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
        onTap: () => _toast('Profile coming soon'),
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

  Widget _onlinePill() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _isOnline ? AppTheme.success : scheme.onSurfaceVariant;
    final label = _isOnline ? _stateLabel() : 'You are offline';

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
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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

  String _stateLabel() => switch (_state) {
        DriverState.available => 'Online · waiting',
        DriverState.incomingRequest => 'New request',
        DriverState.enRouteToPickup => 'To pickup',
        DriverState.atPickup => 'At pickup',
        DriverState.onTrip => 'On trip',
        DriverState.offline => 'You are offline',
      };

  Widget _onlineToggle() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: _isOnline ? AppTheme.success : scheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        onTap: _busy ? null : _toggleOnline,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _isOnline ? Colors.white : scheme.primary,
                  ),
                )
              else
                Icon(
                  Icons.power_settings_new_rounded,
                  size: 18,
                  color: _isOnline ? Colors.white : scheme.primary,
                ),
              const SizedBox(width: 8),
              Text(
                _isOnline ? 'Go offline' : 'Go online',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _isOnline ? Colors.white : scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomArea() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _bottomNavigator(),
    );
  }

  Widget _bottomNavigator() {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

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
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceLg,
                AppTheme.spaceLg,
                AppTheme.spaceLg,
                AppTheme.spaceSm,
              ),
              child: _todayStats(theme, scheme),
            ),
            NavigationBar(
              selectedIndex: _navIndex,
              onDestinationSelected: (i) {
                HapticFeedback.selectionClick();
                setState(() => _navIndex = i);
                switch (i) {
                  case 1:
                    EarningsSummarySheet.show(
                      context: context,
                      todayTrips: _todayTrips,
                      todayEarnings: _todayEarnings,
                    );
                  case 2:
                    _toast('Vehicle & documents coming soon');
                  case 3:
                    _toast('Profile coming soon');
                }
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  selectedIcon: Icon(Icons.account_balance_wallet_rounded),
                  label: 'Earnings',
                ),
                NavigationDestination(
                  icon: Icon(Icons.directions_car_outlined),
                  selectedIcon: Icon(Icons.directions_car_rounded),
                  label: 'Vehicle',
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

  Widget _todayStats(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        Expanded(
          child: _statCard(
            theme,
            scheme,
            icon: Icons.attach_money_rounded,
            label: 'Today',
            value: '\$${_todayEarnings.toStringAsFixed(2)}',
            color: AppTheme.success,
          ),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          child: _statCard(
            theme,
            scheme,
            icon: Icons.local_taxi_rounded,
            label: 'Trips',
            value: '$_todayTrips',
            color: scheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _statCard(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceLg,
        vertical: AppTheme.spaceMd,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: AppTheme.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0.4,
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
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
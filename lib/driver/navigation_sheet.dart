import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/api_client.dart';
import '../core/location_service.dart';
import '../core/websocket_client.dart';
import '../models/ride_model.dart';
import '../shared/custom_modal.dart';
import '../theme.dart';

enum NavigationOutcome { completed, cancelled }

class NavigationSheet extends StatefulWidget {
  const NavigationSheet({
    super.key,
    required this.ride,
    required this.api,
    this.socket,
    this.locationService,
  });

  final RideModel ride;
  final ApiClient api;
  final WebSocketClient? socket;
  final LocationService? locationService;

  static Future<NavigationOutcome?> show({
    required BuildContext context,
    required RideModel ride,
    required ApiClient api,
    WebSocketClient? socket,
    LocationService? locationService,
  }) {
    return showGeneralDialog<NavigationOutcome>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black,
      transitionDuration: AppConstants.sheetDuration,
      pageBuilder: (_, __, ___) =>
          NavigationSheet(ride: ride, api: api, socket: socket, locationService: locationService),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    );
  }

  @override
  State<NavigationSheet> createState() => _NavigationSheetState();
}

class _NavigationSheetState extends State<NavigationSheet> {
  final MapController _mapController = MapController();

  late RideModel _ride;
  late NavigationStage _stage;
  late final LocationService _location;
  StreamSubscription<Position>? _posSub;
  Timer? _locationSyncTimer;

  OsrmRoute? _route;
  bool _loadingRoute = false;
  bool _mapReady = false;
  bool _sending = false;
  LatLng? _driverPosition;

  @override
  void initState() {
    super.initState();
    _ride = widget.ride;
    _stage = NavigationStage.toPickup;
    _location = widget.locationService ?? LocationService();
    _driverPosition = _currentDriverCoords();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRoute();
      _startLocationTracking();
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _locationSyncTimer?.cancel();
    super.dispose();
  }

  Future<void> _startLocationTracking() async {
    final status = await _location.ensureReady();
    if (!status.isUsable) return;

    final pos = await _location.current();
    if (pos != null) {
      setState(() {
        _driverPosition = LatLng(pos.latitude, pos.longitude);
      });
    }

    _posSub = _location.positionStream().listen((p) {
      if (!mounted) return;
      final here = LatLng(p.latitude, p.longitude);
      setState(() {
        _driverPosition = here;
      });
    });

    _locationSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncDriverLocation();
    });
  }

  Future<void> _syncDriverLocation() async {
    if (!mounted || _driverPosition == null) return;
    try {
      await widget.api.saveLocation(
        lat: _driverPosition!.latitude,
        lng: _driverPosition!.longitude,
      );
    } catch (_) {}
  }

  Future<void> _loadRoute() async {
    if (_sending) return;
    setState(() => _loadingRoute = true);

    final from = _stage == NavigationStage.toPickup
        ? _currentDriverCoords()
        : LatLng(_ride.pickup.lat, _ride.pickup.lng);
    final to = _stage == NavigationStage.toPickup
        ? LatLng(_ride.pickup.lat, _ride.pickup.lng)
        : LatLng(_ride.dropoff.lat, _ride.dropoff.lng);

    try {
      final route = await widget.api.route(
        fromLat: from.latitude,
        fromLng: from.longitude,
        toLat: to.latitude,
        toLng: to.longitude,
      );
      if (!mounted) return;
      setState(() {
        _route = route;
        _loadingRoute = false;
      });
      _fitRoute(route);
    } on ApiException {
      if (!mounted) return;
      final line = <({double lat, double lng})>[
        (lat: from.latitude, lng: from.longitude),
        (lat: to.latitude, lng: to.longitude),
      ];
      final fallback = OsrmRoute(
          distanceMeters: 0,
          durationSeconds: 0,
          polyline: line,
          segments: const [],
        );
      setState(() {
        _route = fallback;
        _loadingRoute = false;
      });
      _fitRoute(fallback);
    }
  }

  LatLng _currentDriverCoords() {
    if (_driverPosition != null) {
      return _driverPosition!;
    }
    final driver = _ride.driver;
    if (driver != null && driver.hasPosition) {
      return LatLng(driver.latitude!, driver.longitude!);
    }
    return LatLng(_ride.pickup.lat, _ride.pickup.lng);
  }

  void _fitRoute(OsrmRoute route) {
    if (!_mapReady || route.polyline.isEmpty) return;
    try {
      final points = route.polyline
          .map<LatLng>((p) => LatLng(p.lat, p.lng))
          .toList(growable: false);
      if (_driverPosition != null) {
        points.add(_driverPosition!);
      }
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.fromLTRB(48, 120, 48, 280),
          maxZoom: 17,
        ),
      );
    } catch (_) {}
  }

  Future<void> _markArrived() async {
    if (_sending) return;
    setState(() => _sending = true);

    try {
      widget.socket?.send({
        'type': 'driver_arrived',
        'ride_id': _ride.id,
      });
      if (!mounted) return;
      setState(() {
        _stage = NavigationStage.atPickup;
        _ride = _ride.copyWith(
          state: RideState.driverArrived,
          arrivedAtPickupAt: DateTime.now(),
        );
      });
      HapticFeedback.mediumImpact();
      _loadRoute();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startRide() async {
    if (_sending) return;
    setState(() => _sending = true);

    try {
      widget.socket?.send({
        'type': 'ride_started',
        'ride_id': _ride.id,
      });
      if (!mounted) return;
      setState(() {
        _stage = NavigationStage.onTrip;
        _ride = _ride.copyWith(
          state: RideState.ongoing,
          startedAt: DateTime.now(),
        );
        _route = null;
      });
      HapticFeedback.mediumImpact();
      await _loadRoute();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _endRide() async {
    if (_sending) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this trip?'),
        content: Text(
          'Confirm that you have dropped off '
          '${_ride.rider?.firstName ?? 'the rider'} '
          'at ${_ride.dropoff.displayLabel}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
            child: const Text('End trip'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _sending = true);
    try {
      widget.socket?.send({
        'type': 'ride_completed',
        'ride_id': _ride.id,
        'ended_at': DateTime.now().toIso8601String(),
      });
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      Navigator.of(context).pop(NavigationOutcome.completed);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancelRide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this trip?'),
        content: const Text(
          'Frequent cancellations can affect your rating and dispatch priority.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Cancel trip'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    widget.socket?.send({
      'type': 'ride_cancelled',
      'ride_id': _ride.id,
      'reason': 'driver_cancelled',
    });
    if (!mounted) return;
    Navigator.of(context).pop(NavigationOutcome.cancelled);
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
            _buildBottomPanel(),
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
        initialCenter: LatLng(_ride.pickup.lat, _ride.pickup.lng),
        initialZoom: 14,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: () {
          _mapReady = true;
          if (_route != null) _fitRoute(_route!);
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.fastride.app',
          maxNativeZoom: 19,
        ),
        if (_route != null && _route!.polyline.isNotEmpty)
          PolylineLayer(
            polylines: _route!.segments.isNotEmpty
                ? _route!.segments.asMap().map((i, seg) {
                    return MapEntry(
                      i,
                      Polyline(
                        points: seg.polyline
                            .map<LatLng>((p) => LatLng(p.lat, p.lng))
                            .toList(),
                        strokeWidth: 6,
                        color: _trafficColor(seg.avgSpeedKmh),
                        borderStrokeWidth: 1,
                        borderColor: Colors.white,
                      ),
                    );
                  }).values.toList()
                : [
                    Polyline(
                      points: _route!.polyline
                          .map<LatLng>((p) => LatLng(p.lat, p.lng))
                          .toList(),
                      strokeWidth: 6,
                      color: scheme.primary,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
          ),
        MarkerLayer(
          markers: [
            if (_driverPosition != null) _driverMarker(_driverPosition!, scheme),
            _pin(
              LatLng(_ride.pickup.lat, _ride.pickup.lng),
              scheme.primary,
              Icons.my_location_rounded,
            ),
            if (_stage == NavigationStage.onTrip)
              _pin(
                LatLng(_ride.dropoff.lat, _ride.dropoff.lng),
                AppTheme.danger,
                Icons.place_rounded,
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

  Marker _pin(LatLng point, Color color, IconData icon) {
    return Marker(
      point: point,
      width: 44,
      height: 44,
      alignment: Alignment.center,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 3),
          boxShadow: AppTheme.softShadow,
        ),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }

  Marker _driverMarker(LatLng point, ColorScheme scheme) {
    return Marker(
      point: point,
      width: 32,
      height: 32,
      alignment: Alignment.center,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: AppTheme.softShadow,
        ),
        child: const Icon(Icons.motorcycle_rounded, size: 16, color: Colors.white),
      ),
    );
  }

  Color _trafficColor(double avgSpeedKmh) {
    if (avgSpeedKmh < 10) return const Color(0xFFE53935); // Red (heavy traffic)
    if (avgSpeedKmh < 25) return const Color(0xFFFF9800); // Orange (moderate)
    return const Color(0xFF43A047); // Green (free flowing)
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: Row(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surface,
                shape: const CircleBorder(),
                elevation: 2,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _cancelRide,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.close_rounded, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(child: _stagePill()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stagePill() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (label, color) = switch (_stage) {
      NavigationStage.toPickup => ('Heading to pickup', scheme.primary),
      NavigationStage.atPickup => ('Waiting at pickup', AppTheme.success),
      NavigationStage.onTrip => ('On trip', AppTheme.info),
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
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

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
              AppTheme.spaceXl,
              AppTheme.spaceLg,
              AppTheme.spaceXl,
              AppTheme.spaceLg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _routeSummary(theme, scheme),
                const SizedBox(height: AppTheme.spaceLg),
                _milestones(theme, scheme),
                const SizedBox(height: AppTheme.spaceLg),
                _actionButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _routeSummary(ThemeData theme, ColorScheme scheme) {
    final target =
        _stage == NavigationStage.toPickup ? _ride.pickup : _ride.dropoff;
    final label = _stage == NavigationStage.toPickup ? 'Pickup' : 'Dropoff';
    final eta = _loadingRoute
        ? '…'
        : _route == null
            ? '—'
            : _fmtDuration(_route!.durationSeconds);
    final distance = _loadingRoute
        ? '…'
        : _route == null
            ? '—'
            : _fmtDistance(_route!.distanceMeters);

    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Icon(Icons.navigation_rounded, color: scheme.primary),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label · $eta',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                target.displayLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Text(
          distance,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _milestones(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        _milestone(
          theme,
          scheme,
          icon: Icons.directions_car_rounded,
          label: 'Accepted',
          active: _stage.index >= NavigationStage.toPickup.index,
        ),
        _connector(scheme, _stage.index >= NavigationStage.atPickup.index),
        _milestone(
          theme,
          scheme,
          icon: Icons.person_pin_circle_rounded,
          label: 'At pickup',
          active: _stage.index >= NavigationStage.atPickup.index,
        ),
        _connector(scheme, _stage.index >= NavigationStage.onTrip.index),
        _milestone(
          theme,
          scheme,
          icon: Icons.flag_rounded,
          label: 'Dropoff',
          active: _stage.index >= NavigationStage.onTrip.index,
        ),
      ],
    );
  }

  Widget _milestone(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required bool active,
  }) {
    final color = active ? scheme.primary : scheme.outlineVariant;
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: active
                  ? scheme.primary.withValues(alpha: 0.12)
                  : scheme.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _connector(ColorScheme scheme, bool active) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Container(
          height: 2,
          color: active ? scheme.primary : scheme.outlineVariant,
        ),
      ),
    );
  }

  Widget _actionButton() {
    final (label, icon, tone, onPressed) = switch (_stage) {
      NavigationStage.toPickup => (
          'Arrived at pickup',
          Icons.pin_drop_rounded,
          SheetButtonTone.primary,
          _markArrived,
        ),
      NavigationStage.atPickup => (
          'Start ride',
          Icons.play_arrow_rounded,
          SheetButtonTone.primary,
          _startRide,
        ),
      NavigationStage.onTrip => (
          'End ride',
          Icons.flag_rounded,
          SheetButtonTone.danger,
          _endRide,
        ),
    };

    return SheetPrimaryButton(
      label: label,
      icon: icon,
      tone: tone,
      isLoading: _sending,
      onPressed: _sending ? null : onPressed,
    );
  }

  String _fmtDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _fmtDuration(double seconds) {
    final m = (seconds / 60).round();
    if (m < 1) return '<1 min';
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return '${h}h ${r.toString().padLeft(2, '0')}m';
  }
}

enum NavigationStage { toPickup, atPickup, onTrip }
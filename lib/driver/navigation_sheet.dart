import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/location_service.dart';
import '../core/websocket_client.dart';
import '../models/ride_model.dart';
import '../shared/custom_modal.dart';
import '../shared/map_zoom_controls.dart';
import '../theme.dart';

enum NavigationOutcome { completed, cancelled }

class NavigationSheet extends StatefulWidget {
  const NavigationSheet({
    super.key,
    required this.ride,
    required this.api,
    this.socket,
    this.locationService,
    this.riderPhone = '',
    this.riderName = '',
    this.initialStage,
  });

  final RideModel ride;
  final ApiClient api;
  final WebSocketClient? socket;
  final LocationService? locationService;

  /// The customer's phone number, so the driver can call them from the map.
  final String riderPhone;
  final String riderName;

  /// Where to pick the trip up. Defaults to driving to the pickup, but a ride
  /// resumed after signing out already knows how far along it is.
  final NavigationStage? initialStage;

  bool get hasRiderPhone => riderPhone.trim().isNotEmpty;

  static Future<NavigationOutcome?> show({
    required BuildContext context,
    required RideModel ride,
    required ApiClient api,
    WebSocketClient? socket,
    LocationService? locationService,
    String riderPhone = '',
    String riderName = '',
    NavigationStage? initialStage,
  }) {
    // A non-opaque page route rather than a dialog: there is no modal barrier,
    // so folding the panel away leaves the map fully visible and pannable.
    return Navigator.of(context).push<NavigationOutcome>(
      PageRouteBuilder<NavigationOutcome>(
        opaque: false,
        transitionDuration: AppConstants.sheetDuration,
        pageBuilder: (_, __, ___) => NavigationSheet(
          ride: ride,
          api: api,
          socket: socket,
          locationService: locationService,
          riderPhone: riderPhone,
          riderName: riderName,
          initialStage: initialStage,
        ),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: child,
        ),
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

  /// The dark trip panel can be folded away so the map fills the screen.
  bool _panelExpanded = true;

  /// The rider's pin, refreshed from the backend while driving to pickup.
  LatLng? _riderPosition;
  Timer? _riderPoll;
  bool _almostThere = false;
  bool _riderMoved = false;

  /// The point the driver last routed from, so the route is only recomputed
  /// once they have actually moved rather than on every tick.
  LatLng? _lastRouteFrom;

  /// Under this, the driver is at the door.
  static const double _almostThereMeters = 100;

  /// Straight-line metres left to the target, refreshed with the rider pin.
  /// Null means "not known yet" — a plain `double` sentinel cannot express that
  /// safely, because a field added by a hot reload starts life as null and
  /// reading `.isFinite` off it throws instead of showing the placeholder.
  double? _remaining;

  @override
  void initState() {
    super.initState();
    _ride = widget.ride;
    _stage = widget.initialStage ?? NavigationStage.toPickup;
    _location = widget.locationService ?? LocationService();
    _driverPosition = _currentDriverCoords();
    _riderPosition = LatLng(_ride.pickup.lat, _ride.pickup.lng);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRoute();
      _startLocationTracking();
      _startRiderTracking();
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _locationSyncTimer?.cancel();
    _riderPoll?.cancel();
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
      // Keep the remaining distance and ETA honest as the driver moves.
      _refreshRouteIfMoved(here);
    });

    _locationSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncDriverLocation();
    });
  }

  /// Re-route only once the driver has covered a meaningful distance, so the
  /// number on screen ticks down as they drive instead of jumping about.
  void _refreshRouteIfMoved(LatLng here) {
    final last = _lastRouteFrom;
    if (last != null) {
      const distance = Distance();
      final moved = distance.as(LengthUnit.Meter, last, here);
      if (moved < 60) return;
    }
    _lastRouteFrom = here;
    _loadRoute(fit: false);
  }

  /// ------------------------------------------------------------------------
  /// Live rider tracking
  /// ------------------------------------------------------------------------
  /// The rider is walking (or driving) toward the pickup, so the pin the
  /// driver sees has to move with them and the distance has to count down.
  void _startRiderTracking() {
    _riderPoll?.cancel();
    _riderPoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pollRider(),
    );
  }

  Future<void> _pollRider() async {
    if (!mounted) return;
    // Once the customer is in the car their position is the driver's problem,
    // not something worth polling.
    if (_stage != NavigationStage.toPickup) return;

    try {
      final location = await widget.api.getRiderLocation(_ride.id);
      if (!mounted || _stage != NavigationStage.toPickup) return;

      final here = _driverPosition;
      final pickup = LatLng(_ride.pickup.lat, _ride.pickup.lng);
      const distance = Distance();

      final target = location.marker;

      // The driver is at the pickup, so "almost there" is judged on how close
      // they are to the point they are actually heading for.
      final remaining = distance.as(LengthUnit.Meter, here ?? target, pickup);
      final almost = remaining <= _almostThereMeters;

      final moved = target != _riderPosition;
      final changed = moved || almost != _almostThere || remaining != _remaining;
      if (!changed) return;

      setState(() {
        _riderPosition = target;
        _remaining = remaining;
        _almostThere = almost;
        if (moved) _riderMoved = true;
      });
    } catch (_) {
      // No fix yet, or the backend is briefly unreachable. Keep the booked
      // pickup point on the map and try again next tick.
    }
  }

  /// The rider's marker, falling back to the booked pickup point.
  LatLng get _riderMarker => _riderPosition ?? _riderTarget;

  LatLng get _riderTarget => _stage == NavigationStage.onTrip
      ? LatLng(_ride.dropoff.lat, _ride.dropoff.lng)
      : LatLng(_ride.pickup.lat, _ride.pickup.lng);

  Future<void> _syncDriverLocation() async {
    if (!mounted || _driverPosition == null) return;
    try {
      await widget.api.saveLocation(
        lat: _driverPosition!.latitude,
        lng: _driverPosition!.longitude,
      );
    } catch (_) {}
  }

  Future<void> _loadRoute({bool fit = true}) async {
    if (_sending) return;
    setState(() => _loadingRoute = true);

    final from = _stage == NavigationStage.toPickup
        ? _currentDriverCoords()
        : LatLng(_ride.pickup.lat, _ride.pickup.lng);
    final to = _stage == NavigationStage.toPickup
        ? LatLng(_ride.pickup.lat, _ride.pickup.lng)
        : LatLng(_ride.dropoff.lat, _ride.dropoff.lng);

    _lastRouteFrom = from;

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
        _remaining = route.distanceMeters;
        _almostThere = route.distanceMeters <= _almostThereMeters;
      });
      if (fit) _fitRoute(route);
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
      if (fit) _fitRoute(fallback);
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
          padding: _mapPadding(),
          maxZoom: 17,
        ),
      );
    } catch (_) {}
  }

  /// Leave room for whichever panel height is actually on screen.
  EdgeInsets _mapPadding() {
    final media = MediaQuery.of(context);
    final bottom = _panelExpanded ? media.size.height * 0.42 : 96.0;
    return EdgeInsets.fromLTRB(48, 120, 48, bottom);
  }

  /// Called after the panel finishes animating, so the route is not left
  /// hiding underneath it.
  void _refitAfterPanel() {
    if (!_mapReady) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_route != null) {
        _fitRoute(_route!);
      } else if (_driverPosition != null) {
        _mapController.move(_driverPosition!, 16);
      }
    });
  }

  void _togglePanel() {
    HapticFeedback.selectionClick();
    setState(() => _panelExpanded = !_panelExpanded);
    _refitAfterPanel();
  }

  Future<void> _markArrived() async {
    if (_sending) return;
    setState(() => _sending = true);

    try {
      widget.socket?.send({
        'type': 'driver_arrived',
        'ride_id': _ride.id,
      });
      // Mirror the socket message to the backend so the rider's poll sees
      // the driver has arrived.
      try {
        await widget.api.updateRideState(
          _ride.id,
          state: RideState.driverArrived,
        );
      } catch (_) {}
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
      try {
        await widget.api.updateRideState(
          _ride.id,
          state: RideState.ongoing,
        );
      } catch (_) {}
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
      try {
        await widget.api.updateRideState(
          _ride.id,
          state: RideState.completed,
        );
      } catch (_) {}
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
    try {
      await widget.api.updateRideState(
        _ride.id,
        state: RideState.cancelled,
        reason: 'Driver cancelled the trip',
      );
    } catch (_) {}
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
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            _buildMap(),
            _buildMapControls(),
            _buildTopBar(),
            // A visible control on the map itself, so folding the panel does
            // not depend on the driver finding the grab bar.
            _buildPanelToggle(),
            _buildBottomPanel(),
          ],
        ),
      ),
    );
  }

  /// Floating control that brings the trip panel back once it is folded away.
  Widget _buildPanelToggle() {
    if (_panelExpanded) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Positioned(
      right: AppTheme.spaceLg,
      bottom: 84,
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        elevation: 6,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          onTap: _togglePanel,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spaceLg,
              vertical: AppTheme.spaceSm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.expand_less_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Trip details',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pinch, double tap and scroll wheel already work on the map; these
  /// buttons make zooming discoverable for everyone else.
  Widget _buildMapControls() {
    return Positioned(
      right: AppTheme.spaceLg,
      top: 92,
      child: SafeArea(
        bottom: false,
        child: MapZoomControls(controller: _mapController),
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
        minZoom: AppConstants.mapMinZoom,
        maxZoom: AppConstants.mapMaxZoom,
        onMapReady: () {
          _mapReady = true;
          if (_route != null) _fitRoute(_route!);
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchMove,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.fastride.app',
          minZoom: AppConstants.mapMinZoom,
          maxZoom: AppConstants.mapMaxZoom,
          maxNativeZoom: AppConstants.mapNativeMaxZoom,
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
                      color: AppTheme.danger,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
          ),
        MarkerLayer(
          markers: [
            if (_driverPosition != null) _driverMarker(_driverPosition!, scheme),
            // The rider's pin follows their live position while the driver is
            // on the way to pickup, and the destination once they are en route.
            _pin(
              _riderMarker,
              AppTheme.danger,
              _stage == NavigationStage.onTrip
                  ? Icons.place_rounded
                  : Icons.person_pin_circle_rounded,
            ),
            if (_stage == NavigationStage.onTrip)
              _pin(
                LatLng(_ride.pickup.lat, _ride.pickup.lng),
                AppTheme.danger,
                Icons.person_pin_circle_rounded,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle + collapse control. Swiping or tapping it folds
              // the panel away so the driver can just follow the map.
              _panelHandle(theme, scheme),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _panelExpanded
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppTheme.spaceXl,
                          0,
                          AppTheme.spaceXl,
                          AppTheme.spaceLg,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_almostThere) ...[
                              _almostThereBanner(theme, scheme),
                              const SizedBox(height: AppTheme.spaceMd),
                            ],
                            _routeSummary(theme, scheme),
                            if (_riderMoved &&
                                _stage == NavigationStage.toPickup) ...[
                              const SizedBox(height: AppTheme.spaceSm),
                              _riderOnTheMoveNote(theme, scheme),
                            ],
                            if (widget.hasRiderPhone) ...[
                              const SizedBox(height: AppTheme.spaceMd),
                              _customerContact(theme, scheme),
                            ],
                            const SizedBox(height: AppTheme.spaceLg),
                            _milestones(theme, scheme),
                            const SizedBox(height: AppTheme.spaceLg),
                            _actionButton(),
                          ],
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppTheme.spaceXl,
                          0,
                          AppTheme.spaceXl,
                          AppTheme.spaceSm,
                        ),
                        child: _collapsedRow(theme, scheme),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The grab bar plus an explicit "Hide" control, so folding the panel does
  /// not depend on the driver working out that the bar is draggable.
  Widget _panelHandle(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceXl,
        AppTheme.spaceXs,
        AppTheme.spaceMd,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _togglePanel,
              onVerticalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity > 120 && _panelExpanded) _togglePanel();
                if (velocity < -120 && !_panelExpanded) _togglePanel();
              },
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  const SizedBox(height: AppTheme.spaceSm),
                  Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                    ),
                  ),
                  const SizedBox(height: AppTheme.spaceSm),
                ],
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _togglePanel,
            icon: const Icon(Icons.fullscreen_rounded, size: 16),
            label: const Text('Hide'),
            style: TextButton.styleFrom(
              foregroundColor: scheme.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  /// Slim bar shown when the panel is folded: just the essentials. Tapping it,
  /// or the floating pill above, brings the full panel back.
  Widget _collapsedRow(ThemeData theme, ColorScheme scheme) {
    final target = _stage == NavigationStage.toPickup
        ? _ride.pickup
        : _ride.dropoff;
    final label = _stage == NavigationStage.toPickup ? 'Pickup' : 'Dropoff';
    final distance = _loadingRoute
        ? '…'
        : _remaining != null
            ? _fmtDistance(_remaining!)
            : '—';

    return GestureDetector(
      onTap: _togglePanel,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spaceXl,
          0,
          AppTheme.spaceXl,
          AppTheme.spaceSm,
        ),
        child: Row(
          children: [
            Icon(Icons.navigation_rounded, size: 20, color: scheme.primary),
            const SizedBox(width: AppTheme.spaceSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _almostThere ? 'Almost there · $label' : '$label · $distance',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: _almostThere ? AppTheme.success : scheme.onSurface,
                    ),
                  ),
                  Text(
                    target.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.expand_less_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// Shown while the driver is within 100 m of the pickup.
  Widget _almostThereBanner(ThemeData theme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.success.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.near_me_rounded,
            color: AppTheme.success,
            size: 20,
          ),
          const SizedBox(width: AppTheme.spaceSm),
          Expanded(
            child: Text(
              _remaining != null
                  ? 'Almost there — ${_fmtDistance(_remaining!)} away'
                  : 'Almost there',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppTheme.success,
              ),
            ),
          ),
        ],
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

    // Prefer the routed distance so the number follows the road, and fall back
    // to the straight-line figure while a fresh route is on its way.
    final routed = _route?.distanceMeters ?? 0;
    final distance = _loadingRoute
        ? '…'
        : routed > 0
            ? _fmtDistance(routed)
            : _remaining != null
                ? _fmtDistance(_remaining!)
                : '—';

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

  /// The rider's pin is no longer on the point the ride was booked against,
  /// so the driver should expect to meet them somewhere along the way.
  Widget _riderOnTheMoveNote(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        Icon(Icons.directions_walk_rounded, size: 14, color: scheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            widget.riderName.trim().isEmpty
                ? 'Your customer is on the move — their pin is live.'
                : '${widget.riderName.split(' ').first} is on the move — '
                    'their pin is live.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// The customer's name and phone, with a one-tap call button.
  Widget _customerContact(ThemeData theme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceMd,
        vertical: AppTheme.spaceSm,
      ),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.person_rounded, size: 20, color: scheme.primary),
          const SizedBox(width: AppTheme.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.riderName.trim().isNotEmpty)
                  Text(
                    widget.riderName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                Text(
                  widget.riderPhone,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => _callRider(),
            icon: const Icon(Icons.call_rounded, size: 18),
            label: const Text('Call'),
          ),
        ],
      ),
    );
  }

  Future<void> _callRider() async {
    final digits = widget.riderPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.isEmpty) return;
    try {
      final launched = await launchUrl(Uri(scheme: 'tel', path: digits));
      if (!launched && mounted) {
        _toast('Could not start the dialler on this device.');
      }
    } catch (_) {
      if (mounted) _toast('Could not start the dialler on this device.');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _milestones(ThemeData theme, ColorScheme scheme) {    return Row(
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
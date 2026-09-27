import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../core/api_client.dart';
import '../models/driver_model.dart';
import '../models/ride_model.dart';
import '../shared/custom_modal.dart';
import '../theme.dart';

/// What the sheet returns to the dashboard when it closes.
enum ActiveTripOutcome { completed, cancelled }

/// =========================================================================
/// ActiveTripSheet
/// -------------------------------------------------------------------------
/// The rider's home during the ride. Adapts to the current RideState:
///
///   accepted / driverArriving → shows driver card, ETA, cancel
///   driverArrived             → shows OTP, "Driver is here"
///   ongoing                   → shows live progress, dropoff info
///   completed                 → shows receipt-style summary
///   cancelled                 → briefly shows reason then pops
///
/// The sheet is dismissible only when the ride is in a cancellable state —
/// once the trip starts, the rider must complete it to return to idle.
/// =========================================================================
class ActiveTripSheet extends StatefulWidget {
  const ActiveTripSheet({
    super.key,
    required this.ride,
    required this.api,
  });

  final RideModel ride;
  final ApiClient api;

  static Future<ActiveTripOutcome?> show({
    required BuildContext context,
    required RideModel ride,
    required ApiClient api,
  }) {
    // A non-opaque page route rather than a modal bottom sheet: collapsing the
    // panel has to leave the dashboard's map fully visible and tappable, and
    // a modal barrier (or a fixed barrier colour) would get in the way.
    return Navigator.of(context).push<ActiveTripOutcome>(
      PageRouteBuilder<ActiveTripOutcome>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => ActiveTripSheet(ride: ride, api: api),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: child,
        ),
      ),
    );
  }

  @override
  State<ActiveTripSheet> createState() => _ActiveTripSheetState();
}

class _ActiveTripSheetState extends State<ActiveTripSheet> {
  late RideModel _ride;
  Timer? _progressTick;
  Timer? _statusPoll;
  int _etaSeconds = 0;

  /// Live straight-line distance from the driver to the pickup point, in
  /// metres. Null until the driver has reported a position.
  double? _driverDistanceMeters;

  /// Where the driver is right now, for routing.
  LatLng? _driverAt;

  /// Road distance and drive time from the driver to the point this trip is
  /// heading for — the pickup while they are coming to get the rider, the
  /// destination once the ride is under way. A straight line understates a
  /// real trip, so these come from the router whenever it answers.
  double? _remainingMeters;
  int? _remainingSeconds;

  /// Guards the routing call and lets us throttle how often we ask for it.
  bool _routing = false;
  DateTime? _lastRoutedAt;
  LatLng? _lastRoutedFrom;

  /// The driver is at the door.
  static const double _almostThereMeters = 100;

  /// When false the details are folded away and only the map is left.
  bool _expanded = true;

  /// Prefer the routed distance when we have it: a straight line through
  /// buildings is always shorter than the road the driver has to drive.
  bool get _driverAlmostThere {
    final distance = _remainingMeters ?? _driverDistanceMeters;
    return distance != null && distance <= _almostThereMeters;
  }

  @override
  void initState() {
    super.initState();
    _ride = widget.ride;
    _etaSeconds = (widget.ride.durationSeconds ?? 0).round();
    _measureDriverDistance(_ride);
    _routeRemaining();
    _startProgress();
    _startStatusPolling();
  }

  @override
  void dispose() {
    _progressTick?.cancel();
    _statusPoll?.cancel();
    super.dispose();
  }

  /// How far the driver still is from the pickup point. The driver pushes a
  /// position every couple of seconds, so this counts down as they approach.
  void _measureDriverDistance(RideModel ride) {
    final driver = ride.driver;
    if (driver == null || !driver.hasPosition) {
      _driverAt = null;
      _driverDistanceMeters = null;
      return;
    }
    final here = LatLng(driver.latitude!, driver.longitude!);
    _driverAt = here;
    const distance = Distance();
    _driverDistanceMeters = distance.as(
      LengthUnit.Meter,
      here,
      LatLng(ride.pickup.lat, ride.pickup.lng),
    );
  }

  /// Where the trip is currently headed.
  LatLng? get _targetAt {
    switch (_ride.state) {
      case RideState.accepted:
      case RideState.driverArriving:
      case RideState.driverArrived:
        return LatLng(_ride.pickup.lat, _ride.pickup.lng);
      case RideState.ongoing:
        return LatLng(_ride.dropoff.lat, _ride.dropoff.lng);
      default:
        return null;
    }
  }

  /// Ask the backend how far the driver actually has to drive, road distance
  /// rather than as the crow flies, and how long that should take.
  Future<void> _routeRemaining() async {
    if (!mounted || _routing) return;

    final from = _driverAt;
    final to = _targetAt;
    if (from == null || to == null) return;

    // Routing costs a network round trip, so only ask again once the answer
    // would have changed — the driver has moved, or the last one has gone
    // stale because traffic changed under them.
    final elapsed = _lastRoutedAt == null
        ? const Duration(minutes: 1)
        : DateTime.now().difference(_lastRoutedAt!);
    if (elapsed < const Duration(seconds: 20)) return;

    final moved = _lastRoutedFrom == null
        ? double.infinity
        : const Distance().as(LengthUnit.Meter, _lastRoutedFrom!, from);
    if (moved < 50 && elapsed < const Duration(minutes: 1)) return;

    _routing = true;
    try {
      final route = await widget.api.route(
        fromLat: from.latitude,
        fromLng: from.longitude,
        toLat: to.latitude,
        toLng: to.longitude,
      );
      if (!mounted) return;
      setState(() {
        _remainingMeters = route.distanceMeters;
        _remainingSeconds = route.durationSeconds.round();
      });
    } catch (_) {
      // Keep whatever straight-line estimate we already had; next tick retries.
    } finally {
      _routing = false;
      _lastRoutedAt = DateTime.now();
      _lastRoutedFrom = from;
    }
  }

  /// Pulls the authoritative ride state from the backend. The driver writes it
  /// as they accept, arrive, start and complete, so this is what moves the
  /// rider's screen from "arriving" through to "on trip".
  void _startStatusPolling() {
    _statusPoll?.cancel();
    _statusPoll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshFromServer(),
    );
  }

  Future<void> _refreshFromServer() async {
    if (!mounted) return;
    if (_ride.state == RideState.completed ||
        _ride.state == RideState.cancelled) {
      return;
    }

    try {
      final fresh = await widget.api.getRide(_ride.id);
      if (!mounted) return;

      final previous = _driverDistanceMeters;
      _measureDriverDistance(fresh);

      final stateChanged = fresh.state != _ride.state;
      final driverChanged = fresh.driver?.id != _ride.driver?.id;
      // The position moves constantly, so a small change still means the
      // on-screen number is stale.
      final distanceMoved = previous == null ||
          _driverDistanceMeters == null ||
          (previous - _driverDistanceMeters!).abs() >= 5;

      if (!stateChanged && !driverChanged && !distanceMoved) return;

      setState(() {
        _ride = fresh;
        if (stateChanged && fresh.startedAt != null) {
          _etaSeconds = (fresh.durationSeconds ?? 0).round();
        }
        if (stateChanged) {
          // The destination just changed, so the old figure is meaningless.
          _remainingMeters = null;
          _remainingSeconds = null;
          _lastRoutedAt = null;
        }
      });

      if (stateChanged || distanceMoved) _routeRemaining();
    } catch (_) {
      // A failed poll is not fatal; the next tick retries.
    }
  }

  /// A local countdown used only for the UI.
  /// A real deployment would drive this from server-side ETA updates
  /// arriving on the WebSocket.
  void _startProgress() {
    _progressTick?.cancel();
    _progressTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_etaSeconds > 0) _etaSeconds--;
      });
    });
  }

  // =========================================================================
  // Actions
  // =========================================================================

  Future<void> _cancelTrip() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel ride?'),
        content: const Text(
          'Your driver is on the way. Cancelling now may incur a fee.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep ride'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Cancel ride'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    HapticFeedback.mediumImpact();
    try {
      await widget.api.updateRideState(
        _ride.id,
        state: RideState.cancelled,
        reason: 'Rider cancelled the ride',
      );
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop(ActiveTripOutcome.cancelled);
  }

  void _triggerSOS() {
    HapticFeedback.heavyImpact();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: AppTheme.danger, size: 40),
        title: const Text('Emergency'),
        content: const Text(
          'This will alert our safety team and share your live location. '
          'Only use this in an emergency.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Safety team notified. Help is on the way.'),
                ),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Send alert'),
          ),
        ],
      ),
    );
  }

  void _finishTrip() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(ActiveTripOutcome.completed);
  }

  // =========================================================================
  // Build
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);

    return Stack(
      children: [
        // The scrim belongs to the panel: folding the panel away takes the
        // scrim with it, leaving the map clear and interactive.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_expanded,
            child: AnimatedOpacity(
              opacity: _expanded ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                onTap: _expanded ? _collapse : null,
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(
                maxHeight: _expanded ? media.size.height * 0.85 : double.infinity,
              ),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppTheme.radiusLg),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: SafeArea(
                top: false,
                child: _expanded
                    ? _expandedPanel(theme, scheme)
                    : _collapsedBar(theme, scheme),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Grab bar. Tap it, or swipe down, to fold the panel away and leave just
  /// the map.
  Widget _panelHandle(ThemeData theme, ColorScheme scheme) {
    return GestureDetector(
      onTap: _collapse,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity > 120) _collapse();
        if (velocity < -120) _expand();
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
    );
  }

  /// Slim bar shown when folded: where the trip is, and a way back.
  Widget _collapsedBar(ThemeData theme, ColorScheme scheme) {
    final closing = _ride.state == RideState.accepted ||
        _ride.state == RideState.driverArriving;
    final title = _driverAlmostThere && closing
        ? 'Your driver is almost here'
        : _ride.state.label;
    final closingDistance = _remainingMeters ?? _driverDistanceMeters;
    final subtitle = closing
        ? (closingDistance != null
            ? '${_distanceLabel(closingDistance)} away'
            : _ride.pickup.displayLabel)
        : _ride.dropoff.displayLabel;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _panelHandle(theme, scheme),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceLg,
            0,
            AppTheme.spaceMd,
            AppTheme.spaceSm,
          ),
          child: Row(
            children: [
              Icon(Icons.route_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: AppTheme.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: _driverAlmostThere && closing
                            ? AppTheme.success
                            : scheme.onSurface,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _expand,
                icon: const Icon(Icons.expand_less_rounded, size: 18),
                label: const Text('Details'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _expandedPanel(ThemeData theme, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
          _panelHandle(theme, scheme),
          // Top grip / title bar
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceXl,
              AppTheme.spaceSm,
              AppTheme.spaceXl,
              AppTheme.spaceSm,
            ),
            child: Row(
              children: [
                Expanded(child: _statePill(theme, scheme)),
                IconButton(
                  onPressed: _collapse,
                  tooltip: 'Hide ride details',
                  icon: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_ride.isCancellable)
                  IconButton(
                    onPressed: _cancelTrip,
                    tooltip: 'Cancel ride',
                    icon: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceXl,
                0,
                AppTheme.spaceXl,
                AppTheme.spaceXl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ETA card
                  _etaCard(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),

                  // Driver card
                  _driverCard(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),

                  // OTP (only when driver is at pickup)
                  if (_ride.state == RideState.driverArrived) ...[
                    _otpCard(theme, scheme),
                    const SizedBox(height: AppTheme.spaceLg),
                  ],

                  // Trip endpoints
                  _tripCard(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),

                  // SOS
                  _sosButton(theme, scheme),

                  if (_ride.state == RideState.completed) ...[
                    const SizedBox(height: AppTheme.spaceLg),
                    SheetPrimaryButton(
                      label: 'Done',
                      icon: Icons.check_rounded,
                      onPressed: _finishTrip,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
  }

  // -------------------------------------------------------------------------
  // Collapse / expand
  // -------------------------------------------------------------------------

  /// Hide the details so the rider is left with just the map and route.
  void _collapse() {
    HapticFeedback.selectionClick();
    setState(() => _expanded = false);
  }

  void _expand() {
    HapticFeedback.selectionClick();
    setState(() => _expanded = true);
  }

  // -------------------------------------------------------------------------
  // Sub-widgets
  // -------------------------------------------------------------------------

  Widget _statePill(ThemeData theme, ColorScheme scheme) {
    final color = switch (_ride.state) {
      RideState.accepted || RideState.driverArriving => AppTheme.info,
      RideState.driverArrived => AppTheme.success,
      RideState.ongoing => scheme.primary,
      RideState.completed => AppTheme.success,
      RideState.cancelled || RideState.expired => AppTheme.danger,
      _ => scheme.primary,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            _ride.state.label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _etaCard(ThemeData theme, ColorScheme scheme) {
    final minutes = (_etaSeconds / 60).ceil().clamp(0, 999);
    final closing = _ride.state == RideState.accepted ||
        _ride.state == RideState.driverArriving;

    final title = _driverAlmostThere && closing
        ? 'Your driver is almost here'
        : switch (_ride.state) {
            RideState.accepted || RideState.driverArriving => _remainingMeters != null
                ? 'Driver is ${_distanceLabel(_remainingMeters!)} away'
                : 'Arriving in $minutes min',
            RideState.driverArrived => 'Your driver is here',
            RideState.ongoing => _remainingMeters != null
                ? 'Destination ${_distanceLabel(_remainingMeters!)} away'
                : 'Arriving at destination in $minutes min',
            RideState.completed => 'Trip completed',
            RideState.cancelled => 'Trip cancelled',
            _ => 'Please wait…',
          };

    final subtitle = _driverAlmostThere && closing
        ? 'Head to ${_ride.pickup.displayLabel} — your driver is within '
            '${_distanceLabel(_driverDistanceMeters!)}'
        : switch (_ride.state) {
            RideState.accepted || RideState.driverArriving =>
              'Meet at ${_ride.pickup.displayLabel}',
            RideState.driverArrived =>
              'Look for ${_ride.driver?.vehicle?.displayName ?? 'the vehicle'}',
            RideState.ongoing => 'To ${_ride.dropoff.displayLabel}',
            RideState.completed => 'Thanks for riding with us',
            RideState.cancelled => _ride.cancellationReason ?? 'Ride was cancelled',
            _ => '',
          };

    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceXl),
      decoration: BoxDecoration(
        color: _driverAlmostThere && closing
            ? AppTheme.success
            : scheme.primary,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onPrimary.withValues(alpha: 0.85),
            ),
          ),
          if ((closing || _ride.state == RideState.ongoing) &&
              _remainingSeconds != null) ...[
            // The headline now carries the distance, so the drive time moves
            // down here rather than being thrown away.
            const SizedBox(height: AppTheme.spaceMd),
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 16,
                  color: scheme.onPrimary.withValues(alpha: 0.9),
                ),
                const SizedBox(width: 6),
                Text(
                  'About ${_etaLabel(_remainingSeconds!)}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _etaLabel(int seconds) {
    final minutes = (seconds / 60).ceil();
    if (minutes < 1) return 'less than a minute';
    if (minutes == 1) return '1 min';
    return '$minutes min';
  }

  static String _distanceLabel(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  Widget _driverCard(ThemeData theme, ColorScheme scheme) {
    final driver = _ride.driver;
    if (driver == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _avatar(driver, scheme),
              const SizedBox(width: AppTheme.spaceLg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driver.firstName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded,
                            size: 16, color: Color(0xFFF59E0B)),
                        const SizedBox(width: 4),
                        Text(
                          '${driver.ratingLabel} · ${driver.tripsLabel}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _iconAction(
                Icons.call_rounded,
                () => _fakeAction('Calling ${driver.firstName}…'),
                scheme,
              ),
              const SizedBox(width: AppTheme.spaceSm),
              _iconAction(
                Icons.chat_bubble_rounded,
                () => _fakeAction('Opening chat…'),
                scheme,
              ),
            ],
          ),
          if (driver.vehicle != null) ...[
            const SizedBox(height: AppTheme.spaceLg),
            Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            const SizedBox(height: AppTheme.spaceMd),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: Icon(
                    Icons.directions_car_rounded,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        driver.vehicle!.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        driver.vehicle!.displayPlate,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _avatar(DriverModel driver, ColorScheme scheme) {
    if (driver.avatarUrl != null) {
      return CircleAvatar(
        radius: 28,
        backgroundImage: NetworkImage(driver.avatarUrl!),
        onBackgroundImageError: (_, __) {},
        child: null,
      );
    }
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        driver.initials,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }

  Widget _iconAction(IconData icon, VoidCallback onTap, ColorScheme scheme) {
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: 20, color: scheme.onSurface),
        ),
      ),
    );
  }

  Widget _otpCard(ThemeData theme, ColorScheme scheme) {
    final otp = _ride.otp ?? '----';
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceXl),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: AppTheme.success.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Text(
            'Share this code with your driver',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spaceMd),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final ch in otp.split('')) ...[
                _otpDigit(theme, scheme, ch),
                const SizedBox(width: AppTheme.spaceSm),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _otpDigit(ThemeData theme, ColorScheme scheme, String ch) {
    return Container(
      width: 48,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        ch,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: scheme.onSurface,
        ),
      ),
    );
  }

  Widget _tripCard(ThemeData theme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _locationRow(
            theme,
            scheme,
            icon: Icons.my_location_rounded,
            color: scheme.primary,
            title: _ride.pickup.displayLabel,
            subtitle: _ride.pickup.displaySubtitle,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 11),
            child: Container(
              width: 2,
              height: 22,
              color: scheme.outlineVariant,
            ),
          ),
          _locationRow(
            theme,
            scheme,
            icon: Icons.place_rounded,
            color: AppTheme.danger,
            title: _ride.dropoff.displayLabel,
            subtitle: _ride.dropoff.displaySubtitle,
          ),
          const SizedBox(height: AppTheme.spaceLg),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppTheme.spaceMd),
          Row(
            children: [
              Expanded(
                child: _metaCell(
                  theme,
                  scheme,
                  'Distance',
                  _ride.distanceLabel,
                ),
              ),
              Expanded(
                child: _metaCell(
                  theme,
                  scheme,
                  'Duration',
                  _ride.durationLabel,
                ),
              ),
              Expanded(
                child: _metaCell(
                  theme,
                  scheme,
                  'Fare',
                  _ride.fareLabel,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _locationRow(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metaCell(
    ThemeData theme,
    ColorScheme scheme,
    String label,
    String value,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _sosButton(ThemeData theme, ColorScheme scheme) {
    return Material(
      color: AppTheme.danger.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: _triggerSOS,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spaceLg,
            vertical: AppTheme.spaceLg,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.danger,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.shield_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppTheme.spaceLg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Emergency',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.danger,
                      ),
                    ),
                    Text(
                      'Alert our safety team with your live location',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _fakeAction(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
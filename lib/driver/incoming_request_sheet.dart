import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ride_model.dart';
import '../shared/map_zoom_controls.dart';
import '../theme.dart';

/// =========================================================================
/// IncomingRequestSheet
/// -------------------------------------------------------------------------
/// High-priority overlay shown when the dispatcher offers a ride.
///
/// Behaviour:
///   • Full-screen takeover — ignores back gesture, no drag-to-dismiss.
///   • 15-second radial countdown (spec) → auto-declines at 0.
///   • Shows the rider's route on a map: pickup and destination both red.
///   • Shows the rider's phone number with one-tap call.
///   • Returns `true` on Accept, `false` on Reject / timeout.
/// =========================================================================
class IncomingRequestSheet extends StatefulWidget {
  const IncomingRequestSheet({super.key, required this.offer});

  final RideOffer offer;

  static Future<bool?> show({
    required BuildContext context,
    required RideOffer offer,
  }) {
    return showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      transitionDuration: AppConstants.sheetDuration,
      pageBuilder: (_, __, ___) => IncomingRequestSheet(offer: offer),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    );
  }

  @override
  State<IncomingRequestSheet> createState() => _IncomingRequestSheetState();
}

class _IncomingRequestSheetState extends State<IncomingRequestSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _countdown;
  final MapController _mapController = MapController();
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    _countdown = AnimationController(
      vsync: this,
      duration: AppConstants.requestCountdown,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_answered) {
          _answered = true;
          Navigator.of(context).pop(false);
        }
      });
    _countdown.forward();
    // Subtle alert haptic on open.
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (mounted) HapticFeedback.heavyImpact();
    });
  }

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  void _accept() {
    if (_answered) return;
    _answered = true;
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(true);
  }

  void _decline() {
    if (_answered) return;
    _answered = true;
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.spaceLg),
            child: Column(
              children: [
                // --- Countdown header (pinned) ----------------------------
                _countdownHeader(theme, scheme),

                const SizedBox(height: AppTheme.spaceMd),

                // --- Route + offer card (scrolls on short screens) -------
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _routePreview(theme, scheme),
                        const SizedBox(height: AppTheme.spaceLg),
                        _offerCard(theme, scheme),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: AppTheme.spaceLg),

                // --- Actions (pinned) ------------------------------------
                _actions(theme, scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _countdownHeader(ThemeData theme, ColorScheme scheme) {
    // Short viewports (small browser windows, landscape phones) get a
    // compact header so the offer card still has room.
    final compact = MediaQuery.sizeOf(context).height < 680;
    final dialSize = compact ? 60.0 : 96.0;

    return AnimatedBuilder(
      animation: _countdown,
      builder: (_, __) {
        final remaining =
            (AppConstants.requestCountdown.inSeconds * (1 - _countdown.value))
                .ceil()
                .clamp(0, AppConstants.requestCountdown.inSeconds);

        return Column(
          children: [
            SizedBox(
              width: dialSize,
              height: dialSize,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: dialSize,
                    height: dialSize,
                    child: CircularProgressIndicator(
                      value: 1 - _countdown.value,
                      strokeWidth: 5,
                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _countdown.value < 0.33
                            ? AppTheme.danger
                            : Colors.white,
                      ),
                    ),
                  ),
                  Text(
                    '$remaining',
                    style: (compact
                            ? theme.textTheme.headlineMedium
                            : theme.textTheme.displaySmall)
                        ?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: compact ? AppTheme.spaceSm : AppTheme.spaceMd),
            Text(
              'New ride request',
              style: (compact
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleLarge)
                  ?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: 4),
              Text(
                'Accept before the timer runs out',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Static preview of the customer's route.
  ///
  /// Both the pickup point (where the customer is standing) and the
  /// destination are drawn in red, joined by a straight route line.
  Widget _routePreview(ThemeData theme, ColorScheme scheme) {
    final pickup = LatLng(widget.offer.pickup.lat, widget.offer.pickup.lng);
    final dropoff = LatLng(widget.offer.dropoff.lat, widget.offer.dropoff.lng);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final mapHeight = screenHeight < 680
        ? 130.0
        : screenHeight < 820
            ? 170.0
            : 190.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: SizedBox(
        height: mapHeight,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: LatLng(
                  (pickup.latitude + dropoff.latitude) / 2,
                  (pickup.longitude + dropoff.longitude) / 2,
                ),
                initialZoom: 13,
                minZoom: AppConstants.mapMinZoom,
                maxZoom: AppConstants.mapMaxZoom,
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
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.fastride.app',
                  minZoom: AppConstants.mapMinZoom,
                  maxZoom: AppConstants.mapMaxZoom,
                  maxNativeZoom: AppConstants.mapNativeMaxZoom,
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [pickup, dropoff],
                      strokeWidth: 4,
                      color: AppTheme.danger,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    _redPin(pickup, Icons.person_pin_circle_rounded),
                    _redPin(dropoff, Icons.place_rounded),
                  ],
                ),
              ],
            ),
            Positioned(
              right: AppTheme.spaceSm,
              bottom: AppTheme.spaceSm,
              child: MapZoomControls(
                controller: _mapController,
                compact: true,
              ),
            ),
            // Legend so the two red markers are unambiguous.
            Positioned(
              left: AppTheme.spaceSm,
              bottom: AppTheme.spaceSm,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.circle,
                      size: 10,
                      color: AppTheme.danger,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Pickup & destination',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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

  /// The customer's phone number, with a one-tap call button.
  Widget _riderContact(ThemeData theme, ColorScheme scheme) {
    final o = widget.offer;
    if (!o.hasRiderPhone) return const SizedBox.shrink();

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
                Text(
                  o.riderName,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  o.riderPhone,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Call customer',
            onPressed: () => _callRider(o.riderPhone),
            icon: Icon(Icons.call_rounded, color: scheme.primary),
          ),
        ],
      ),
    );
  }

  Future<void> _callRider(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri(scheme: 'tel', path: digits);
    try {
      final launched = await launchUrl(uri);
      if (!launched && mounted) {
        _showSnack('Could not start the dialler on this device.');
      }
    } catch (_) {
      if (mounted) _showSnack('Could not start the dialler on this device.');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _offerCard(ThemeData theme, ColorScheme scheme) {
    final o = widget.offer;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.softShadow,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceXl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          // Payout header — the fare the rider is charged, derived from the
          // driver's own per-km rate.
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total the rider pays',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      '${o.currency} ${o.payout.toStringAsFixed(2)}',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.success,
                      ),
                    ),
                    if (o.priceBreakdown.isNotEmpty)
                      Text(
                        o.priceBreakdown,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded,
                        size: 16, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      o.riderRating.toStringAsFixed(1),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: AppTheme.spaceLg),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppTheme.spaceLg),

          // Pickup / dropoff — both red, matching the map above.
          _endpoint(
            theme,
            scheme,
            icon: Icons.person_pin_circle_rounded,
            color: AppTheme.danger,
            label: 'Customer is here',
            place: o.pickup,
            distance: o.distanceToPickupLabel,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 11),
            child: Container(
              width: 2,
              height: 26,
              color: scheme.outlineVariant,
            ),
          ),
          _endpoint(
            theme,
            scheme,
            icon: Icons.place_rounded,
            color: AppTheme.danger,
            label: 'Destination',
            place: o.dropoff,
            distance: o.tripDistanceLabel,
          ),

          const SizedBox(height: AppTheme.spaceLg),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppTheme.spaceMd),

          // Customer contact
          _riderContact(theme, scheme),
          if (o.hasRiderPhone) const SizedBox(height: AppTheme.spaceMd),

          // Meta row
          Row(
            children: [
              Expanded(
                child: _meta(
                  theme,
                  scheme,
                  Icons.route_rounded,
                  'Trip',
                  o.tripDistanceLabel,
                ),
              ),
              Expanded(
                child: _meta(
                  theme,
                  scheme,
                  Icons.schedule_rounded,
                  'ETA',
                  o.tripDurationLabel,
                ),
              ),
              Expanded(
                child: _meta(
                  theme,
                  scheme,
                  Icons.person_rounded,
                  'Rider',
                  o.riderName,
                ),
              ),
            ],
          ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _endpoint(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required Color color,
    required String label,
    required RideLocation place,
    required String distance,
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
              Row(
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    distance,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              Text(
                place.displayLabel,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (place.address.isNotEmpty)
                Text(
                  place.displaySubtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _meta(
    ThemeData theme,
    ColorScheme scheme,
    IconData icon,
    String label,
    String value,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _actions(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 56,
            child: OutlinedButton(
              onPressed: _decline,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.6)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: const Text(
                'Decline',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 56,
            child: FilledButton(
              onPressed: _accept,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.success,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: const Text(
                'Accept ride',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ),
          ),
        ),
      ],
    );
  }
}



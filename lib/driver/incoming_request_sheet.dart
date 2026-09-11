import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ride_model.dart';
import '../theme.dart';

/// =========================================================================
/// IncomingRequestSheet
/// -------------------------------------------------------------------------
/// High-priority overlay shown when the dispatcher offers a ride.
///
/// Behaviour:
///   • Full-screen takeover — ignores back gesture, no drag-to-dismiss.
///   • 15-second radial countdown (spec) → auto-declines at 0.
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
                // --- Countdown header ------------------------------------
                _countdownHeader(theme, scheme),

                const Spacer(),

                // --- Offer card ------------------------------------------
                _offerCard(theme, scheme),

                const Spacer(),

                // --- Actions ---------------------------------------------
                _actions(theme, scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _countdownHeader(ThemeData theme, ColorScheme scheme) {
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
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
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
                    style: theme.textTheme.displaySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Text(
              'New ride request',
              style: theme.textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Accept before the timer runs out',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _offerCard(ThemeData theme, ColorScheme scheme) {
    final o = widget.offer;
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceXl),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Payout header
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Trip payout',
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

          // Pickup / dropoff
          _endpoint(
            theme,
            scheme,
            icon: Icons.my_location_rounded,
            color: scheme.primary,
            label: 'Pickup',
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
            label: 'Dropoff',
            place: o.dropoff,
            distance: o.tripDistanceLabel,
          ),

          const SizedBox(height: AppTheme.spaceLg),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppTheme.spaceMd),

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

/// =========================================================================
/// RideOffer
/// -------------------------------------------------------------------------
/// A dispatcher-issued offer. Lightweight — no full RideModel needed
/// until the driver accepts.
/// =========================================================================
class RideOffer {
  const RideOffer({
    required this.rideId,
    required this.pickup,
    required this.dropoff,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.payout,
    required this.currency,
    required this.riderName,
    required this.riderRating,
    this.distanceToPickupMeters = 1200,
  });

  final String rideId;
  final RideLocation pickup;
  final RideLocation dropoff;
  final double distanceMeters;
  final double durationSeconds;
  final double payout;
  final String currency;
  final String riderName;
  final double riderRating;
  final double distanceToPickupMeters;

  String get tripDistanceLabel {
    if (distanceMeters < 1000) return '${distanceMeters.round()} m';
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }

  String get distanceToPickupLabel {
    if (distanceToPickupMeters < 1000) {
      return '${distanceToPickupMeters.round()} m';
    }
    return '${(distanceToPickupMeters / 1000).toStringAsFixed(1)} km';
  }

  String get tripDurationLabel {
    final m = (durationSeconds / 60).round();
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return '${h}h ${r.toString().padLeft(2, '0')}m';
  }
}
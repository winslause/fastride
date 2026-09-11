import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    return AppSheet.show<ActiveTripOutcome>(
      context: context,
      isDismissible: ride.isCancellable,
      enableDrag: ride.isCancellable,
      isScrollControlled: true,
      child: ActiveTripSheet(ride: ride, api: api),
    );
  }

  @override
  State<ActiveTripSheet> createState() => _ActiveTripSheetState();
}

class _ActiveTripSheetState extends State<ActiveTripSheet> {
  late RideModel _ride;
  Timer? _progressTick;
  int _etaSeconds = 0;

  @override
  void initState() {
    super.initState();
    _ride = widget.ride;
    _etaSeconds = (widget.ride.durationSeconds ?? 0).round();
    _startProgress();
  }

  @override
  void dispose() {
    _progressTick?.cancel();
    super.dispose();
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

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
      ),
    );
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
    final title = switch (_ride.state) {
      RideState.accepted || RideState.driverArriving => 'Arriving in $minutes min',
      RideState.driverArrived => 'Your driver is here',
      RideState.ongoing => 'Arriving at destination in $minutes min',
      RideState.completed => 'Trip completed',
      RideState.cancelled => 'Trip cancelled',
      _ => 'Please wait…',
    };

    final subtitle = switch (_ride.state) {
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
        color: scheme.primary,
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
        ],
      ),
    );
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